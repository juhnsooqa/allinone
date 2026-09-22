#!/usr/bin/env bash
#
# Combined Remnawave node setup script.
#
# Merges:
#   - https://github.com/herbalsomml/remnawave-guide   (manual guide -> automated: firewall, ICMP block,
#     nginx, certbot, remnanode docker-compose)
#   - https://github.com/juhnsooqa/servers              (fail2ban.sh, roscom.sh folded in directly;
#     node-accelerator and cascademod (=vladimir-kartamyshev/remnawave-reverse-proxy-pro) are unrelated
#     third-party installers and are only offered as optional external steps, not inlined)
#
# Run as root on a fresh Ubuntu/Debian VPS that will act as a Remnawave node.
#
#   sudo bash remnawave-node-setup.sh            # interactive menu
#   sudo bash remnawave-node-setup.sh full       # firewall + icmp + nginx + ssl + docker + remnanode
#   sudo bash remnawave-node-setup.sh fail2ban
#   sudo bash remnawave-node-setup.sh roscom
#   sudo bash remnawave-node-setup.sh psiphon         # Psiphon-выход для xray (psiphon/, из Chara-Freedom/vps-psiphon)
#
# После первого запуска на сервере есть команда `allinone` (всегда тянет свежую версию с GitHub).
#   sudo bash remnawave-node-setup.sh accelerator     # optional, 3rd-party
#   sudo bash remnawave-node-setup.sh reverse-proxy   # optional, 3rd-party

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; }

STATE_FILE="/root/.remnanode-setup.env"
NODE_DIR="/opt/remnanode"
REPO_RAW="https://raw.githubusercontent.com/juhnsooqa/allinone/main"
CLI_PATH="/usr/local/bin/allinone"

require_root() {
    if [ "$EUID" -ne 0 ]; then
        err "Запустите скрипт с правами root (sudo)."
        exit 1
    fi
}

ask() { # ask "prompt" varname [default]
    local prompt="$1" __var="$2" default="${3:-}" reply
    if [ -n "$default" ]; then
        read -rp "$prompt [$default]: " reply
        reply="${reply:-$default}"
    else
        read -rp "$prompt: " reply
        while [ -z "$reply" ]; do
            read -rp "$prompt (обязательно): " reply
        done
    fi
    printf -v "$__var" '%s' "$reply"
}

load_common_vars() {
    [ -f "$STATE_FILE" ] && source "$STATE_FILE"
    if [ -z "${DOMAIN:-}" ]; then
        ask "Домен ноды (например node1.example.com)" DOMAIN
    fi
    if [ -z "${EMAIL:-}" ]; then
        ask "Email для Let's Encrypt (пусто = без email)" EMAIL ""
    fi
    if [ -z "${SECRET_KEY:-}" ]; then
        ask "SECRET_KEY ноды из панели Remnawave" SECRET_KEY
    fi
    if [ -z "${NODE_PORT:-}" ]; then
        ask "Порт ноды (NODE_PORT, панель ходит на него)" NODE_PORT "2222"
    fi
    cat > "$STATE_FILE" <<EOF
DOMAIN="$DOMAIN"
EMAIL="$EMAIL"
SECRET_KEY="$SECRET_KEY"
NODE_PORT="$NODE_PORT"
EOF
    chmod 600 "$STATE_FILE"
}

### ---------------------------------------------------------------------
### 1. Firewall (remnawave-guide)
### ---------------------------------------------------------------------
setup_firewall() {
    load_common_vars
    log "Установка и настройка UFW..."
    apt update -y && apt install -y ufw
    ufw allow OpenSSH
    ufw allow "${NODE_PORT}/tcp"
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 9443/tcp
    ufw allow 44443/tcp
    ufw allow 44444/tcp
    ufw --force disable
    ufw --force enable
    log "UFW настроен и включён."
}

block_icmp() {
    log "Блокировка ICMP-запросов..."
    local f=/etc/ufw/before.rules
    cp "$f" "${f}.bak.$(date +%s)"

    local t
    for t in destination-unreachable time-exceeded parameter-problem echo-request source-quench; do
        sed -i "s/-A ufw-before-input -p icmp --icmp-type ${t} -j ACCEPT/-A ufw-before-input -p icmp --icmp-type ${t} -j DROP/" "$f"
    done
    for t in destination-unreachable time-exceeded parameter-problem echo-request; do
        sed -i "s/-A ufw-before-forward -p icmp --icmp-type ${t} -j ACCEPT/-A ufw-before-forward -p icmp --icmp-type ${t} -j DROP/" "$f"
    done

    ufw --force disable
    ufw --force enable
    log "ICMP заблокирован (бэкап правил: ${f}.bak.*)."
}

### ---------------------------------------------------------------------
### 2. nginx + заглушка + SSL (remnawave-guide)
### ---------------------------------------------------------------------
install_nginx() {
    log "Установка nginx mainline (nginx.org)..."
    apt update -y
    apt install -y curl gnupg2 ca-certificates lsb-release ubuntu-keyring
    curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/ubuntu $(lsb_release -cs) nginx" \
        | tee /etc/apt/sources.list.d/nginx.list >/dev/null
    printf 'Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n' \
        | tee /etc/apt/preferences.d/99nginx >/dev/null
    apt update -y
    apt install -y nginx
    systemctl enable --now nginx
    log "nginx установлен."
}

create_stub() {
    log "Создание страницы-заглушки..."
    mkdir -p /var/www/html/
    cat > /var/www/html/index.html <<'EOF'
<!DOCTYPE html>
<html>
    <head>
        <title>All good!</title>
    </head>
    <body>
        <h1>All good!</h1>
    </body>
</html>
EOF
}

issue_ssl() {
    load_common_vars
    log "Выпуск SSL-сертификата для ${DOMAIN}..."
    apt update -y
    apt install -y certbot python3-certbot-nginx

    local email_args=(--register-unsafely-without-email)
    [ -n "$EMAIL" ] && email_args=(--email "$EMAIL")

    # Старый xray.conf со ссылкой на несуществующий сертификат валит `nginx -t` внутри certbot.
    # configure_nginx всё равно перепишет его после выпуска.
    rm -f /etc/nginx/conf.d/xray.conf

    # certonly: только выпуск, SSL-конфиг пишет configure_nginx
    if ! certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos "${email_args[@]}"; then
        warn "certbot не смог выпустить сертификат автоматически."
        warn "Проверьте, что A-запись $DOMAIN указывает на этот сервер, затем выполните вручную:"
        warn "  certbot --nginx -d $DOMAIN"
        return 1
    fi
    log "Сертификат выпущен."
}

configure_nginx() {
    load_common_vars
    log "Запись /etc/nginx/conf.d/xray.conf..."
    cat > /etc/nginx/conf.d/xray.conf <<EOF
server {
    listen 443 ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    root /var/www/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location /xhttppath/ {
        proxy_pass http://unix:/dev/shm/xrxh.socket;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}

server {
    listen 9443 ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    root /var/www/html;
    index index.html;
}

server {
    listen 80;
    server_name ${DOMAIN};

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
    nginx -t && systemctl restart nginx
    log "nginx настроен и перезапущен."
}

### ---------------------------------------------------------------------
### 3. Docker + remnanode (remnawave-guide)
### ---------------------------------------------------------------------
install_docker() {
    if command -v docker &>/dev/null; then
        log "Docker уже установлен, пропускаю."
        return 0
    fi
    log "Установка Docker..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
}

setup_remnanode() {
    load_common_vars
    log "Установка remnanode в ${NODE_DIR}..."
    mkdir -p "$NODE_DIR"

    cat > "${NODE_DIR}/.env" <<EOF
NODE_PORT=${NODE_PORT}
SECRET_KEY=${SECRET_KEY}
EOF

    wget -qO "${NODE_DIR}/geoip.dat"   https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
    wget -qO "${NODE_DIR}/geosite.dat" https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat

    # NB: важно смонтировать именно /dev/shm целиком (а не только .env/.dat) -
    # xhttp-инбаунд слушает unix-сокет в /dev/shm внутри контейнера, и без этого
    # монтирования nginx на хосте не увидит сокет (502 Bad Gateway).
    cat > "${NODE_DIR}/docker-compose.yml" <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    volumes:
      - /dev/shm:/dev/shm
      - ${NODE_DIR}/geoip.dat:/opt/remnanode/geoip.dat
      - ${NODE_DIR}/geosite.dat:/opt/remnanode/geosite.dat
    env_file:
      - ${NODE_DIR}/.env
EOF

    (cd "$NODE_DIR" && docker compose up -d)
    log "remnanode запущен. Логи: docker compose -f ${NODE_DIR}/docker-compose.yml logs -f"

    write_panel_reference_files
}

# Справочные JSON для панели Remnawave (профиль ноды + xHTTP host extra).
# Reality-ключи панель генерирует сама - сюда они не подставляются.
write_panel_reference_files() {
    load_common_vars

    # Если стоит vps-psiphon - добавляем его SOCKS-аутбаунд и правило (только TCP: UDP psiphon не умеет).
    local psi_out="" psi_rule="" psi_bind psi_port
    if [ -r /etc/default/vps-psiphon ]; then
        read -r psi_bind psi_port < <(. /etc/default/vps-psiphon; echo "${BIND:-172.17.0.1} ${SOCKS_PORT:-1080}")
        psi_out=",
    { \"tag\": \"psiphon-out\", \"protocol\": \"socks\", \"settings\": { \"address\": \"${psi_bind}\", \"port\": ${psi_port} } }"
        psi_rule="
      { \"type\": \"field\", \"network\": \"tcp\", \"domain\": [\"geosite:openai\", \"geosite:google-gemini\"], \"outboundTag\": \"psiphon-out\" },"
    fi

    cat > "${NODE_DIR}/panel-profile.reference.json" <<EOF
{
  "log": { "loglevel": "info" },
  "dns": {
    "servers": [
      { "address": "94.140.14.14", "domains": ["geosite:geolocation-!cn"] },
      { "address": "94.140.15.15", "domains": ["geosite:geolocation-!cn"] }
    ]
  },
  "inbounds": [
    {
      "tag": "NODE_TCP",
      "port": 44443,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "sniffing": { "enabled": true, "routeOnly": false, "destOverride": ["http","tls","quic","fakedns"], "metadataOnly": false },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "tcpSettings": { "header": { "type": "none" }, "acceptProxyProtocol": false },
        "realitySettings": {
          "dest": "9443", "show": false, "xver": 0, "spiderX": "/",
          "shortIds": [""],
          "publicKey": "<ПУБЛИЧНЫЙ КЛЮЧ ИЗ ПАНЕЛИ>",
          "privateKey": "<ПРИВАТНЫЙ КЛЮЧ ИЗ ПАНЕЛИ>",
          "serverNames": ["${DOMAIN}"]
        }
      }
    },
    {
      "tag": "NODE_GRPC",
      "port": 44444,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "sniffing": { "enabled": true, "routeOnly": false, "destOverride": ["http","tls","quic","fakedns"], "metadataOnly": false },
      "streamSettings": {
        "network": "grpc",
        "security": "reality",
        "tcpSettings": { "header": { "type": "none" }, "acceptProxyProtocol": false },
        "realitySettings": {
          "dest": "9443", "show": false, "xver": 0, "spiderX": "/",
          "shortIds": [""],
          "publicKey": "<ПУБЛИЧНЫЙ КЛЮЧ ИЗ ПАНЕЛИ>",
          "privateKey": "<ПРИВАТНЫЙ КЛЮЧ ИЗ ПАНЕЛИ>",
          "serverNames": ["${DOMAIN}"]
        }
      }
    },
    {
      "tag": "NODE_XHTTP",
      "listen": "/dev/shm/xrxh.socket,0666",
      "protocol": "vless",
      "settings": { "clients": [], "fallbacks": [], "decryption": "none" },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "mode": "auto",
          "path": "/xhttppath/",
          "extra": {
            "noSSEHeader": true,
            "xPaddingBytes": "100-1000",
            "scMaxBufferedPosts": 30,
            "scMaxEachPostBytes": 1000000,
            "scStreamUpServerSecs": "20-80"
          }
        }
      }
    }
  ],
  "outbounds": [
    { "tag": "DIRECT", "protocol": "freedom" },
    { "tag": "BLOCK", "protocol": "blackhole" }${psi_out}
  ],
  "routing": {
    "rules": [${psi_rule}
      { "ip": ["ext:geoip.dat:ru"], "type": "field", "outboundTag": "DIRECT" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "BLOCK" }
    ],
    "domainStrategy": "IPIfNonMatch"
  }
}
EOF

    cat > "${NODE_DIR}/panel-xhttp-host-extra.reference.json" <<EOF
{
  "xmux": {
    "cMaxReuseTimes": 0,
    "maxConcurrency": "16-32",
    "maxConnections": 0,
    "hKeepAlivePeriod": 0,
    "hMaxRequestTimes": "600-900",
    "hMaxReusableSecs": "1800-3000"
  },
  "noGRPCHeader": false,
  "xPaddingBytes": "100-1000",
  "downloadSettings": {
    "port": 443,
    "address": "${DOMAIN}",
    "network": "xhttp",
    "security": "tls",
    "tlsSettings": {
      "alpn": ["h2", "http/1.1"],
      "show": false,
      "serverName": "${DOMAIN}",
      "fingerprint": "chrome",
      "allowInsecure": false
    },
    "xhttpSettings": { "path": "/xhttppath/" }
  },
  "scMaxEachPostBytes": 1000000,
  "scMinPostsIntervalMs": 30,
  "scStreamUpServerSecs": "20-80"
}
EOF
    cat > "${NODE_DIR}/panel-hosts.txt" <<EOF
Хосты в панели Remnawave (Хосты -> Создать). Для каждого выберите свой инбаунд и ноду.

[TCP]   инбаунд NODE_TCP
  Основные:    Адрес ${DOMAIN}   Порт 44443
  Расширенные: SNI ${DOMAIN}, "Переопределить SNI из адреса" ВКЛ, остальное пусто/по умолчанию

[XHTTP] инбаунд NODE_XHTTP
  Основные:    Адрес ${DOMAIN}   Порт 443
  Расширенные: SNI ${DOMAIN}, "Переопределить SNI из адреса" ВЫКЛ
               Хост ${DOMAIN}   Путь /xhttppath/
               Security Layer TLS   ALPN h2,http/1.1   Отпечаток chrome
  Xray Json & Raw -> xHTTP: содержимое panel-xhttp-host-extra.reference.json

[gRPC]  инбаунд NODE_GRPC
  Основные:    Адрес ${DOMAIN}   Порт 44444
  Расширенные: как у TCP (SNI ${DOMAIN}, переопределение SNI ВКЛ)
EOF
    cat "${NODE_DIR}/panel-hosts.txt"
    log "Справочные JSON для панели сохранены в ${NODE_DIR}/panel-*.reference.json, настройки хостов - ${NODE_DIR}/panel-hosts.txt"
    warn "Вставьте их вручную в настройки хостов/профиля Remnawave — путь и Host там уже проставлены на ${DOMAIN}."
    warn "ВАЖНО: в клиентской ссылке path обязан ТОЧНО совпадать (включая слеш на конце) с path на ноде: /xhttppath/"
}

### ---------------------------------------------------------------------
### 4. fail2ban (juhnsooqa/servers: fail2ban.sh)
### ---------------------------------------------------------------------
install_fail2ban() {
    log "Установка fail2ban..."
    apt update -y
    apt install -y fail2ban
    systemctl enable fail2ban
    systemctl start fail2ban
    sleep 2

    log "Запись /etc/fail2ban/jail.local..."
    tee /etc/fail2ban/jail.local >/dev/null <<'EOF'
[DEFAULT]
# Добавьте сюда свои доверенные IP/подсети!
ignoreip = 127.0.0.1/8 ::1

bantime  = 3h
findtime = 10m
maxretry = 5

[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 2h
EOF

    systemctl restart fail2ban
    sleep 3

    if systemctl is-active --quiet fail2ban; then
        log "fail2ban успешно запущен."
        fail2ban-client status sshd 2>/dev/null || warn "jail sshd ещё активируется..."
    else
        err "fail2ban не запущен, смотрите: systemctl status fail2ban"
    fi
}

### ---------------------------------------------------------------------
### 5. roscom.dat автообновление (juhnsooqa/servers: roscom.sh)
### ---------------------------------------------------------------------
setup_roscom() {
    local work_dir="$NODE_DIR"
    if [ ! -f "${work_dir}/docker-compose.yml" ]; then
        warn "Не найден ${work_dir}/docker-compose.yml."
        ask "Укажите директорию с docker-compose.yml ноды" work_dir "$NODE_DIR"
    fi

    local roscom_file="${work_dir}/roscom.dat"
    local compose_file="${work_dir}/docker-compose.yml"
    local update_script="${work_dir}/update_roscom.sh"
    local container_name="remnanode"
    local download_url="https://github.com/hydraponique/roscomvpn-geosite/releases/latest/download/geosite.dat"

    log "[1/4] Скачивание roscom.dat..."
    wget -q -O "$roscom_file" "$download_url" || { err "Не удалось скачать roscom.dat"; return 1; }

    log "[2/4] Проверка монтирования в docker-compose.yml..."
    if grep -q "roscom.dat" "$compose_file"; then
        warn "Монтирование roscom.dat уже настроено."
    else
        cp "$compose_file" "${compose_file}.bak.$(date +%s)"
        # Добавляем volume строкой, без переписывания всего YAML - надёжнее, чем через yaml-парсер,
        # т.к. не меняет форматирование остального файла.
        sed -i "/remnanode:/,/volumes:/ s#\(volumes:\)#\1\n      - ${roscom_file}:/usr/local/share/xray/roscom.dat#" "$compose_file"
        if grep -q "roscom.dat" "$compose_file"; then
            log "Монтирование добавлено в docker-compose.yml."
        else
            warn "Не получилось добавить монтирование автоматически. Добавьте вручную в volumes сервиса remnanode:"
            warn "      - ${roscom_file}:/usr/local/share/xray/roscom.dat"
        fi
    fi

    log "[3/4] Скрипт автообновления ${update_script}..."
    cat > "$update_script" <<EOF
#!/bin/bash
DOWNLOAD_URL="${download_url}"
TARGET_FILE="${roscom_file}"
COMPOSE_DIR="${work_dir}"
CONTAINER_NAME="${container_name}"
LOG_FILE="/var/log/roscom_update.log"

exec >> "\$LOG_FILE" 2>&1
echo "--- \$(date '+%Y-%m-%d %H:%M:%S') ---"

TEMP_FILE="/tmp/roscom_temp_\$(date +%s).dat"
wget -q -O "\$TEMP_FILE" "\$DOWNLOAD_URL" || { echo "ОШИБКА: скачивание не удалось"; rm -f "\$TEMP_FILE"; exit 1; }

if [ -f "\$TARGET_FILE" ] && [ "\$(md5sum "\$TARGET_FILE" | awk '{print \$1}')" == "\$(md5sum "\$TEMP_FILE" | awk '{print \$1}')" ]; then
    echo "Файл не изменился."
    rm -f "\$TEMP_FILE"
    exit 0
fi

mv -f "\$TEMP_FILE" "\$TARGET_FILE"
echo "Файл обновлён, перезапуск контейнера..."
cd "\$COMPOSE_DIR" && docker compose restart "\$CONTAINER_NAME"
EOF
    chmod +x "$update_script"

    log "[4/4] Cron (каждый день в 03:00)..."
    if ! crontab -l 2>/dev/null | grep -qF "$update_script"; then
        (crontab -l 2>/dev/null; echo "0 3 * * * $update_script") | crontab -
    else
        warn "Задача cron уже есть."
    fi

    log "Перезапуск контейнеров..."
    (cd "$work_dir" && docker compose down && docker compose up -d)
    log "roscom.dat настроен. Правила маршрутизации: \"ext:roscom.dat:category-ru\", \"ext:roscom.dat:youtube\" и т.д."
}

### ---------------------------------------------------------------------
### 6. Psiphon как выход для xray (psiphon/psiphon_install.sh, из Chara-Freedom/vps-psiphon)
### ---------------------------------------------------------------------
setup_psiphon() {
    warn "Ставить только на зарубежную ноду: трафик Psiphon узнаётся DPI."
    install_docker
    local region args=()
    read -rp "Страна выхода Psiphon (DE или пул DE,NL,FR; Enter = авто): " region
    [ -n "$region" ] && args=(--region "$region")
    bash <(curl -fsSL "${REPO_RAW}/psiphon/psiphon_install.sh") "${args[@]}" || { err "Установка Psiphon не удалась."; return 1; }
    # Пересобираем справочный профиль, чтобы в нём появился psiphon-out
    [ -f "${NODE_DIR}/panel-profile.reference.json" ] && write_panel_reference_files
    log "Psiphon установлен. Управление: allinone -> Psiphon, или напрямую: vps-psiphon"
}

psiphon_menu() {
    if ! command -v vps-psiphon &>/dev/null; then
        warn "Psiphon ещё не установлен."
        read -rp "Установить сейчас? [Y/n]: " a
        [[ "$a" =~ ^[Nn]$ ]] || setup_psiphon
        return
    fi
    local c v
    echo -e "${CYAN}${BOLD}=== Psiphon ===${NC}"
    echo "  1) Статус          5) Логи клиента"
    echo "  2) Сменить IP      6) Журнал вотчдога"
    echo "  3) Страна выхода   7) Переустановить/обновить"
    echo "  4) Тест скорости   8) Удалить"
    echo "  0) Назад"
    read -rp "Выбор: " c
    case "$c" in
        1) vps-psiphon ;;
        2) vps-psiphon rotate ;;
        3) read -rp "Код страны (DE, NL, JP...; auto = любая): " v; vps-psiphon region "$v" ;;
        4) vps-psiphon speed ;;
        5) vps-psiphon logs 50 ;;
        6) vps-psiphon watchdog 50 ;;
        7) setup_psiphon ;;
        8) read -rp "Точно удалить Psiphon? [y/N]: " v; [[ "$v" =~ ^[Yy]$ ]] && vps-psiphon uninstall ;;
    esac
}

### ---------------------------------------------------------------------
### 7. Опциональные сторонние установщики (НЕ встраиваются целиком)
### ---------------------------------------------------------------------
run_node_accelerator() {
    warn "Это сторонний репозиторий jestivald/node-accelerator (оптимизация сети/защита, не про Remnawave)."
    read -rp "Склонировать и запустить его меню? [y/N]: " a
    [[ "$a" =~ ^[Yy]$ ]] || return 0
    if [ ! -d /opt/node-accelerator ]; then
        git clone https://github.com/jestivald/node-accelerator.git /opt/node-accelerator
    else
        (cd /opt/node-accelerator && git pull)
    fi
    (cd /opt/node-accelerator && bash install.sh)
}

run_reverse_proxy_pro() {
    warn "Это сторонний установщик vladimir-kartamyshev/remnawave-reverse-proxy-pro (панель+reverse-proxy, отдельный проект)."
    warn "Скрипт скачивается напрямую с GitHub автора и выполняется как есть - проверьте доверие к источнику."
    read -rp "Скачать и запустить его? [y/N]: " a
    [[ "$a" =~ ^[Yy]$ ]] || return 0
    bash <(curl -fsSL "https://raw.githubusercontent.com/vladimir-kartamyshev/remnawave-reverse-proxy-pro/refs/heads/main/install_remnawave.sh")
}

### ---------------------------------------------------------------------
### Основная установка ноды одним вызовом
### ---------------------------------------------------------------------
full_install() {
    load_common_vars
    setup_firewall
    block_icmp
    install_nginx
    create_stub
    issue_ssl || { err "Без сертификата дальше нельзя. Исправьте DNS и запустите снова."; return 1; }
    configure_nginx
    install_docker
    setup_remnanode
    log "Базовая установка ноды завершена."
    read -rp "Установить fail2ban сейчас? [Y/n]: " a
    [[ "$a" =~ ^[Nn]$ ]] || install_fail2ban
    read -rp "Настроить roscom.dat сейчас? [Y/n]: " a
    [[ "$a" =~ ^[Nn]$ ]] || setup_roscom
}

### ---------------------------------------------------------------------
### Меню / CLI
### ---------------------------------------------------------------------
# Команда `allinone` на сервере: каждый раз качает свежий скрипт с GitHub и запускает его.
install_cli() {
    cat > "$CLI_PATH" <<EOF
#!/usr/bin/env bash
s="\$(curl -fsSL ${REPO_RAW}/remnawave-node-setup.sh)" || { echo "allinone: не удалось скачать скрипт" >&2; exit 1; }
exec bash -c "\$s" allinone "\$@"
EOF
    chmod 755 "$CLI_PATH"
}

print_menu() {
    clear
    echo -e "${CYAN}${BOLD}=== Remnawave Node Setup ===${NC}"
    echo -e "  ${GREEN}1)${NC} Полная установка ноды (firewall+icmp+nginx+ssl+docker+remnanode)"
    echo -e "  ${GREEN}2)${NC} fail2ban"
    echo -e "  ${GREEN}3)${NC} roscom.dat + автообновление"
    echo -e "  ${GREEN}6)${NC} Psiphon-выход (установка / управление)"
    echo -e "  ${YELLOW}4)${NC} [опционально, сторонний репо] node-accelerator"
    echo -e "  ${YELLOW}5)${NC} [опционально, сторонний репо] remnawave-reverse-proxy-pro"
    echo -e "  ${RED}0)${NC} Выход"
    echo -ne "${BOLD}Выбор: ${NC}"
}

main() {
    require_root
    install_cli
    case "${1:-}" in
        full)           full_install ;;
        fail2ban)       install_fail2ban ;;
        roscom)         setup_roscom ;;
        psiphon)        psiphon_menu ;;
        accelerator)    run_node_accelerator ;;
        reverse-proxy)  run_reverse_proxy_pro ;;
        "")
            while true; do
                print_menu
                read -r choice
                case "$choice" in
                    1) full_install ;;
                    2) install_fail2ban ;;
                    3) setup_roscom ;;
                    4) run_node_accelerator ;;
                    5) run_reverse_proxy_pro ;;
                    6) psiphon_menu ;;
                    0) exit 0 ;;
                    *) warn "Неверный выбор" ;;
                esac
                read -rp "Нажмите Enter для продолжения..." _
            done
            ;;
        *)
            err "Неизвестный аргумент: $1"
            echo "Использование: $0 [full|fail2ban|roscom|psiphon|accelerator|reverse-proxy]"
            exit 1
            ;;
    esac
}

main "$@"
