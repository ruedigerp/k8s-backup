#!/bin/bash

# Kubernetes PV Backup Script
# Automatisiert das Backup aller Persistent Volumes im Cluster

set +e

# Konfiguration aus Umgebungsvariablen
BACKUP_IMAGE="${BACKUP_IMAGE:-busybox:latest}"
NFS_SERVER="${NFS_SERVER:-10.0.10.7}"
NFS_PATH="${NFS_PATH:-/srv/nfs/k8s-pv/production/k8s-backup}"
STORAGE_CLASS="${STORAGE_CLASS:-nfs-client}"
LOG_LEVEL="${LOG_LEVEL:-info}"

# Log-Datei Location (in Container)
LOG_FILE="/var/log/backup/pv-backup-$(date +%Y%m%d-%H%M%S).log"

# Logging-Funktion
log() {
    local level="INFO"
    local message="$1"
    
    if [[ "$2" ]]; then
        level="$1"
        message="$2"
    fi
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$LOG_FILE"
}

# Startup-Validierung
validate_environment() {
    log "INFO" "Validiere Umgebung..."
    
    if [[ -z "$NFS_SERVER" ]]; then
        log "ERROR" "NFS_SERVER Umgebungsvariable ist nicht gesetzt"
        exit 1
    fi
    
    if [[ -z "$BACKUP_IMAGE" ]]; then
        log "ERROR" "BACKUP_IMAGE Umgebungsvariable ist nicht gesetzt"
        exit 1
    fi
    
    log "INFO" "Konfiguration:"
    log "INFO" "  BACKUP_IMAGE: $BACKUP_IMAGE"
    log "INFO" "  NFS_SERVER: $NFS_SERVER"
    log "INFO" "  NFS_PATH: $NFS_PATH"
    log "INFO" "  STORAGE_CLASS: $STORAGE_CLASS"
}

# Funktion zum Finden von Pods, die ein PVC nutzen
find_pods_using_pvc() {
    local pvc_name="$1"
    local namespace="$2"
    
    kubectl get pods -n "$namespace" -o json | jq -r --arg pvc "$pvc_name" '
        .items[] | 
        select(.spec.volumes[]?.persistentVolumeClaim?.claimName == $pvc) | 
        .metadata.name
    '
}

# Funktion zum Ermitteln des Controllers (Deployment, StatefulSet, DaemonSet)
get_pod_controller() {
    local pod_name="$1"
    local namespace="$2"
    
    local owner_ref=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.metadata.ownerReferences[0]}')
    
    if [[ -z "$owner_ref" ]]; then
        echo "none"
        return
    fi
    
    local kind=$(echo "$owner_ref" | jq -r '.kind')
    local name=$(echo "$owner_ref" | jq -r '.name')
    
    case "$kind" in
        "ReplicaSet")
            # Bei ReplicaSet nach Deployment suchen
            local deployment=$(kubectl get rs "$name" -n "$namespace" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || echo "")
            if [[ -n "$deployment" ]]; then
                echo "deployment/$deployment"
            else
                echo "replicaset/$name"
            fi
            ;;
        "StatefulSet")
            echo "statefulset/$name"
            ;;
        "DaemonSet")
            echo "daemonset/$name"
            ;;
        "Job")
            echo "job/$name"
            ;;
        *)
            echo "$kind/$name"
            ;;
    esac
}

# Funktion zum Ermitteln der aktuellen Replicas
get_current_replicas() {
    local controller="$1"
    local namespace="$2"
    
    kubectl get "$controller" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1"
}

# Funktion zum Skalieren
scale_controller() {
    local controller="$1"
    local namespace="$2"
    local replicas="$3"
    
    log "INFO" "Skaliere $controller in Namespace $namespace auf $replicas Replicas"
    kubectl scale "$controller" -n "$namespace" --replicas="$replicas"
    
    # Warten bis skaliert
    if [[ "$replicas" == "0" ]]; then
        log "INFO" "Warte bis alle Pods gestoppt sind..."
        kubectl wait --for=delete pod -l app.kubernetes.io/name -n "$namespace" --timeout=300s 2>/dev/null || true
        sleep 10
    else
        log "INFO" "Warte bis Pods wieder bereit sind..."
        kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name -n "$namespace" --timeout=300s 2>/dev/null || true
    fi
}

# Funktion zum Erstellen des Backup-Jobs
create_backup_job() {
    local pvc_name="$1"
    local namespace="$2"
    local job_name="backup-${pvc_name}-$(date +%s)"
    
    log "INFO" "Erstelle Backup-Job für PVC $pvc_name"

    # Service Account für diesen Namespace erstellen (falls nicht vorhanden)
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: backup-service-account
  namespace: $namespace
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: backup-service-account-binding-$namespace
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: full-backup-role
subjects:
- kind: ServiceAccount
  name: backup-service-account
  namespace: $namespace
EOF

    # Backup-Storage PV und PVC erstellen (PV zuerst!)
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $job_name-pv
  labels:
    type: nfs
    app: k8s-backup
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: "$STORAGE_CLASS"
  nfs:
    server: $NFS_SERVER
    path: $NFS_PATH
  claimRef:
    namespace: $namespace
    name: $job_name-pvc
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $job_name-pvc
  namespace: $namespace
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: "$STORAGE_CLASS"
  resources:
    requests:
      storage: 5Gi
  selector:
    matchLabels:
      type: nfs
      app: k8s-backup
EOF

    # Kurz warten bis PVC gebunden ist
    log "INFO" "Warte bis PVC $job_name-pvc gebunden ist..."
    kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/$job_name-pvc -n "$namespace" --timeout=60s

    # Backup-Job erstellen
    cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: $job_name
  namespace: $namespace
spec:
  template:
    spec:
      serviceAccountName: backup-service-account
      containers:
      - name: backup
        image: $BACKUP_IMAGE
        command: ["/bin/sh"]
        args:
        - "-c"
        - |
          echo "Starte Backup für PVC $pvc_name"
          echo "Verfügbare Dateien in /data:"
          ls -la /data/
          echo "Disk Usage:"
          du -sh /data/* 2>/dev/null || echo "Keine Dateien gefunden"
          echo "Backup läuft ..."
          
          # Backup-Verzeichnis erstellen falls nicht vorhanden
          mkdir -p /backup
          
          # Backup erstellen
          tar -czvf /backup/$pvc_name-\$(date +%Y%m%d-%H%M%S).tar.gz /data/
          
          echo "Backup für $pvc_name abgeschlossen"
          echo "Backup-Dateien:"
          ls -la /backup/
        volumeMounts:
        - name: data
          mountPath: /data
        - name: backup-storage
          mountPath: /backup
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: $pvc_name
      - name: backup-storage
        persistentVolumeClaim:
          claimName: $job_name-pvc
      restartPolicy: Never
  backoffLimit: 3
EOF

    # Warten bis Job abgeschlossen ist
    log "INFO" "Warte auf Abschluss des Backup-Jobs..."
    kubectl wait --for=condition=complete job/$job_name -n "$namespace" --timeout=1800s
    
    # Job-Logs anzeigen
    log "INFO" "Backup-Job Logs:"
    kubectl logs job/$job_name -n "$namespace" | tee -a "$LOG_FILE"
    
    # Job aufräumen aber PV/PVC für Backup behalten
    kubectl delete job/$job_name -n "$namespace"
    
    log "INFO" "Backup für PVC $pvc_name abgeschlossen"
}

# Hauptfunktion
main() {
    log "INFO" "Starte PV-Backup-Prozess"
    
    # Umgebung validieren
    validate_environment
    
    # Prüfen ob kubectl verfügbar ist
    if ! command -v kubectl &> /dev/null; then
        log "ERROR" "kubectl ist nicht installiert oder nicht im PATH"
        exit 1
    fi
    
    # Prüfen ob jq verfügbar ist
    if ! command -v jq &> /dev/null; then
        log "ERROR" "jq ist nicht installiert"
        exit 1
    fi
    
    # Erstelle globale RBAC-Ressourcen (einmalig)
    log "INFO" "Erstelle globale RBAC-Ressourcen..."
    cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: full-backup-role
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["*"]
EOF
    
    # Alle PVs abrufen
    log "INFO" "Sammle alle Persistent Volumes..."
    local pvs=$(kubectl get pv -o jsonpath='{.items[*].metadata.name}')
    
    if [[ -z "$pvs" ]]; then
        log "WARN" "Keine Persistent Volumes gefunden"
        exit 0
    fi
    
    local pv_count=$(echo "$pvs" | wc -w)
    log "INFO" "Gefunden: $pv_count Persistent Volumes"
    
    local current=0
    
    # Durch alle PVs iterieren
    for pv in $pvs; do
        current=$((current + 1))
        log "INFO" "===== Verarbeite PV $current/$pv_count: $pv ====="
        
        # Prüfen ob es sich um ein Backup-Volume handelt (anhand Labels)
        local backup_labels=$(kubectl get pv "$pv" -o jsonpath='{.metadata.labels.app}{.metadata.labels.type}')
        if [[ "$backup_labels" == "k8s-backupnfs" ]]; then
            log "INFO" "PV $pv ist ein Backup-Volume - überspringe"
            continue
        fi
        
        # PVC-Informationen abrufen
        local pvc_info=$(kubectl get pv "$pv" -o jsonpath='{.spec.claimRef.name} {.spec.claimRef.namespace}')
        
        if [[ -z "$pvc_info" || "$pvc_info" == " " ]]; then
            log "INFO" "PV $pv hat keine PVC-Bindung - überspringe"
            continue
        fi
        
        local pvc_name=$(echo "$pvc_info" | cut -d' ' -f1)
        local pvc_namespace=$(echo "$pvc_info" | cut -d' ' -f2)
        
        # Zusätzliche Prüfung: Backup-PVCs anhand des Namens ausschließen
        if [[ "$pvc_name" =~ ^backup-.*-pvc$ ]]; then
            log "INFO" "PVC $pvc_name ist ein Backup-PVC - überspringe"
            continue
        fi
        
        log "INFO" "PVC: $pvc_name in Namespace: $pvc_namespace"
        
        # Prüfen ob PVC existiert
        if ! kubectl get pvc "$pvc_name" -n "$pvc_namespace" &>/dev/null; then
            log "WARN" "PVC $pvc_name existiert nicht in Namespace $pvc_namespace - überspringe"
            continue
        fi
        
        # Pods finden, die das PVC nutzen
        local pods=$(find_pods_using_pvc "$pvc_name" "$pvc_namespace")
        
        # Access Mode des PVCs prüfen
        local access_modes=$(kubectl get pvc "$pvc_name" -n "$pvc_namespace" -o jsonpath='{.spec.accessModes[*]}')
        log "INFO" "PVC $pvc_name hat Access Modes: $access_modes"
        
        if [[ -z "$pods" ]]; then
            log "INFO" "Keine Pods nutzen PVC $pvc_name - erstelle direktes Backup"
            create_backup_job "$pvc_name" "$pvc_namespace"
            continue
        fi
        
        log "INFO" "Pods die PVC $pvc_name nutzen: $(echo "$pods" | tr '\n' ' ')"
        
        # Prüfen ob ReadWriteMany - dann können Pods weiterlaufen
        if [[ "$access_modes" == *"ReadWriteMany"* ]]; then
            log "INFO" "PVC $pvc_name hat ReadWriteMany Access Mode - Pods können weiterlaufen"
            create_backup_job "$pvc_name" "$pvc_namespace"
            continue
        fi
        
        log "INFO" "PVC $pvc_name hat ReadWriteOnce/ReadOnlyMany - Pods müssen gestoppt werden"
        
        # Controllers und deren Replicas sammeln (ohne assoziative Arrays)
        local controllers_file=$(mktemp)
        local replicas_file=$(mktemp)
        
        for pod in $pods; do
            local controller=$(get_pod_controller "$pod" "$pvc_namespace")
            if [[ "$controller" != "none" ]]; then
                # Prüfen ob Controller bereits in der Liste ist
                if ! grep -q "^$controller$" "$controllers_file" 2>/dev/null; then
                    local current_replicas=$(get_current_replicas "$controller" "$pvc_namespace")
                    echo "$controller" >> "$controllers_file"
                    echo "$current_replicas" >> "$replicas_file"
                    log "INFO" "Controller gefunden: $controller mit $current_replicas Replicas"
                fi
            fi
        done
        
        # Controllers auf 0 skalieren
        while IFS= read -r controller; do
            if [[ -n "$controller" ]]; then
                scale_controller "$controller" "$pvc_namespace" "0"
            fi
        done < "$controllers_file"
        
        # Kurz warten bis alle Pods gestoppt sind
        sleep 15
        
        # Backup durchführen
        create_backup_job "$pvc_name" "$pvc_namespace"
        
        # Controllers wieder auf ursprüngliche Werte skalieren
        local line_num=1
        while IFS= read -r controller; do
            if [[ -n "$controller" ]]; then
                local original_replicas=$(sed -n "${line_num}p" "$replicas_file")
                scale_controller "$controller" "$pvc_namespace" "$original_replicas"
                line_num=$((line_num + 1))
            fi
        done < "$controllers_file"
        
        # Temporäre Dateien aufräumen
        rm -f "$controllers_file" "$replicas_file"
        
        log "INFO" "Backup für PV $pv abgeschlossen"
    done
    
    log "INFO" "===== Alle PV-Backups abgeschlossen ====="
    log "INFO" "Logfile: $LOG_FILE"
    
    # Optional: Cleanup aller temporären ClusterRoleBindings
    log "INFO" "Cleanup: Entferne temporäre ClusterRoleBindings..."
    kubectl get clusterrolebinding -o name | grep "backup-service-account-binding-" | xargs kubectl delete 2>/dev/null || true
}

# Script ausführen
main "$@"