cat > ~/utkarsh-installer.sh << 'INSTALLER_END'
#!/usr/bin/env bash
# =====================================================
#  UTKARSH INSTALLER - Pterodactyl Panel / Wings / Cloudflare
#  Made by Utkarsh
#
#  Usage:
#    bash utkarsh-installer.sh                 -> menu
#    bash utkarsh-installer.sh panel           -> install / start panel
#    bash utkarsh-installer.sh wings           -> install / start wings
#    bash utkarsh-installer.sh cloudflare      -> set tunnel token + auto-start
#    add --reset to panel/wings                -> DELETE everything, reinstall
#
#  Optional env vars:
#    Panel : PANEL_URL PANEL_IMAGE ADMIN_EMAIL ADMIN_USER ADMIN_PASS WAIT_TRIES
#    Wings : WINGS_PANEL_URL NODE_UUID TOKEN_ID WINGS_TOKEN
#    Both  : CF_TOKEN (Cloudflare tunnel token)
# =====================================================
set -Eeuo pipefail

BASE="$HOME/.utkarsh"                 # installer state (token, autostart log)
CONF="$BASE/config.env"
PANEL_DIR="$HOME/pterodactyl"
WINGS_DIR="$HOME/wings"
CF_NAME="utkarsh-cloudflared"
PORT=80
IMAGE="${PANEL_IMAGE:-ghcr.io/blueprintframework/blueprint:latest}"
WAIT_TRIES="${WAIT_TRIES:-10}"        # x 3 seconds
SELF="$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || true)"
TOTAL=1
N=0
RESET=0
ACTION=""

mkdir -p "$BASE"

for a in "$@"; do
  case "$a" in
    --reset) RESET=1 ;;
    --autostart|autostart) ACTION="autostart" ;;
    panel|wings|cloudflare) ACTION="$a" ;;
  esac
done

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
  printf '   %sPterodactyl Panel + Wings + Cloudflare%s  %s|%s  %sinstaller by Utkarsh%s\n' "$WHITE" "$NC" "$DIM" "$NC" "$YELLOW" "$NC"
  printf '   %s%s%s\n' "$BLUE" "----------------------------------------------------" "$NC"
}

# ---------- helpers ----------
# ask VAR "prompt" [default] [secret]
ask() {
  local __v="$1" __p="$2" __d="${3:-}" __s="${4:-}" __r=""
  if [[ -t 0 ]]; then
    if [[ "$__s" == "secret" ]]; then
      read -r -s -p "   $__p" __r || true; echo
    else
      read -r -p "   $__p" __r || true
    fi
  fi
  printf -v "$__v" '%s' "${__r:-$__d}"
}

conf_set() {
  local k="$1" v="$2" tmp
  tmp="$(mktemp)"
  if [[ -f "$CONF" ]]; then grep -v "^${k}=" "$CONF" > "$tmp" || true; fi
  printf '%s=%q\n' "$k" "$v" >> "$tmp"
  mv "$tmp" "$CONF"; chmod 600 "$CONF"
}

load_conf() {
  local env_cf="${CF_TOKEN:-}"
  if [[ -f "$CONF" ]]; then set +u; source "$CONF"; set -u; fi
  if [[ -n "$env_cf" ]]; then CF_TOKEN="$env_cf"; fi
  CF_TOKEN="${CF_TOKEN:-}"
  PANEL_APP_URL="${PANEL_APP_URL:-}"
  PANEL_DOMAIN="${PANEL_DOMAIN:-}"
}

docker_ready() { docker info >/dev/null 2>&1; }

need_docker() {
  command -v docker >/dev/null || die "docker not found"
  docker compose version >/dev/null 2>&1 || die "docker compose plugin not found"
}

# =====================================================
#  CLOUDFLARE  (one shared tunnel container for panel + wings)
# =====================================================
cf_run() {
  docker rm -f "$CF_NAME" >/dev/null 2>&1 || true
  docker run -d --name "$CF_NAME" --restart always --network host \
    -e TUNNEL_TOKEN="$CF_TOKEN" \
    cloudflare/cloudflared:latest tunnel --no-autoupdate run >/dev/null
}

cf_ensure() {
  [[ -n "${CF_TOKEN:-}" ]] || return 0
  local state
  state="$(docker inspect -f '{{.State.Running}}' "$CF_NAME" 2>/dev/null || echo missing)"
  case "$state" in
    true)  echo "cloudflared already running" ;;
    false) docker start "$CF_NAME" >/dev/null || cf_run ;;
    *)     cf_run ;;
  esac
  docker update --restart always "$CF_NAME" >/dev/null 2>&1 || true
}

install_autostart() {
  local dst="$BASE/installer.sh" rc
  if [[ -f "$SELF" && "$SELF" != "$dst" ]]; then
    cp -f "$SELF" "$dst"; chmod +x "$dst"
  fi
  if [[ ! -f "$dst" ]]; then
    warn "Could not install auto-start (installer copy missing)"
    return 0
  fi
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [[ "$rc" == *zshrc && ! -f "$rc" ]]; then continue; fi
    touch "$rc"
    if ! grep -q 'utkarsh-autostart' "$rc"; then
      printf '\n# utkarsh-autostart\n[ -f "$HOME/.utkarsh/installer.sh" ] && (nohup bash "$HOME/.utkarsh/installer.sh" --autostart >/dev/null 2>&1 &)\n' >> "$rc"
    fi
  done
  ok "auto-start enabled (Cloudflare + panel + wings come back when the Codespace starts)"
  info "log: $BASE/autostart.log"
}

# Asked at the START of every panel / wings install (token is visible so you can see the paste worked)
cf_prompt() {
  load_conf
  local new=""
  if [[ -n "$CF_TOKEN" ]]; then
    ask new "➔ Enter Cloudflare Tunnel Token [Enter = keep saved (...${CF_TOKEN: -6}), 'skip' = none]: "
  else
    ask new "➔ Enter Cloudflare Tunnel Token [Enter = skip]: "
  fi
  case "$new" in
    "")   ;;
    skip) CF_TOKEN=""; conf_set CF_TOKEN ""; info "Cloudflare disabled" ;;
    *)    CF_TOKEN="$new"; conf_set CF_TOKEN "$CF_TOKEN"; ok "token received (...${CF_TOKEN: -6})" ;;
  esac
  if [[ -n "$CF_TOKEN" && "$new" == "" ]]; then ok "using saved token"; fi
}

cloudflare_step() {
  step "Cloudflare tunnel + auto-start"
  load_conf
  if [[ -n "$CF_TOKEN" ]]; then
    if docker_ready && cf_run; then
      ok "cloudflared running (container: ${CF_NAME})"
    else
      warn "Could not start cloudflared now, auto-start will retry"
    fi
  else
    info "no token given, Cloudflare skipped (run option 3 later)"
  fi
  install_autostart
}

do_cloudflare() {
  TOTAL=3; N=0
  step "Checking requirements"
  need_docker
  ok "docker found"
  mkdir -p "$BASE"

  step "Cloudflare tunnel token"
  load_conf
  local new=""
  ask new "Cloudflare tunnel token [Enter = keep saved]: "
  if [[ -n "$new" ]]; then CF_TOKEN="$new"; fi
  [[ -n "$CF_TOKEN" ]] || die "No token saved or given"
  conf_set CF_TOKEN "$CF_TOKEN"
  if cf_run; then ok "cloudflared running (container: ${CF_NAME})"; else die "cloudflared failed to start"; fi

  step "Auto-start on Codespace start"
  install_autostart
  echo
  info "Tunnel public hostnames (set in Cloudflare dashboard):"
  info "  panel -> http://localhost:${PORT}"
  info "  wings -> http://localhost:8080"
}

# Runs silently every time a terminal opens (only does work when something is down)
do_autostart() {
  exec 9>"$BASE/autostart.lock"
  if command -v flock >/dev/null 2>&1; then flock -n 9 || exit 0; fi
  if [[ -f "$BASE/autostart.log" && "$(stat -c%s "$BASE/autostart.log" 2>/dev/null || echo 0)" -gt 1048576 ]]; then : > "$BASE/autostart.log"; fi
  exec >>"$BASE/autostart.log" 2>&1
  echo "=== $(date -u) autostart ==="
  load_conf
  command -v docker >/dev/null || { echo "docker not found"; exit 0; }

  local i
  for i in $(seq 1 45); do docker_ready && break; sleep 2; done
  docker_ready || { echo "docker not ready, giving up"; exit 0; }

  cf_ensure || echo "cloudflared failed"

  if [[ -f "$PANEL_DIR/docker-compose.yml" ]]; then
    (cd "$PANEL_DIR" && docker compose up -d) || echo "panel start failed"
    (cd "$PANEL_DIR" && docker compose ps -q | xargs -r docker update --restart always >/dev/null) || true
    for i in $(seq 1 30); do
      code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/auth/login" || true)"
      [[ "$code" == "200" || "$code" == "302" ]] && break
      sleep 3
    done
  fi

  if [[ -x "$WINGS_DIR/wings-ctl.sh" && -f "$WINGS_DIR/etc/pterodactyl/config.yml" ]]; then
    "$WINGS_DIR/wings-ctl.sh" start || echo "wings start failed"
  fi
  echo "=== done ==="
  exit 0
}

# =====================================================
#  1) PANEL + BLUEPRINT
# =====================================================
prompts_header() {
  echo
  printf '%s[⚙️] CONFIGURATION PROMPTS:%s\n' "$YELLOW" "$NC"
}

# Asked first, before anything is installed: tunnel token, domain, admin password
panel_prompts() {
  prompts_header
  cf_prompt
  local d="${PANEL_DOMAIN:-}"
  ask d "➔ Enter Panel Domain (e.g. site.com)${d:+ [Enter = keep ${d}]}: " "$d"
  d="${d#https://}"; d="${d#http://}"; d="${d%%/*}"
  PANEL_DOMAIN="$d"
  conf_set PANEL_DOMAIN "$PANEL_DOMAIN"
  P_PASS=""
  if [[ $RESET -eq 1 || ! -f "$PANEL_DIR/.env.secrets" ]]; then
    P_PASS="${ADMIN_PASS:-}"
    ask P_PASS "➔ Enter Custom Admin Password [Enter = random]: " "$P_PASS"
  else
    info "existing admin account kept (use --reset to set a new password)"
  fi
  echo
}

install_panel() {
  TOTAL=10; N=0
  local DIR="$PANEL_DIR"

  panel_prompts

  step "Checking requirements"
  need_docker
  command -v openssl >/dev/null || die "openssl not found"
  ok "docker, docker compose and openssl found"

  mkdir -p "$DIR"; cd "$DIR"

  if [[ $RESET -eq 1 ]]; then
    warn "RESET: deleting containers AND volumes (database + panel files)"
    docker compose down --volumes --remove-orphans 2>/dev/null || true
    rm -f .env.secrets credentials.txt docker-compose.yml
  fi
  docker compose down --remove-orphans 2>/dev/null || true

  # ---------- 2. secrets + admin details ----------
  step "Generating secrets and admin details"
  if [[ ! -f .env.secrets ]]; then
    local A_EMAIL="${ADMIN_EMAIL:-}" A_USER="${ADMIN_USER:-}" A_PASS="${P_PASS:-}"
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
  local APP_URL
  if [[ -n "${PANEL_URL:-}" ]]; then
    APP_URL="$PANEL_URL"
  elif [[ -n "$PANEL_DOMAIN" ]]; then
    APP_URL="https://${PANEL_DOMAIN}"
  elif [[ -n "${CODESPACE_NAME:-}" ]]; then
    APP_URL="https://${CODESPACE_NAME}-${PORT}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-app.github.dev}"
  else
    APP_URL="http://localhost:${PORT}"
  fi
  conf_set PANEL_APP_URL "$APP_URL"
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
    restart: always
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
    restart: always
    network_mode: host
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 20

  panel:
    image: ${IMAGE}
    restart: always
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

volumes:
  db_data:
  panel_app:
  panel_var:
EOF
  ok "compose file ready (Cloudflare runs as its own shared container)"

  # ---------- 5. pull ----------
  step "Pulling images (large, be patient)"
  docker compose pull || die "Image pull failed. Retry with: PANEL_IMAGE=ghcr.io/pterodactyl/panel:latest bash utkarsh-installer.sh panel"
  ok "images pulled"

  # ---------- 6. start ----------
  step "Starting containers"
  docker compose up -d
  ok "containers started"

  # ---------- 7. wait ----------
  step "Waiting for the panel on port ${PORT} (up to $((WAIT_TRIES*3)) sec)"
  local ok_ready=0 code i
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

  local BUNDLE ctype
  BUNDLE=$(docker compose exec -T panel sh -c 'ls /app/public/assets/bundle.*.js 2>/dev/null | head -1 | xargs -n1 basename' || true)
  if [[ -n "$BUNDLE" ]]; then
    ctype=$(curl -sI "http://127.0.0.1:${PORT}/assets/${BUNDLE}" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-type"{print $2}')
    if [[ "$ctype" == *javascript* ]]; then ok "assets served correctly (${ctype})"; else warn "assets not served as JavaScript (${ctype:-none})"; fi
  fi

  # ---------- 8. admin ----------
  step "Creating admin user (${ADMIN_USER})"
  local created=0
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
  local BP
  if docker compose exec -T panel sh -c 'command -v blueprint' >/dev/null 2>&1; then
    BP="${GREEN}installed${NC}"
    ok "blueprint command found"
  else
    BP="${RED}NOT FOUND (stock panel image)${NC}"
    warn "blueprint command not found"
  fi

  if [[ -n "${CODESPACE_NAME:-}" ]] && command -v gh >/dev/null; then
    if gh codespace ports visibility "${PORT}:public" -c "$CODESPACE_NAME" >/dev/null 2>&1; then
      info "port ${PORT} set to Public"
    else
      warn "Set port ${PORT} to Public manually in the Ports tab"
    fi
  fi

  cat > credentials.txt <<EOF
URL:      ${APP_URL}
Email:    ${ADMIN_EMAIL}
Username: ${ADMIN_USER}
Password: ${ADMIN_PASS}
EOF
  chmod 600 credentials.txt

  # ---------- 10. cloudflare + autostart ----------
  cloudflare_step

  # ---------- done ----------
  echo
  printf '%s============================================================%s\n' "$GREEN" "$NC"
  printf '  %s✔ PANEL INSTALL COMPLETE%s   %s(made by Utkarsh)%s\n' "$GREEN" "$NC" "$YELLOW" "$NC"
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
  printf '%sLogs:%s  cd %s && docker compose logs -f panel\n' "$MAGENTA" "$NC" "$DIR"
  printf '%sCloudflare tunnel -> panel origin:%s http://localhost:%s\n\n' "$MAGENTA" "$NC" "$PORT"
}

# =====================================================
#  2) WINGS  (no systemd, plain Codespaces process)
# =====================================================
wings_stop_all() {
  if [[ -x "$WINGS_DIR/wings-ctl.sh" ]]; then "$WINGS_DIR/wings-ctl.sh" stop >/dev/null 2>&1 || true; fi
  pkill -f "$WINGS_DIR/bin/wings" 2>/dev/null || true
}

install_wings() {
  TOTAL=7; N=0
  prompts_header
  cf_prompt
  local WCONF="$WINGS_DIR/etc/pterodactyl"
  local DATA_DIR="$WINGS_DIR/var/lib/pterodactyl"
  local LOG_DIR="$WINGS_DIR/var/log/pterodactyl"
  local RUN_DIR="$WINGS_DIR/run"
  local TMP_DIR="$WINGS_DIR/tmp"
  local BIN_DIR="$WINGS_DIR/bin"
  local CFG="$WCONF/config.yml"

  # ---------- 1. checks ----------
  step "Checking requirements"
  command -v curl >/dev/null || die "curl not found"
  need_docker
  docker_ready || warn "Docker daemon not accessible - servers cannot run until Docker works"
  local ARCH WINGS_ARCH
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64)        WINGS_ARCH="amd64" ;;
    aarch64|arm64) WINGS_ARCH="arm64" ;;
    *) die "Unsupported architecture: $ARCH" ;;
  esac
  ok "curl, docker found (arch: ${ARCH})"
  if [[ "${CODESPACES:-}" != "true" && -z "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]]; then
    warn "Not running inside GitHub Codespaces - continuing anyway"
  fi

  if [[ $RESET -eq 1 ]]; then
    warn "RESET: deleting ${WINGS_DIR} (config, volumes, backups)"
    wings_stop_all
    sleep 2
    rm -rf "$WINGS_DIR"
  else
    wings_stop_all
  fi
  mkdir -p "$BIN_DIR" "$WCONF" "$DATA_DIR/volumes" "$DATA_DIR/archives" "$DATA_DIR/backups" "$LOG_DIR" "$RUN_DIR" "$TMP_DIR"

  # ---------- 2. node details ----------
  step "Node configuration"
  local REUSE=0 W_URL="" W_UUID="" W_TID="" W_TOKEN=""
  if [[ -f "$CFG" && $RESET -eq 0 ]]; then
    REUSE=1
    ok "reusing existing config.yml (use --reset to enter new node details)"
  else
    load_conf
    W_URL="${WINGS_PANEL_URL:-$PANEL_APP_URL}"
    W_UUID="${NODE_UUID:-}"; W_TID="${TOKEN_ID:-}"; W_TOKEN="${WINGS_TOKEN:-}"
    if [[ -t 0 ]]; then
      ask W_URL   "Panel URL [${W_URL:-required}]: " "$W_URL"
      ask W_UUID  "Node UUID [${W_UUID:-required}]: " "$W_UUID"
      ask W_TID   "Token ID  [${W_TID:-required}]: " "$W_TID"
      if [[ -z "$W_TOKEN" ]]; then ask W_TOKEN "Token (hidden): " "" secret; fi
    fi
    W_URL="${W_URL%/}"
    [[ -n "$W_URL"   ]] || die "Panel URL cannot be empty"
    [[ -n "$W_UUID"  ]] || die "Node UUID cannot be empty"
    [[ -n "$W_TID"   ]] || die "Token ID cannot be empty"
    [[ -n "$W_TOKEN" ]] || die "Token cannot be empty"
    ok "node details received"
  fi

  # ---------- 3. binary ----------
  step "Downloading Wings binary"
  local WINGS_URL="https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${WINGS_ARCH}"
  local WINGS_TMP="$TMP_DIR/wings.download"
  curl -fL --retry 3 --retry-delay 2 "$WINGS_URL" -o "$WINGS_TMP" || die "Failed to download Wings"
  [[ -s "$WINGS_TMP" ]] || die "Downloaded Wings file is empty"
  chmod +x "$WINGS_TMP"
  mv -f "$WINGS_TMP" "$BIN_DIR/wings"      # atomic, avoids "Text file busy"
  local WV
  WV="$("$BIN_DIR/wings" version 2>/dev/null | head -n 1 || true)"
  [[ -n "$WV" ]] || die "Wings executable verification failed"
  ok "installed: ${WV}"

  # ---------- 4. config ----------
  step "Writing config.yml"
  if [[ $REUSE -eq 1 ]]; then
    ok "kept existing config.yml"
  else
    cat > "$CFG" <<EOF
debug: false

uuid: ${W_UUID}
token_id: ${W_TID}
token: ${W_TOKEN}

api:
  host: 0.0.0.0
  port: 8080
  ssl:
    enabled: false
    cert: ""
    key: ""
  disable_remote_download: false
  upload_limit: 100

system:
  root_directory: ${DATA_DIR}
  log_directory: ${LOG_DIR}
  data: ${DATA_DIR}/volumes
  archive_directory: ${DATA_DIR}/archives
  backup_directory: ${DATA_DIR}/backups
  tmp_directory: ${TMP_DIR}
  username: $(whoami)
  timezone: UTC

  user:
    rootless:
      enabled: false
      container_uid: $(id -u)
      container_gid: $(id -g)

    uid: $(id -u)
    gid: $(id -g)

docker:
  network:
    name: pterodactyl_nw

    interfaces:
      v4:
        subnet: 172.18.0.0/16
        gateway: 172.18.0.1

      v6:
        subnet: fdba:17c8:6c94::/64
        gateway: fdba:17c8:6c94::1

  domainname: ""
  registries: {}
  tmpfs_size: 100
  container_pid_limit: 512

  installer_limits:
    memory: 1024
    cpu: 100

  build:
    network: pterodactyl_nw

remote: ${W_URL}

remote_query:
  timeout: 30
  boot_servers_per_page: 50

allowed_mounts: []
allowed_origins: []

sftp:
  bind_address: 0.0.0.0
  bind_port: 2022
  read_only: false
EOF
    chmod 600 "$CFG"
    ok "config.yml created (permissions 600)"
  fi

  # ---------- 5. docker network ----------
  step "Docker network"
  if docker_ready; then
    if docker network inspect pterodactyl_nw >/dev/null 2>&1; then
      ok "pterodactyl_nw already exists"
    elif docker network create --driver bridge --subnet 172.18.0.0/16 --gateway 172.18.0.1 pterodactyl_nw >/dev/null 2>&1; then
      ok "pterodactyl_nw created"
    else
      warn "Could not create pterodactyl_nw manually - Wings will try itself"
    fi
  else
    warn "Docker not available, skipped"
  fi

  # ---------- 6. control script + start ----------
  step "Starting Wings"
  cat > "$WINGS_DIR/wings-ctl.sh" <<'WCTL'
#!/usr/bin/env bash
# Usage: wings-ctl.sh {start|stop|restart|status|logs}
set -Eeuo pipefail
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINGS="$BASE/bin/wings"
CONFIG="$BASE/etc/pterodactyl/config.yml"
LOG="$BASE/var/log/pterodactyl/wings.log"
PIDFILE="$BASE/run/wings.pid"
mkdir -p "$(dirname "$LOG")" "$(dirname "$PIDFILE")"

running()  { [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; }
api_code() { curl -s --max-time 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/api/system 2>/dev/null || true; }

do_start() {
  [[ -x "$WINGS" ]]   || { echo "ERROR: Wings binary missing."; exit 1; }
  [[ -f "$CONFIG" ]]  || { echo "ERROR: Wings config missing."; exit 1; }
  if running; then echo "Wings is already running (PID $(cat "$PIDFILE"))."; return 0; fi
  rm -f "$PIDFILE"
  echo "Starting Wings..."
  nohup "$WINGS" --config "$CONFIG" >>"$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  sleep 8
  if ! running; then
    echo "Wings failed to stay running. Last output:"
    tail -n 60 "$LOG" 2>/dev/null || true
    rm -f "$PIDFILE"
    exit 1
  fi
  local code; code="$(api_code)"
  if [[ "$code" == "000" || -z "$code" ]]; then
    echo "WARNING: process is up but API is not answering yet."
  else
    echo "Wings API is responding (HTTP $code; 401 is normal without auth)."
  fi
  echo "Wings started. PID $(cat "$PIDFILE") | log: $LOG"
}

do_stop() {
  if running; then
    local pid; pid="$(cat "$PIDFILE")"
    echo "Stopping Wings PID $pid..."
    kill "$pid" 2>/dev/null || true
    for _ in {1..20}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
    kill -9 "$pid" 2>/dev/null || true
  fi
  pkill -f "$WINGS" 2>/dev/null || true
  rm -f "$PIDFILE"
  echo "Wings stopped."
}

do_status() {
  echo "========================================"
  echo "        UTKARSH WINGS STATUS"
  echo "========================================"
  if running; then echo "STATUS : RUNNING (PID $(cat "$PIDFILE"))"; else echo "STATUS : STOPPED"; fi
  local code; code="$(api_code)"
  if [[ "$code" == "000" || -z "$code" ]]; then echo "API    : OFFLINE"; else echo "API    : ONLINE (HTTP $code)"; fi
  echo "CONFIG : $CONFIG"
  echo "LOG    : $LOG"
  echo "========================================"
}

case "${1:-status}" in
  start)   do_start ;;
  stop)    do_stop ;;
  restart) do_stop; do_start ;;
  status)  do_status ;;
  logs)    tail -f "$LOG" ;;
  *) echo "Usage: $0 {start|stop|restart|status|logs}"; exit 1 ;;
esac
WCTL
  chmod +x "$WINGS_DIR/wings-ctl.sh"
  ok "wings-ctl.sh created"

  if docker_ready; then
    if "$WINGS_DIR/wings-ctl.sh" start; then
      ok "Wings started"
    else
      warn "Wings did not start - check: ${WINGS_DIR}/wings-ctl.sh logs"
    fi
  else
    warn "Docker unavailable - Wings not started"
  fi

  # ---------- 7. cloudflare + autostart ----------
  cloudflare_step

  # ---------- done ----------
  echo
  printf '%s============================================================%s\n' "$GREEN" "$NC"
  printf '  %s✔ WINGS INSTALL COMPLETE%s   %s(made by Utkarsh)%s\n' "$GREEN" "$NC" "$YELLOW" "$NC"
  printf '%s============================================================%s\n' "$GREEN" "$NC"
  printf '  %sBinary    :%s %s/wings\n' "$CYAN" "$NC" "$BIN_DIR"
  printf '  %sConfig    :%s %s\n' "$CYAN" "$NC" "$CFG"
  printf '  %sLog       :%s %s/wings.log\n' "$CYAN" "$NC" "$LOG_DIR"
  printf '  %sControl   :%s %s/wings-ctl.sh {start|stop|restart|status|logs}\n' "$CYAN" "$NC" "$WINGS_DIR"
  printf '%s============================================================%s\n' "$GREEN" "$NC"
  echo
  printf '%sCloudflare tunnel -> wings origin:%s http://localhost:8080\n' "$MAGENTA" "$NC"
  printf '%sSFTP:%s port 2022 | %sDo NOT use systemctl/service - Wings is a normal process%s\n\n' "$MAGENTA" "$NC" "$DIM" "$NC"
}

# =====================================================
#  MENU / MAIN
# =====================================================
confirm_reset() {
  # $1 = path that proves an install exists
  if [[ $RESET -eq 0 && -e "$1" && -t 0 ]]; then
    local a=""
    ask a "Existing install found. DELETE it and reinstall from scratch? [y/N]: " "n"
    if [[ "$a" == [yY]* ]]; then RESET=1; fi
  fi
}

menu() {
  banner
  echo
  printf '   %s1)%s Pterodactyl Panel + Blueprint\n' "$GREEN" "$NC"
  printf '   %s2)%s Pterodactyl Wings\n' "$GREEN" "$NC"
  printf '   %s3)%s Cloudflare tunnel token + auto-start\n' "$GREEN" "$NC"
  printf '   %s0)%s Exit\n\n' "$RED" "$NC"
  local c=""
  printf '   Choose [0-3]: '
  read -r c 2>/dev/null </dev/tty || c=""
  case "$c" in
    1) ACTION="panel" ;;
    2) ACTION="wings" ;;
    3) ACTION="cloudflare" ;;
    *) echo; echo "   Bye."; exit 0 ;;
  esac
}

main() {
  if [[ "$ACTION" == "autostart" ]]; then do_autostart; fi

  if [[ -z "$ACTION" ]]; then menu; else banner; fi

  case "$ACTION" in
    panel)      confirm_reset "$PANEL_DIR/docker-compose.yml"; install_panel ;;
    wings)      confirm_reset "$WINGS_DIR/etc/pterodactyl/config.yml"; install_wings ;;
    cloudflare) do_cloudflare ;;
  esac
}

main
INSTALLER_END
bash ~/utkarsh-installer.sh
