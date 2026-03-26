#!/usr/bin/env bash
# =============================================================================
# ByteGrader Thinkific Client — Unified Deployment Script
# =============================================================================
# Reads all configuration from config.yaml — no interactive prompts.
#
# Usage:
#   sudo bash install.sh [--skip-bytegrader] [--skip-nginx] [--skip-build]
#
# Options:
#   --skip-bytegrader   Skip calling bytegrader/install.sh (ByteGrader already
#                       deployed and running).
#   --skip-nginx        Skip nginx and SSL setup. Client is reachable directly
#                       on CLIENT_PORT for pre-DNS testing. Once DNS is pointed
#                       at this server, re-run with --skip-build.
#   --skip-build        Skip Docker image build. Re-runs nginx and SSL config
#                       using the existing container. Use after DNS propagates.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}ℹ${NC}  $*"; }
success() { echo -e "${GREEN}✅${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $*"; }
die()     { echo -e "${RED}❌ ERROR:${NC} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

# ── Args ──────────────────────────────────────────────────────────────────────
SKIP_BYTEGRADER=false
SKIP_NGINX=false
SKIP_BUILD=false
for arg in "$@"; do
  case $arg in
    --skip-bytegrader) SKIP_BYTEGRADER=true ;;
    --skip-nginx)      SKIP_NGINX=true ;;
    --skip-build)      SKIP_BUILD=true ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

if [[ "$SKIP_NGINX" == true ]]; then
  BIND_ADDRESS="0.0.0.0"
else
  BIND_ADDRESS="127.0.0.1"
fi

[[ $EUID -ne 0 ]] && die "Run as root: sudo bash install.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/config.yaml"
[[ -f "$CONFIG" ]] || die "config.yaml not found at $SCRIPT_DIR"

# ── Step 1: Dependencies ──────────────────────────────────────────────────────
header "Step 1 — Installing Dependencies"

apt-get update -qq
apt-get install -y -qq \
  ca-certificates curl wget git nginx certbot python3-certbot-nginx python3-yaml \
  > /dev/null 2>&1
success "System packages ready"

if ! command -v docker &>/dev/null; then
  info "Installing Docker..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc 2>/dev/null
  chmod a+r /etc/apt/keyrings/docker.asc
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
     https://download.docker.com/linux/ubuntu \
     $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update -qq
  apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin \
    > /dev/null 2>&1
  success "Docker installed"
else
  success "Docker already installed"
fi

# ── Step 2: Read config ───────────────────────────────────────────────────────
header "Step 2 — Reading Configuration"

cfg() {
  python3 - "$1" <<'PYEOF'
import sys, yaml
key = sys.argv[1]
with open("config.yaml") as f:
    d = yaml.safe_load(f)
val = d.get(key, "")
if isinstance(val, list):
    print("\n".join(str(v) for v in val if v))
elif isinstance(val, dict):
    for k, v in val.items():
        print(f"{k}={v}")
elif val is None:
    print("")
else:
    print(str(val))
PYEOF
}

cd "$SCRIPT_DIR"

BYTEGRADER_PATH=$(cfg "bytegrader_path"); [[ -z "$BYTEGRADER_PATH" ]] && die "bytegrader_path is required in config.yaml"
BYTEGRADER_API_KEY=$(cfg "bytegrader_api_key"); [[ -z "$BYTEGRADER_API_KEY" ]] && die "bytegrader_api_key is required in config.yaml"
DOMAIN=$(cfg "domain");         [[ -z "$DOMAIN" ]]     && die "domain is required in config.yaml"
SUBDOMAIN=$(cfg "subdomain");   [[ -z "$SUBDOMAIN" ]]  && die "subdomain is required in config.yaml"
SSL_EMAIL=$(cfg "ssl_email");   [[ -z "$SSL_EMAIL" ]]  && die "ssl_email is required in config.yaml"
[[ "$SSL_EMAIL" == "you@example.com" ]] && die "Please set a real ssl_email in config.yaml"

RESEND_API_KEY=$(cfg "resend_api_key"); [[ -z "$RESEND_API_KEY" ]] && die "resend_api_key is required in config.yaml"
RESEND_FROM=$(cfg "resend_from");       [[ -z "$RESEND_FROM" ]]    && die "resend_from is required in config.yaml"
PASSING_SCORE=$(cfg "passing_score");   PASSING_SCORE="${PASSING_SCORE:-80.0}"
COURSE_B_URL=$(cfg "course_b_url");     [[ -z "$COURSE_B_URL" ]]   && die "course_b_url is required in config.yaml"
CLIENT_PORT=$(cfg "client_port");       CLIENT_PORT="${CLIENT_PORT:-8081}"
FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN}"

info "Domain:      $FULL_DOMAIN"
info "Repo dir:    $SCRIPT_DIR"
info "Client port: $CLIENT_PORT"
info "ByteGrader:  $BYTEGRADER_PATH"

# ── Step 3: Deploy ByteGrader ─────────────────────────────────────────────────
if [[ "$SKIP_BYTEGRADER" == true ]]; then
  header "Step 3 — ByteGrader (skipped)"
  warn "Skipping ByteGrader deployment — assuming it is already running."
else
  header "Step 3 — Deploying ByteGrader"
  [[ -f "$BYTEGRADER_PATH/install.sh" ]] || die "ByteGrader install.sh not found at $BYTEGRADER_PATH/install.sh"
  info "Calling ByteGrader install.sh..."
  bash "$BYTEGRADER_PATH/install.sh" --skip-nginx
  success "ByteGrader deployed"
fi

# ── Step 4: Deploy client ─────────────────────────────────────────────────────
header "Step 4 — Deploying Thinkific Client"

# Write .env for docker compose (standard vars)
cat > "$SCRIPT_DIR/.env" <<EOF
BIND_ADDRESS=${BIND_ADDRESS}
CLIENT_PORT=${CLIENT_PORT}
BYTEGRADER_URL=http://bytegrader:8080
BYTEGRADER_API_KEY=${BYTEGRADER_API_KEY}
RESEND_API_KEY=${RESEND_API_KEY}
RESEND_FROM=${RESEND_FROM}
PASSING_SCORE=${PASSING_SCORE}
COURSE_B_URL=${COURSE_B_URL}
EOF
chmod 600 "$SCRIPT_DIR/.env"
success "Written .env"

# Write coupons.env (loaded via env_file in docker-compose.yaml)
> "$SCRIPT_DIR/coupons.env"
while IFS='=' read -r key val; do
  [[ -z "$key" ]] && continue
  upper_key=$(echo "$key" | tr '[:lower:]' '[:upper:]')
  echo "COUPONS_${upper_key}=${val}" >> "$SCRIPT_DIR/coupons.env"
done < <(cfg "coupons")
chmod 600 "$SCRIPT_DIR/coupons.env"
success "Written coupons.env"

if [[ "$SKIP_BUILD" == false ]]; then
  docker compose down 2>/dev/null || true
  docker compose build --no-cache
  docker compose up -d
  success "Client container built and started"
else
  warn "--skip-build: bringing up existing container"
  docker compose up -d 2>/dev/null || true
fi

# Wait for healthy
info "Waiting for service..."
for i in $(seq 1 30); do
  if curl -sf "http://localhost:${CLIENT_PORT}/health" &>/dev/null; then
    success "Client is healthy"
    break
  fi
  sleep 2
  [[ $i -eq 30 ]] && die "Client did not become healthy. Check: cd $SCRIPT_DIR && docker compose logs"
done

# ── Step 5: nginx ─────────────────────────────────────────────────────────────
if [[ "$SKIP_NGINX" == true ]]; then
  header "Step 5 — Nginx (skipped)"
  warn "Client is reachable directly at:"
  warn "  http://<SERVER_IP>:${CLIENT_PORT}/health"
  warn "Once DNS is pointed at this server, re-run to configure nginx + SSL:"
  warn "  sudo bash install.sh --skip-bytegrader --skip-build"
else
  header "Step 5 — Configuring Nginx"

  cat > /etc/nginx/sites-available/thinkific-client <<NGINX_HTTP
# Thinkific client nginx config — generated by install.sh

server {
    listen 80;
    server_name ${FULL_DOMAIN};
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / {
        proxy_pass http://localhost:${CLIENT_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
        client_max_body_size 100M;
    }
}
NGINX_HTTP

  ln -sf /etc/nginx/sites-available/thinkific-client \
         /etc/nginx/sites-enabled/thinkific-client
  nginx -t && systemctl reload nginx
  success "Nginx configured (HTTP)"

# ── Step 6: Firewall ──────────────────────────────────────────────────────────
  header "Step 6 — Firewall"
  ufw allow OpenSSH    > /dev/null 2>&1
  ufw allow 'Nginx Full' > /dev/null 2>&1
  ufw delete allow "${CLIENT_PORT}/tcp" > /dev/null 2>&1 || true
  ufw --force enable   > /dev/null 2>&1
  success "Firewall: SSH + HTTP/HTTPS open"

# ── Step 7: SSL ───────────────────────────────────────────────────────────────
  header "Step 7 — SSL Certificate"

  SERVER_IP=$(curl -4 -sf https://ifconfig.me 2>/dev/null || true)
  RESOLVED_IP=$(getent hosts "$FULL_DOMAIN" 2>/dev/null | awk '{print $1}' || true)

  if [[ "$SERVER_IP" != "$RESOLVED_IP" ]]; then
    warn "DNS not ready: server is $SERVER_IP but $FULL_DOMAIN resolves to ${RESOLVED_IP:-nothing}"
    warn "Point your DNS A record to $SERVER_IP, wait for propagation, then re-run:"
    warn "  sudo bash install.sh --skip-bytegrader --skip-build"
  else
    certbot certonly \
      --nginx \
      --non-interactive \
      --agree-tos \
      -m "$SSL_EMAIL" \
      -d "$FULL_DOMAIN" || { warn "certbot failed — re-run after DNS propagates: sudo bash install.sh --skip-bytegrader --skip-build"; }

    if [[ -f "/etc/letsencrypt/live/${FULL_DOMAIN}/fullchain.pem" ]]; then
      cat > /etc/nginx/sites-available/thinkific-client <<NGINX_FULL
# Thinkific client nginx config — generated by install.sh

server {
    listen 80;
    server_name ${FULL_DOMAIN};
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$server_name\$request_uri; }
}

server {
    listen 443 ssl http2;
    server_name ${FULL_DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${FULL_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${FULL_DOMAIN}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload";

    location / {
        proxy_pass         http://localhost:${CLIENT_PORT};
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
        proxy_connect_timeout 10s;
        client_max_body_size 100M;
    }
}
NGINX_FULL
      nginx -t && systemctl reload nginx
      success "HTTPS enabled for https://$FULL_DOMAIN"

      (crontab -l 2>/dev/null | grep -v certbot; echo "0 12 * * * /usr/bin/certbot renew --quiet") | crontab -
      success "SSL auto-renewal configured"
    fi
  fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────
header "Installation Complete"

LOCAL=$(curl -sf "http://localhost:${CLIENT_PORT}/health" || echo "FAILED")
echo ""
echo -e "  ${GREEN}Local health:${NC}  $LOCAL"
echo ""

if [[ "$SKIP_NGINX" == true ]]; then
  SERVER_IP=$(curl -4 -sf https://ifconfig.me 2>/dev/null || echo "<SERVER_IP>")
  echo -e "  ${BOLD}Test endpoint:${NC}  http://${SERVER_IP}:${CLIENT_PORT}/health"
  echo ""
  echo -e "  ${YELLOW}Next steps:${NC}"
  echo -e "  1. Test the server directly via the URL above"
  echo -e "  2. Point DNS A record to: ${SERVER_IP}"
  echo -e "  3. Wait for DNS propagation, then run:"
  echo -e "     sudo bash install.sh --skip-bytegrader --skip-build"
else
  if [[ -f "/etc/letsencrypt/live/${FULL_DOMAIN}/fullchain.pem" ]]; then
    REMOTE=$(curl -sf "https://${FULL_DOMAIN}/health" 2>/dev/null || echo "not yet reachable")
    echo -e "  ${GREEN}Remote health:${NC} $REMOTE"
    echo ""
    echo -e "  ${BOLD}Endpoint:${NC}  https://${FULL_DOMAIN}"
  else
    echo -e "  ${YELLOW}SSL not yet configured.${NC} Re-run after DNS propagates:"
    echo -e "  sudo bash install.sh --skip-bytegrader --skip-build"
    echo ""
    echo -e "  ${BOLD}Endpoint (HTTP only):${NC}  http://${FULL_DOMAIN}"
  fi
fi

echo ""
echo -e "  ${BOLD}Logs:${NC}  cd $SCRIPT_DIR && docker compose logs -f"
echo ""
success "Thinkific client is live!"
