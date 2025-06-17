# Kubernetes PV Backup Script - Anwender-Dokumentation

## Was macht das Script?

Das Backup-Script erstellt automatisch Sicherungskopien von allen Daten, die in Kubernetes Persistent Volumes gespeichert sind. Es durchläuft dabei den gesamten Cluster und sichert jedes gefundene Volume auf einen zentralen NFS-Server.

## Wie funktioniert das Script?

### 1. Vorbereitung
Das Script prüft zunächst, ob alle benötigten Programme verfügbar sind und erstellt die notwendigen Berechtigungen für die Backup-Vorgänge.

### 2. Volume-Erkennung
Es sammelt alle Persistent Volumes im Cluster und filtert bereits vorhandene Backup-Volumes heraus, um Endlosschleifen zu vermeiden.

### 3. Intelligente Backup-Strategie

**Für jeden gefundenen Datenträger entscheidet das Script:**

#### ReadWriteMany Volumes (z.B. NFS-Shares)
- **Keine Unterbrechung:** Anwendungen laufen normal weiter
- **Direktes Backup:** Daten werden im laufenden Betrieb gesichert
- **Vorteil:** Null Downtime für die Anwendungen

#### ReadWriteOnce Volumes (z.B. Festplatten)
- **Kontrollierte Pause:** Anwendungen werden temporär gestoppt
- **Konsistentes Backup:** Daten werden in ruhendem Zustand gesichert
- **Automatischer Neustart:** Anwendungen werden nach dem Backup wieder gestartet

### 4. Der Backup-Prozess

Für jedes Volume:
1. **Backup-Job erstellen:** Ein temporärer Container wird gestartet
2. **Daten kopieren:** Volume wird als tar.gz-Archiv auf NFS-Server gespeichert
3. **Aufräumen:** Backup-Job wird nach Abschluss entfernt

## Was benötigt das Script?

### Voraussetzungen
- Zugriff auf Kubernetes-Cluster mit Admin-Rechten
- NFS-Server für die Backup-Speicherung
- Installierte Programme: `kubectl` und `jq`

### Konfiguration
Vor der ersten Nutzung müssen Sie anpassen:
- **NFS-Server IP-Adresse** (derzeit: 10.0.10.7)
- **NFS-Pfad** (derzeit: /srv/nfs/k8s-pv/production/k8s-backup)

## Wie verwende ich das Script?

### Einfache Ausführung
```bash
./backup.sh
```

### Was passiert dabei?
1. Das Script startet und zeigt den Fortschritt an
2. Für jedes Volume wird angezeigt:
   - Welche Anwendungen das Volume nutzen
   - Ob eine Pause notwendig ist oder nicht
   - Backup-Fortschritt und Ergebnis
3. Am Ende erhalten Sie eine Zusammenfassung

### Überwachung während des Backups
```bash
# Live-Log verfolgen
tail -f /tmp/pv-backup-*.log

# Aktuelle Backup-Jobs anzeigen
kubectl get jobs --all-namespaces | grep backup
```

## Was macht das Script intelligent?

### Automatische Erkennung
- **Volume-Typen:** Erkennt automatisch, ob ein Volume gleichzeitig von mehreren Anwendungen genutzt werden kann
- **Anwendungs-Controller:** Findet heraus, welche Deployments, StatefulSets oder DaemonSets das Volume nutzen
- **Aktuelle Größe:** Ermittelt, wie viele Instanzen einer Anwendung laufen

### Minimale Ausfallzeiten
- **NFS/Shared Storage:** Kein Stopp der Anwendungen nötig
- **Block Storage:** Nur kurze, kontrollierte Pausen
- **Automatischer Neustart:** Anwendungen werden exakt so wiederhergestellt, wie sie vorher liefen

### Sicherheitsmechanismen
- **Backup-Loop-Vermeidung:** Sichert nie seine eigenen Backup-Volumes
- **Berechtigungsmanagement:** Erstellt temporäre, sichere Zugriffsrechte
- **Fehlerbehandlung:** Bricht bei Problemen ab, ohne Schäden zu verursachen

## Typische Anwendungsszenarien

### Nächtliche Vollsicherung
```bash
# In Crontab für automatische nächtliche Backups
0 2 * * * /pfad/zum/backup.sh
```

### Vor Wartungsarbeiten
```bash
# Manuell vor größeren Updates
./backup.sh
```

### Disaster Recovery Vorbereitung
Das Script erstellt konsistente Snapshots aller Daten, die für eine vollständige Wiederherstellung verwendet werden können.

## Was wird gesichert?

### Vollständige Datenträger
- Alle Dateien und Ordner im Volume
- Datei-Berechtigungen und Eigentümer
- Symlinks und spezielle Dateien

### Format der Backups
- **Dateiname:** `[volume-name]-[datum-uhrzeit].tar.gz`
- **Speicherort:** NFS-Server unter konfiguriertem Pfad
- **Komprimierung:** Automatische Größenreduktion

### Beispiel-Backup-Struktur
```
/srv/nfs/k8s-pv/production/k8s-backup/
├── database-pvc-20241217-143022.tar.gz
├── webapp-storage-20241217-143045.tar.gz
└── monitoring-data-20241217-143108.tar.gz
```

## Monitoring und Logs

### Log-Informationen
Das Script protokolliert detailliert:
- Gefundene Volumes und deren Status
- Welche Anwendungen gestoppt/gestartet werden
- Backup-Fortschritt und Erfolg
- Eventuelle Fehler oder Warnungen

### Beispiel-Log
```
[2024-12-17 14:30:15] Starte PV-Backup-Prozess
[2024-12-17 14:30:16] Gefunden: 8 Persistent Volumes
[2024-12-17 14:30:17] ===== Verarbeite PV 1/8: pvc-123456 =====
[2024-12-17 14:30:18] PVC: webapp-storage in Namespace: production
[2024-12-17 14:30:19] PVC webapp-storage hat ReadWriteOnce Access Mode - Pods müssen gestoppt werden
[2024-12-17 14:30:20] Controller gefunden: deployment/webapp mit 3 Replicas
[2024-12-17 14:30:21] Skaliere deployment/webapp auf 0 Replicas
[2024-12-17 14:30:35] Erstelle Backup-Job für PVC webapp-storage
[2024-12-17 14:31:45] Backup für webapp-storage abgeschlossen
[2024-12-17 14:31:46] Skaliere deployment/webapp auf 3 Replicas
```

## Häufige Fragen

### "Wie lange dauert ein Backup?"
- Abhängig von der Datenmenge
- Kleine Volumes (< 1GB): 1-2 Minuten
- Große Volumes (> 10GB): 10-30 Minuten
- Netzwerkgeschwindigkeit zum NFS-Server ist entscheidend

### "Werden meine Anwendungen gestoppt?"
- **ReadWriteMany Volumes:** Nein, laufen weiter
- **ReadWriteOnce Volumes:** Ja, aber nur kurzzeitig und automatisch wieder gestartet

### "Was passiert bei Fehlern?"
- Script bricht sicher ab
- Anwendungen werden wieder gestartet (falls gestoppt)
- Detaillierte Fehlermeldungen im Log
- Keine Datenverluste

### "Kann ich einzelne Volumes ausschließen?"
Ja, durch Anpassung des Scripts können Sie:
- Bestimmte Namespaces ausschließen
- Volumes nach Namen filtern
- Nach Storage-Klassen selektieren

## Wiederherstellung von Backups

### Backup-Dateien finden
```bash
# Auf dem NFS-Server
ls -la /srv/nfs/k8s-pv/production/k8s-backup/

# Nach bestimmtem Volume suchen
ls -la *webapp-storage*
```

### Manuelle Wiederherstellung
```bash
# Backup entpacken
tar -xzf webapp-storage-20241217-143045.tar.gz

# Inhalte prüfen
ls -la data/
```

### In Kubernetes wiederherstellen
Ein separates Restore-Script oder manuelle Wiederherstellung über temporäre Pods mit dem gleichen PVC.

## Wartung und Pflege

### Regelmäßige Aufgaben
- **Log-Dateien prüfen:** Auf Fehler oder Warnungen achten
- **Backup-Größe überwachen:** NFS-Server-Speicherplatz im Blick behalten
- **Test-Restores:** Gelegentlich Backups testweise wiederherstellen

### Alte Backups bereinigen
```bash
# Beispiel: Backups älter als 30 Tage löschen
find /srv/nfs/k8s-pv/production/k8s-backup/ -name "*.tar.gz" -mtime +30 -delete
```

## Erste Schritte

1. **Script herunterladen** und ausführbar machen
2. **NFS-Server-Adresse** im Script anpassen
3. **Test-Lauf** mit wenigen Volumes
4. **Logs prüfen** und Funktion bestätigen
5. **Automatisierung** einrichten (Crontab)
6. **Backup-Wiederherstellung** testen

Das Script ist darauf ausgelegt, sicher und automatisch zu funktionieren. Bei der ersten Nutzung sollten Sie jedoch die Logs aufmerksam verfolgen, um sich mit dem Ablauf vertraut zu machen.