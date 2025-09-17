#!/bin/bash
set -e

# === Настройки ===
USER_NAME="vpnuser"
WORK_DIR="/srv/vpn/3x-ui"
PANEL_PORT=51873
DOMAIN="mybest.duckdns.org"
CERT_DIR="$WORK_DIR/cert"
CERT_FILE="$CERT_DIR/fullchain.pem"
KEY_FILE="$CERT_DIR/privkey.pem"

# === 0. Установка зависимостей (curl, certbot, docker, docker-compose, ufw) ===
echo "[0/10] Устанавливаю зависимости (curl, certbot, docker, docker-compose, ufw)"
sudo apt update
sudo apt install -y curl certbot ufw apt-transport-https ca-certificates software-properties-common openssl
WEB_BASE_PATH="/xui-dash-$(openssl rand -hex 4)"

# Установка Docker
if ! command -v docker &> /dev/null; then
  echo "Docker не найден, устанавливаю..."
  curl -fsSL https://get.docker.com | sh
fi

# Установка Docker Compose Plugin
if ! docker compose version &> /dev/null; then
  echo "Docker Compose Plugin не найден, устанавливаю..."
  sudo apt install -y docker-compose-plugin
fi

# === 1. Настройка фаервола ===
echo "[1/10] Настраиваю фаервол (UFW: разрешаю 22, 80, 443, $PANEL_PORT)"
sudo ufw allow 22/tcp || true
sudo ufw allow 80/tcp || true
sudo ufw allow 443/tcp || true
sudo ufw allow $PANEL_PORT/tcp || true
sudo ufw --force enable || true

# === 2. Создание пользователя ===
echo "[2/10] Создаю пользователя $USER_NAME"
sudo deluser --remove-home $USER_NAME 2>/dev/null || true
sudo adduser --system --group --home /srv/vpn $USER_NAME
sudo usermod -aG docker $USER_NAME

# === 3. Подготовка каталогов ===
echo "[3/10] Готовлю рабочую директорию $WORK_DIR"
sudo rm -rf $WORK_DIR
sudo -u $USER_NAME mkdir -p $WORK_DIR/config
sudo -u $USER_NAME mkdir -p $WORK_DIR/cert

# === 4. Проверка сертификатов ===
echo "[4/10] Проверяю наличие сертификатов Let’s Encrypt для $DOMAIN"
if [ -f /etc/letsencrypt/live/$DOMAIN/fullchain.pem ] && [ -f /etc/letsencrypt/live/$DOMAIN/privkey.pem ]; then
  echo "Сертификаты найдены, копирую их в $CERT_DIR"
  sudo mkdir -p $CERT_DIR
  sudo cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem $CERT_FILE
  sudo cp /etc/letsencrypt/live/$DOMAIN/privkey.pem $KEY_FILE
  sudo chown $USER_NAME:$USER_NAME $CERT_DIR/*
else
  echo "Сертификаты не найдены. Запускаю certbot для выпуска."
  sudo certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN || {
    echo "Ошибка: certbot не смог получить сертификат. Проверьте DNS и порт 80."
    exit 1
  }
  sudo mkdir -p $CERT_DIR
  sudo cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem $CERT_FILE
  sudo cp /etc/letsencrypt/live/$DOMAIN/privkey.pem $KEY_FILE
  sudo chown $USER_NAME:$USER_NAME $CERT_DIR/*
fi

# === 5. Docker Compose файл ===
echo "[5/10] Создаю docker-compose.yml"
cat <<EOF | sudo -u $USER_NAME tee $WORK_DIR/docker-compose.yml
services:
  3x-ui:
    image: ghcr.io/mhsanaei/3x-ui:latest
    container_name: 3x-ui
    restart: always
    network_mode: host
    volumes:
      - ./config:/etc/x-ui
      - ./cert:/root/cert
    environment:
      - XRAY_VMESS_AEAD_FORCED=false
      - PANEL_PORT=$PANEL_PORT
      - WEB_BASE_PATH=$WEB_BASE_PATH
      - SSL_CERTIFICATE=$CERT_FILE
      - SSL_CERTIFICATE_KEY=$KEY_FILE
EOF

# === 6. Запуск Docker контейнера ===
echo "[6/10] Запускаю контейнер 3x-ui"
cd $WORK_DIR
sudo -u $USER_NAME docker compose down || true
sudo -u $USER_NAME docker compose up -d
sleep 10

# === 7. Проверка доступности панели ===
echo "[7/10] Проверяю доступность панели на https://$DOMAIN:$PANEL_PORT$WEB_BASE_PATH"
STATUS_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" https://$DOMAIN:$PANEL_PORT$WEB_BASE_PATH/login || true)
if [ "$STATUS_CODE" == "200" ] || [ "$STATUS_CODE" == "302" ]; then
  echo "Панель отвечает корректно (HTTP $STATUS_CODE)"
else
  echo "ВНИМАНИЕ: Панель недоступна или отвечает ошибкой (код $STATUS_CODE)."
fi

# === 8. Добавление cron задачи для обновления сертификата ===
echo "[8/10] Добавляю cron задачу для продления сертификатов и рестарта контейнера"
CRON_CMD="0 3 * * * certbot renew --quiet && docker restart 3x-ui"
if ! sudo crontab -l 2>/dev/null | grep -Fq "$CRON_CMD"; then
  (sudo crontab -l 2>/dev/null || true; echo "$CRON_CMD") | sudo crontab -
fi

# === 9. Информация пользователю ===
echo "[9/10] Готово!"
echo "Панель доступна по адресу: https://$DOMAIN:$PANEL_PORT$WEB_BASE_PATH"
echo "Логин/пароль по умолчанию: admin / admin"
echo "Сертификаты: $CERT_FILE и $KEY_FILE"
