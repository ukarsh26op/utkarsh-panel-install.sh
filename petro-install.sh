cat > ~/install-panel.sh << 'INSTALLER_END'
#!/usr/bin/env bash
# =====================================================
#  Pterodactyl Panel + Blueprint installer
#  Made by Utkarsh
#  Usage:  bash install-panel.sh            -> install / start
#          bash install-panel.sh --reset    -> DELETE everything and reinstall
#  Optional env vars: PANEL_URL, CF_TOKEN, PANEL_IMAGE,
#                     ADMIN_EMAIL, ADMIN_USER, ADMIN_PASS, WAIT_TRIES
# =====================================================
set -euo pipefail

DIR="$HOME/pterodactyl"
PORT=80
IMAGE="${PANEL_IMAGE:-ghcr.io/blueprintframework/blueprint:latest}"
WAIT_TRIES="${WAIT_TRIES:-10}"   # x 3 seconds
TOTAL=9
N=0

# ---------- colors ----------
RED=$'\033[1;31m'; GREEN=$'\033[1;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[1;34m'
MAGENTA=$'\033[1;35m'; CYAN=$'\033[1;36m'; WHITE=$'\033[1;37m'; DIM=$'\033[2m'; NC=$'\033[0m'

step() { N=$((N+1)); printf '\n%s[%d/%d]%s %s%s%s\n' "$MAGENTA" "$N" "$TOTAL" "$NC" "$CYAN" "$*" "$NC"; }
ok()   { printf '   %s✔%s %s\n' "$GREEN" "$NC" "$*"; }
info() { printf '   %s➜%s %s\n' "$BLUE" "$NC" "$*"; }
warn() { printf '   %s!%s %s%s%s\n' "$YELLOW" "$NC" "$YELLOW" "$*" "$NC"; }
die()  { printf '\n%s✘ ERROR:%s %s\n' "$RED" "$NC" "$*"; exit 1; }

banner() {
  local rows colors i
  mapfile -t rows <<'BANNER'
 _   _  _____  _  __    _     ____   ____   _   _ 
| | | ||_   _|| |/ /   / \   |  _ \ / ___| | | | |
| | | |  | |  | ' /   / _ \  | |_) |\___ \ | |_| |
| |_| |  | |  | . \  / ___ \ |  _ < ___) ||  _  |
 \___/   |_|  |_|\_\/_/   \_\|_| \_\|____/ |_| |_|
BANNER
  colors=("$RED" "$YELLOW" "$GREEN" "$CYAN" "$MAGENTA")
  clear 2>/dev/null || true
  echo
  for i in "${!rows[@]}"; do printf '%s%s%s\n' "${colors[$i]}" "${rows[$i]}" "$NC"; done
  echo
  printf '   %sPterodactyl Panel + Blueprint%s  %s|%s  %sinstaller by Utkarsh%s\n' "$WHITE" "$NC" "$DIM" "$NC" "$YELLOW" "$NC"
  printf '   %s%s%s\n' "$BLUE" "----------------------------------------------------" "$NC"
}

banner

# ---------- 1. checks ----------
step "Checking requirements"
command -v docker >/dev/null || die "docker not found"
docker compose version >/dev/null 2>&1 || die "docker compose plugin not found"
command -v openssl >/dev/null || die "openssl not found"
ok "docker, docker compose and openssl found"

mkdir -p "$DIR"; cd "$DIR"

if [[ "${1:-}" == "--reset" ]]; then
  warn "RESET: deleting containers AND volumes (database + panel files)"
  docker compose down --volumes --remove-orphans 2>/dev/null || true
  rm -f .env.secrets credentials.txt docker-compose.yml
fi
docker compose down --remove-orphans 2>/dev/null || true

# ---------- 2. secrets + admin details ----------
step "Generating secrets and admin details"
if [[ ! -f .env.secrets ]]; then
  A_EMAIL="${ADMIN_EMAIL:-}"
  A_USER="${ADMIN_USER:-}"
  A_PASS="${ADMIN_PASS:-}"

  if [[ -t 0 ]]; then
    [[ -z "$A_EMAIL" ]] && { read -r -p "   Admin email    [admin@example.com]: " A_EMAIL || true; }
    [[ -z "$A_USER" ]]  && { read -r -p "   Admin username [admin]: " A_USER || true; }
    [[ -z "$A_PASS" ]]  && { read -r -s -p "   Admin password [blank = random]: " A_PASS || true; echo; }
  fi
  A_EMAIL="${A_EMAIL:-admin@example.com}"
  A_USER="${A_USER:-admin}"
  A_PASS="${A_PASS:-$(openssl rand -hex 8)}"

  {
    echo "DB_ROOT_PASS=$(openssl rand -hex 16)"
    echo "DB_PASS=$(openssl rand -hex 16)"
    echo "APP_KEY=base64:$(openssl rand -base64 32)"
    printf 'ADMIN_EMAIL=%q\n' "$A_EMAIL"
    printf 'ADMIN_USER=%q\n' "$A_USER"
    printf 'ADMIN_PASS=%q\n' "$A_PASS"
  } > .env.secrets
  chmod 600 .env.secrets
  ok "new random passwords created"
else
  ok "reusing existing secrets"
fi
source .env.secrets

# ---------- 3. url ----------
step "Detecting panel URL"
if [[ -n "${PANEL_URL:-}" ]]; then
  APP_URL="$PANEL_URL"
elif [[ -n "${CODESPACE_NAME:-}" ]]; then
  APP_URL="https://${CODESPACE_NAME}-${PORT}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-app.github.dev}"
else
  APP_URL="http://localhost:${PORT}"
fi
ok "Panel URL: ${WHITE}${APP_URL}${NC}"

# ---------- 4. compose file ----------
step "Writing docker-compose.yml"

# Fix: panel's mysql client demands SSL, but the local MariaDB has none
cat > client-ssl.cnf <<'EOF'
[client]
skip-ssl
EOF
cat > docker-compose.override.yml <<'EOF'
services:
  panel:
    volumes:
      - ./client-ssl.cnf:/etc/my.cnf.d/client-ssl.cnf:ro
EOF
ok "database SSL fix written"

cat > docker-compose.yml <<EOF
services:
  database:
    image: mariadb:10.11
    restart: unless-stopped
    network_mode: host
    command: --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci
    volumes:
      - db_data:/var/lib/mysql
    environment:
      MYSQL_ROOT_PASSWORD: "${DB_ROOT_PASS}"
      MYSQL_DATABASE: "panel"
      MYSQL_USER: "pterodactyl"
      MYSQL_PASSWORD: "${DB_PASS}"
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 5s
      timeout: 5s
      retries: 30

  cache:
    image: redis:7-alpine
    restart: unless-stopped
    network_mode: host
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 20

  panel:
    image: ${IMAGE}
    restart: unless-stopped
    depends_on:
      database:
        condition: service_healthy
      cache:
        condition: service_healthy
    network_mode: host
    volumes:
      - panel_app:/app
      - panel_var:/app/var
    environment:
      APP_ENV: "production"
      APP_DEBUG: "false"
      APP_KEY: "${APP_KEY}"
      APP_URL: "${APP_URL}"
      APP_TIMEZONE: "UTC"
      APP_SERVICE_AUTHOR: "${ADMIN_EMAIL}"
      DB_HOST: "127.0.0.1"
      DB_PORT: "3306"
      DB_DATABASE: "panel"
      DB_USERNAME: "pterodactyl"
      DB_PASSWORD: "${DB_PASS}"
      CACHE_DRIVER: "redis"
      SESSION_DRIVER: "redis"
      QUEUE_CONNECTION: "redis"
      REDIS_HOST: "127.0.0.1"
      REDIS_PORT: "6379"
      TRUSTED_PROXIES: "*"
      RECAPTCHA_ENABLED: "false"
EOF

if [[ -n "${CF_TOKEN:-}" ]]; then
cat >> docker-compose.yml <<EOF

  cloudflared:
    image: cloudflare/cloudflared:latest
    restart: unless-stopped
    network_mode: host
    depends_on:
      - panel
    command: tunnel --no-autoupdate run
    environment:
      TUNNEL_TOKEN: "${CF_TOKEN}"
EOF
  ok "Cloudflare tunnel enabled"
fi

cat >> docker-compose.yml <<'EOF'

volumes:
  db_data:
  panel_app:
  panel_var:
EOF
ok "compose file ready"

# ---------- 5. pull ----------
step "Pulling images (large, be patient)"
docker compose pull || die "Image pull failed. Retry with: PANEL_IMAGE=ghcr.io/pterodactyl/panel:latest bash install-panel.sh"
ok "images pulled"

# ---------- 6. start ----------
step "Starting containers"
docker compose up -d
ok "containers started"

# ---------- 7. wait ----------
step "Waiting for the panel on port ${PORT} (up to $((WAIT_TRIES*3)) sec)"
ok_ready=0
printf '   '
for i in $(seq 1 "$WAIT_TRIES"); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/auth/login" || true)
  if [[ "$code" == "200" || "$code" == "302" ]]; then ok_ready=1; break; fi
  printf '%s.%s' "$YELLOW" "$NC"
  sleep 3
done
echo
if [[ $ok_ready -eq 1 ]]; then
  ok "panel is answering"
else
  warn "Panel not answering yet (still migrating?). Continuing anyway."
fi

BUNDLE=$(docker compose exec -T panel sh -c 'ls /app/public/assets/bundle.*.js 2>/dev/null | head -1 | xargs -n1 basename' || true)
if [[ -n "$BUNDLE" ]]; then
  ctype=$(curl -sI "http://127.0.0.1:${PORT}/assets/${BUNDLE}" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-type"{print $2}')
  if [[ "$ctype" == *javascript* ]]; then ok "assets served correctly (${ctype})"; else warn "assets not served as JavaScript (${ctype:-none})"; fi
fi

# ---------- 8. admin ----------
step "Creating admin user (${ADMIN_USER})"
created=0
for i in $(seq 1 20); do
  if docker compose exec -T panel php artisan p:user:info --email="${ADMIN_EMAIL}" >/dev/null 2>&1; then
    ok "admin user already exists"; created=1; break
  fi
  if docker compose exec -T panel php artisan p:user:make \
      --email="${ADMIN_EMAIL}" --username="${ADMIN_USER}" \
      --name-first=Admin --name-last=Utkarsh \
      --password="${ADMIN_PASS}" --admin=1 >/dev/null 2>&1; then
    ok "admin user created"; created=1; break
  fi
  info "database not ready yet, retrying ($i/20)..."
  sleep 3
done
if [[ $created -ne 1 ]]; then
  warn "Admin creation failed. Run: cd ${DIR} && docker compose exec panel php artisan p:user:make"
fi

# ---------- 9. blueprint ----------
step "Checking Blueprint"
if docker compose exec -T panel sh -c 'command -v blueprint' >/dev/null 2>&1; then
  BP="${GREEN}installed${NC}"
  ok "blueprint command found"
else
  BP="${RED}NOT FOUND (stock panel image)${NC}"
  warn "blueprint command not found"
fi

if [[ -n "${CODESPACE_NAME:-}" ]] && command -v gh >/dev/null; then
  gh codespace ports visibility "${PORT}:public" -c "$CODESPACE_NAME" >/dev/null 2>&1 \
    && info "port ${PORT} set to Public" \
    || warn "Set port ${PORT} to Public manually in the Ports tab"
fi

cat > credentials.txt <<EOF
URL:      ${APP_URL}
Email:    ${ADMIN_EMAIL}
Username: ${ADMIN_USER}
Password: ${ADMIN_PASS}
EOF
chmod 600 credentials.txt

# ---------- done ----------
echo
printf '%s============================================================%s\n' "$GREEN" "$NC"
printf '  %s✔ INSTALL COMPLETE%s   %s(made by Utkarsh)%s\n' "$GREEN" "$NC" "$YELLOW" "$NC"
printf '%s============================================================%s\n' "$GREEN" "$NC"
printf '  %sURL       :%s %s\n' "$CYAN" "$NC" "$APP_URL"
printf '  %sEmail     :%s %s\n' "$CYAN" "$NC" "$ADMIN_EMAIL"
printf '  %sUsername  :%s %s\n' "$CYAN" "$NC" "$ADMIN_USER"
printf '  %sPassword  :%s %s%s%s\n' "$CYAN" "$NC" "$YELLOW" "$ADMIN_PASS" "$NC"
printf '  %sBlueprint :%s %s\n' "$CYAN" "$NC" "$BP"
printf '  %sSaved in  :%s %s/credentials.txt\n' "$CYAN" "$NC" "$DIR"
printf '%s============================================================%s\n' "$GREEN" "$NC"
echo
printf '%sInstall an extension:%s\n' "$MAGENTA" "$NC"
echo "  cd ${DIR} && docker compose cp myext.blueprint panel:/app/"
echo "  cd ${DIR} && docker compose exec panel blueprint -install myext"
printf '%sLogs:%s  cd %s && docker compose logs -f panel\n\n' "$MAGENTA" "$NC" "$DIR"
INSTALLER_END
bash ~/install-panel.sh --reset
