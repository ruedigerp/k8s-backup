# Dockerfile
FROM alpine:3.22

# Installiere benötigte Pakete
RUN apk add --no-cache \
    bash \
    curl \
    jq \
    ca-certificates \
    && rm -rf /var/cache/apk/*

# Installiere kubectl (Multi-Arch)
ARG TARGETPLATFORM
RUN set -ex && \
    case ${TARGETPLATFORM} in \
        linux/amd64) ARCH=amd64 ;; \
        linux/arm64) ARCH=arm64 ;; \
        linux/arm/v7) ARCH=arm ;; \
        *) echo "Unsupported platform: ${TARGETPLATFORM}" && exit 1 ;; \
    esac && \
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl" \
    && chmod +x kubectl \
    && mv kubectl /usr/local/bin/

# Erstelle Arbeitsverzeichnis
WORKDIR /app

# Kopiere das Backup-Script
COPY k8s-backup.sh /app/backup.sh
RUN chmod +x /app/backup.sh

# Erstelle Log-Verzeichnis
RUN mkdir -p /var/log/backup

# Umgebungsvariablen
ENV BACKUP_IMAGE="busybox:latest"
ENV NFS_SERVER=""
ENV NFS_PATH="/srv/nfs/k8s-pv/production/k8s-backup"
ENV STORAGE_CLASS="nfs-client"
ENV LOG_LEVEL="info"

# Entrypoint
ENTRYPOINT ["/app/backup.sh"]