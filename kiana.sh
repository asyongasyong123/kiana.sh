#!/bin/bash
set -euo pipefail

# =========================================
# KIANA FULLY OPTIMIZED CLOUDSHELL DEPLOYER
# =========================================

# =========================
# COLORS
# =========================
GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

# ========================================
# VARIABLES
# ========================================
PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
REGION="${1:-us-central1}"
RAND=$(openssl rand -hex 3)
CLOUD_RUN_SERVICE_NAME="kiana-$RAND"
DOMAIN="www.google.com"
BUILD_DIR=$(mktemp -d)
# ========================================
# CLEANUP
# =========================

cleanup() {
    rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

# =========================
# HEADER
# =========================
clear
echo ""
echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}       SHELL DEPLOYER BY KIANA${NC}"
echo -e "${GREEN}     FINAL FIXED VERSION${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""
echo -e "${GREEN}✅ Using Region:${NC} $REGION"
echo ""

# =========================
# CHECK PROJECT
# =========================
if [ -z "$PROJECT_ID" ]; then
    echo -e "${RED}ERROR: No Google Cloud project set.${NC}"
    echo -e "Run: gcloud config set project YOUR_PROJECT_ID"
    exit 1
fi

# =========================
# ENABLE APIS
# =========================
echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}        ENABLING REQUIRED APIS${NC}"
echo -e "${CYAN}=========================================${NC}"
gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com --quiet

# =========================
# BILLING SELECT
# =========================
echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}          BILLING MODE${NC}"
echo -e "${CYAN}=========================================${NC}"
echo -e "1) REQUEST-BASED  |  2) INSTANCE-BASED"
while true; do
    read -p "Select [1-2]: " BILLING_CHOICE
    case $BILLING_CHOICE in
        1) BILLING_MODE="request"; break ;;
        2) BILLING_MODE="instance"; break ;;
        *) echo -e "${RED}Invalid choice!${NC}" ;;
    esac
done

# =========================
# RESOURCE SELECT
# =========================
echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}      RESOURCE SETTINGS${NC}"
echo -e "${CYAN}=========================================${NC}"
echo -e "${YELLOW}RECOMMENDED: 4Gi RAM + 4vCPU${NC}"

while true; do
    read -p "Memory [1=512Mi|2=1Gi|3=2Gi|4=4Gi|5=8Gi|6=16Gi|7=32Gi]: " MEM
    case $MEM in
        1) MEMORY="512Mi"; break ;;
        2) MEMORY="1Gi"; break ;;
        3) MEMORY="2Gi"; break ;;
        4) MEMORY="4Gi"; break ;;
        5) MEMORY="8Gi"; break ;;
        6) MEMORY="16Gi"; break ;;
        7) MEMORY="32Gi"; break ;;
    esac
done

while true; do
    read -p "vCPU [1=1|2=2|3=4|4=6|5=8]: " CPU_SEL
    case $CPU_SEL in
        1) CPU="1"; break ;;
        2) CPU="2"; break ;;
        3) CPU="4"; break ;;
        4) CPU="6"; break ;;
        5) CPU="8"; break ;;
    esac
done

CONCURRENCY="1000"
TIMEOUT="3600"
SPECIAL_MODE=$([ "$MEMORY" = "4Gi" ] && [ "$CPU" = "4" ] && echo "true" || echo "false")

# =========================
# INSTANCE COUNT
# =========================
while true; do
    read -p "Min Instances [0-1, default=0]: " MIN_INST
    MIN_INST=${MIN_INST:-0}
    [[ "$MIN_INST" =~ ^[0-1]$ ]] && break || echo -e "${RED}Only 0 or 1 allowed${NC}"
done

if [ "$SPECIAL_MODE" = "true" ]; then
    while true; do
        read -p "Max Instances [1-4, default=1]: " MAX_INST
        MAX_INST=${MAX_INST:-1}
        [[ "$MAX_INST" =~ ^[1-4]$ ]] && break || echo -e "${RED}Only 1-4 allowed${NC}"
    done
else
    while true; do
        read -p "Max Instances [0-2, default=0]: " MAX_INST
        MAX_INST=${MAX_INST:-0}
        [[ "$MAX_INST" =~ ^[0-2]$ ]] && break || echo -e "${RED}Only 0-2 allowed${NC}"
    done
fi

# =========================
# PREPARE BUILD FILES
# =========================
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR" || exit 1

# =========================
# XRAY CONFIG
# =========================
cat > config.json <<'EOF'
{
  "log": { "loglevel": "warning" },
  "policy": {
    "levels": {
      "0": {
        "handshake": 1,
        "connIdle": 86400,
        "uplinkOnly": 0,
        "downlinkOnly": 0,
        "bufferSize": 1048576
      }
    }
  },
  "inbounds": [
    {
      "tag": "trojan-ws",
      "port": 10001,
      "listen": "127.0.0.1",
      "protocol": "trojan",
      "settings": { "clients": [{"password": "kiana", "level": 0}] },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"], "routeOnly": true },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/tr-ws?ed=2560", "acceptForwardedFor": ["127.0.0.1"] },
        "sockopt": { "tcpNoDelay": true, "tcpFastOpen": true, "tcpKeepAlive": true, "tcpKeepAliveIdle": 30, "tcpKeepAliveInterval": 15 }
      }
    },
    {
      "tag": "vless-ws",
      "port": 10002,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [{"id": "a1b2c3d4-5678-40ef-98ab-cdef01234567", "level": 0}], "decryption": "none" },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"], "routeOnly": true },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vl-ws?ed=2560", "acceptForwardedFor": ["127.0.0.1"] },
        "sockopt": { "tcpNoDelay": true, "tcpFastOpen": true, "tcpKeepAlive": true, "tcpKeepAliveIdle": 30, "tcpKeepAliveInterval": 15 }
      }
    },
    {
      "tag": "ss-ws",
      "port": 10003,
      "listen": "127.0.0.1",
      "protocol": "shadowsocks",
      "settings": { "method": "chacha20-ietf-poly1305", "password": "kiana", "network": "tcp,udp" },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"], "routeOnly": true },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/ss-ws?ed=2560", "acceptForwardedFor": ["127.0.0.1"] },
        "sockopt": { "tcpNoDelay": true, "tcpFastOpen": true, "tcpKeepAlive": true, "tcpKeepAliveIdle": 30, "tcpKeepAliveInterval": 15 }
      }
    },
    {
      "tag": "vm-ws",
      "port": 10004,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": { "clients": [{"id": "b2c3d4e5-6789-41af-99bc-def012345678", "alterId": 0, "level": 0}] },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"], "routeOnly": true },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vm-ws?ed=2560", "acceptForwardedFor": ["127.0.0.1"] },
        "sockopt": { "tcpNoDelay": true, "tcpFastOpen": true, "tcpKeepAlive": true, "tcpKeepAliveIdle": 30, "tcpKeepAliveInterval": 15 }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": { "domainStrategy": "UseIPv4v6", "tcpKeepAliveIdle": 30, "tcpKeepAliveInterval": 15 }
    }
  ]
}
EOF

# =========================
# NGINX CONFIG
# =========================
cat > nginx.conf <<'EOF'
worker_processes auto;
worker_rlimit_nofile 65535;
worker_priority -10;

events {
    worker_connections 65535;
    use epoll;
    multi_accept on;
    accept_mutex off;
}

http {
    include mime.types;
    default_type application/octet-stream;

    sendfile on;
    tcp_nodelay on;
    tcp_nopush on;
    types_hash_max_size 2048;

    keepalive_timeout 86400;
    keepalive_requests 1000000;

    client_max_body_size 0;
    client_body_buffer_size 16k;

    proxy_buffering off;
    proxy_request_buffering off;
    proxy_cache off;
    proxy_http_version 1.1;

    proxy_connect_timeout 5s;
    proxy_send_timeout 86400s;
    proxy_read_timeout 86400s;

    server_tokens off;
    gzip on;
    gzip_comp_level 3;
    gzip_types text/plain application/json application/javascript;

    map $http_upgrade $connection_upgrade {
        default upgrade;
        '' close;
    }

    server {
        listen 8080 deferred reuseport;
        server_name _;

        location / {
            proxy_pass https://www.google.com;
            proxy_set_header Host www.google.com;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_ssl_server_name on;
            proxy_ssl_protocols TLSv1.2 TLSv1.3;
        }

        location /tr-ws {
            proxy_pass http://127.0.0.1:10001;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        location /vl-ws {
            proxy_pass http://127.0.0.1:10002;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        location /ss-ws {
            proxy_pass http://127.0.0.1:10003;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        location /vm-ws {
            proxy_pass http://127.0.0.1:10004;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }
    }
}
EOF

# =========================
# ENTRYPOINT
# =========================
cat > entrypoint.sh <<'EOF'
#!/bin/sh
/usr/local/bin/xray run -c /etc/xray.json &
sleep 2
exec /usr/local/openresty/bin/openresty -g 'daemon off;'
EOF
chmod +x entrypoint.sh

# =========================
# DOCKERFILE
# =========================
cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip \
 && unzip xray.zip xray geosite.dat geoip.dat \
 && chmod +x xray

FROM openresty/openresty:alpine-fat
RUN apk add --no-cache ca-certificates tzdata bash

COPY --from=builder /xray /usr/local/bin/xray
COPY --from=builder /geosite.dat /usr/local/share/xray/
COPY --from=builder /geoip.dat /usr/local/share/xray/
COPY config.json /etc/xray.json
COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /usr/local/bin/xray
RUN chmod +x /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
EOF

# =========================
# BUILD & DEPLOY
# =========================
echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}          BUILDING IMAGE${NC}"
echo -e "${CYAN}=========================================${NC}"
gcloud builds submit --tag gcr.io/$PROJECT_ID/$CLOUD_RUN_SERVICE_NAME . --quiet

BILLING_FLAGS=$([ "$BILLING_MODE" = "instance" ] && echo "--no-cpu-throttling" || echo "--cpu-throttling")

echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}         DEPLOYING CLOUD RUN${NC}"
echo -e "${CYAN}=========================================${NC}"
gcloud run deploy $CLOUD_RUN_SERVICE_NAME \
  --image gcr.io/$PROJECT_ID/$CLOUD_RUN_SERVICE_NAME \
  --platform managed --region "$REGION" --allow-unauthenticated \
  --port 8080 --memory $MEMORY --cpu $CPU --concurrency $CONCURRENCY \
  --timeout $TIMEOUT --min-instances $MIN_INST --max-instances $MAX_INST \
  --execution-environment gen2 --cpu-boost $BILLING_FLAGS --quiet

CLOUD_RUN_URL=$(gcloud run services describe $CLOUD_RUN_SERVICE_NAME --region="$REGION" --format='value(status.url)')

# =========================
# FINAL OUTPUT
# =========================
echo -e "\n${CYAN}=========================================${NC}"
echo -e "${GREEN}✅ DEPLOYMENT SUCCESSFUL${NC}"
echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}SERVICE NAME:${NC} $CLOUD_RUN_SERVICE_NAME"
echo -e "${GREEN}DEPLOYED REGION:${NC} $REGION"
echo -e "${GREEN}CLOUD RUN URL:${NC} $CLOUD_RUN_URL"
echo -e "\n${YELLOW}--- CONFIGURATION ---${NC}"
echo -e "${GREEN}🔹 TROJAN WS${NC}"
echo "   Password: kiana"
echo "   Path: /tr-ws"
echo -e "${GREEN}🔹 VLESS WS${NC}"
echo "   UUID: a1b2c3d4-5678-40ef-98ab-cdef01234567"
echo "   Path: /vl-ws"
echo -e "${GREEN}🔹 SHADOWSOCKS WS${NC}"
echo "   Password: kiana"
echo "   Method: chacha20-ietf-poly1305"
echo "   Path: /ss-ws"
echo -e "${GREEN}🔹 VMESS WS${NC}"
echo "   UUID: b2c3d4e5-6789-41af-99bc-def012345678"
echo "   AlterId: 0"
echo "   Path: /vm-ws"
echo -e "${CYAN}=========================================${NC}"
