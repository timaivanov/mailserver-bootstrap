#!/usr/bin/env bash
set -Eeuo pipefail

DOMAIN=""
IP=""
EMAIL=""
MAIL_HOST=""
PHPLIST_HOST=""
MAILSERVER_SCRIPT_URL="https://raw.githubusercontent.com/timaivanov/mailserver-bootstrap/main/mailserver-setup.sh"

usage() {
  cat <<EOF
Usage:
  sudo ./bootstrap-mail+phplist.sh --domain example.com --ip 1.2.3.4 --email postmaster@example.com

Options:
  --domain    Root domain (marketingyconcercio.com)
  --ip        Server public IPv4
  --email     Email for Let's Encrypt + phpList admin email
  --mail-host Mail hostname (default: mail.<domain>)
  --lists-host phpList hostname (default: lists.<domain>)
  --mailserver-url Override mailserver-setup.sh raw URL
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2;;
    --ip) IP="$2"; shift 2;;
    --email) EMAIL="$2"; shift 2;;
    --mail-host) MAIL_HOST="$2"; shift 2;;
    --lists-host) PHPLIST_HOST="$2"; shift 2;;
    --mailserver-url) MAILSERVER_SCRIPT_URL="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 1;;
  esac
done

if [[ -z "${DOMAIN}" || -z "${IP}" || -z "${EMAIL}" ]]; then
  echo "Missing required args."
  usage
  exit 1
fi

MAIL_HOST="${MAIL_HOST:-mail.${DOMAIN}}"
PHPLIST_HOST="${PHPLIST_HOST:-lists.${DOMAIN}}"

log() { echo -e "\n[+] $*\n"; }

export DEBIAN_FRONTEND=noninteractive

log "Install base tools"
apt-get update -y
apt-get install -y curl ca-certificates dos2unix git ufw

log "Firewall"
ufw allow OpenSSH || true
ufw allow 80/tcp || true
ufw allow 443/tcp || true
# Почтовые порты открываем (если надо принимать/проверять снаружи)
ufw allow 25/tcp || true
ufw allow 587/tcp || true
ufw allow 993/tcp || true
ufw --force enable || true

# ---------------------------
# 1) Mail server (Postfix + DKIM/DMARC) from your repo
# ---------------------------
log "Download + run mailserver bootstrap"
curl -fsSL "${MAILSERVER_SCRIPT_URL}" -o /root/mailserver-setup.sh
dos2unix /root/mailserver-setup.sh
chmod +x /root/mailserver-setup.sh

sudo /root/mailserver-setup.sh --domain "${DOMAIN}" --ip "${IP}" | tee /root/mailserver-run.log

MAIL_OUT="/root/MAILSERVER_${DOMAIN}.txt"
if [[ ! -f "${MAIL_OUT}" ]]; then
  MAIL_OUT="$(ls -1 /root/MAILSERVER_*.txt 2>/dev/null | tail -n 1 || true)"
  if [[ -z "${MAIL_OUT}" || ! -f "${MAIL_OUT}" ]]; then
    echo "ERROR: Can't find /root/MAILSERVER_<domain>.txt from mailserver script."
    echo "Check: /root/mailserver-run.log"
    exit 1
  fi
fi

log "Mailserver output detected: ${MAIL_OUT}"

# sanity check: sendmail exists
if [[ ! -x /usr/sbin/sendmail ]]; then
  echo "ERROR: /usr/sbin/sendmail not found. Postfix is not installed correctly."
  exit 1
fi

# ---------------------------
# 2) phpList install (nginx + php + mariadb) + configure to use local Postfix
# ---------------------------
log "Install web stack for phpList"
apt-get install -y nginx mariadb-server \
  php-fpm php-cli php-mysql php-xml php-mbstring php-curl php-zip php-gd php-intl php-imap \
  certbot python3-certbot-nginx

systemctl enable --now nginx mariadb

PHPLIST_PATH="/var/www/phplist"
PHPLIST_DB="phplist"
PHPLIST_DB_USER="phplist"
PHPLIST_DB_PW="$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 28)"

log "Create DB"
mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${PHPLIST_DB}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${PHPLIST_DB_USER}'@'localhost' IDENTIFIED BY '${PHPLIST_DB_PW}';
GRANT ALL PRIVILEGES ON \`${PHPLIST_DB}\`.* TO '${PHPLIST_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

log "Clone phpList from GitHub"
rm -rf "${PHPLIST_PATH}"
git clone --depth 1 https://github.com/phpList/phplist3.git "${PHPLIST_PATH}"

WEBROOT="${PHPLIST_PATH}/public_html"
CONFIG_DIR="${WEBROOT}/lists/config"
mkdir -p "${CONFIG_DIR}"

if [[ ! -f "${CONFIG_DIR}/config.php" ]]; then
  cp "${CONFIG_DIR}/config.php-dist" "${CONFIG_DIR}/config.php"
fi

log "Configure phpList DB + Local MTA (Postfix via sendmail)"
CFG="${CONFIG_DIR}/config.php"

# DB
sed -i "s#^\\s*\\\$database_host\\s*=.*#\\\$database_host = 'localhost';#g" "${CFG}" || true
sed -i "s#^\\s*\\\$database_name\\s*=.*#\\\$database_name = '${PHPLIST_DB}';#g" "${CFG}" || true
sed -i "s#^\\s*\\\$database_user\\s*=.*#\\\$database_user = '${PHPLIST_DB_USER}';#g" "${CFG}" || true
sed -i "s#^\\s*\\\$database_password\\s*=.*#\\\$database_password = '${PHPLIST_DB_PW}';#g" "${CFG}" || true

# Website
if grep -q "^\s*\\\$website" "${CFG}"; then
  sed -i "s#^\\s*\\\$website\\s*=.*#\\\$website = 'https://${PHPLIST_HOST}';#g" "${CFG}" || true
else
  echo "\$website = 'https://${PHPLIST_HOST}';" >> "${CFG}"
fi

# Local Postfix (sendmail)
cat >> "${CFG}" <<PHP

// ---- Mail sending via local Postfix (sendmail) ----
\$mailer = 'sendmail';
\$sendmail_path = '/usr/sbin/sendmail';
PHP

chown -R www-data:www-data "${PHPLIST_PATH}"

log "Nginx vhost for ${PHPLIST_HOST}"
PHP_SOCK="$(php -r 'echo "unix:/run/php/php".PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION."-fpm.sock";')"
NGINX_CONF="/etc/nginx/sites-available/${PHPLIST_HOST}.conf"

cat > "${NGINX_CONF}" <<EOF
server {
  listen 80;
  server_name ${PHPLIST_HOST};

  root ${WEBROOT};
  index index.php index.html;
  client_max_body_size 32m;

  location / {
    try_files \$uri \$uri/ /index.php?\$args;
  }

  location ~ \\.php\$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass ${PHP_SOCK};
  }

  location ~ /\\. { deny all; }
}
EOF

ln -sf "${NGINX_CONF}" "/etc/nginx/sites-enabled/${PHPLIST_HOST}.conf"
rm -f /etc/nginx/sites-enabled/default || true
nginx -t
systemctl reload nginx

log "Let's Encrypt cert for phpList host"
certbot --nginx -d "${PHPLIST_HOST}" --non-interactive --agree-tos -m "${EMAIL}" --redirect || true

log "Cron for phpList queue"
cat > /etc/cron.d/phplist-queue <<EOF
*/5 * * * * www-data php ${WEBROOT}/lists/admin/index.php -p processqueue >/dev/null 2>&1
EOF
chmod 644 /etc/cron.d/phplist-queue

# ---------------------------
# Final output
# ---------------------------
log "IMPORTANT OUTPUT"

OUTFILE="/root/STACK_${DOMAIN}.txt"
cat > "${OUTFILE}" <<EOF
MAIL SERVER:
  Domain:       ${DOMAIN}
  Mail host:    ${MAIL_HOST}
  IP:           ${IP}

phpList:
  URL:          https://${PHPLIST_HOST}/lists/admin/
  Sending:      via local Postfix (/usr/sbin/sendmail)
  DB_NAME:      ${PHPLIST_DB}
  DB_USER:      ${PHPLIST_DB_USER}
  DB_PASS:      ${PHPLIST_DB_PW}

DNS:
  A:     mail   -> ${IP}
  A:     lists  -> ${IP}
  MX:    @      -> ${MAIL_HOST}. (prio 10)
  SPF:   @      -> v=spf1 mx ip4:${IP} -all
  DKIM:  add FULL DKIM TXT from ${MAIL_OUT} (must contain v=DKIM1; ...; p=...)
  DMARC: _dmarc -> v=DMARC1; p=quarantine; adkim=s; aspf=s; rua=mailto:postmaster@${DOMAIN}; ruf=mailto:postmaster@${DOMAIN}; fo=1

NOTES:
  - Set PTR/rDNS for ${IP} to ${MAIL_HOST}
  - Test local sendmail:
      echo "test $(date)" | /usr/sbin/sendmail -v postmaster@${DOMAIN}
  - Tail logs:
      tail -f /var/log/mail.log
EOF

cat "${OUTFILE}"
echo
echo "[+] Saved: ${OUTFILE}"
# ---------------------------
# Autotests
# ---------------------------
log "AUTOTEST: STARTTLS on 587"
if timeout 10 bash -lc "echo | openssl s_client -starttls smtp -connect ${MAIL_HOST}:587 -servername ${MAIL_HOST} 2>/dev/null | grep -E 'Verify return code|subject=|issuer=' >/tmp/starttls_check.txt"; then
  echo "[OK] STARTTLS reachable on 587"
  cat /tmp/starttls_check.txt || true
else
  echo "[WARN] STARTTLS check failed (587). Check firewall/nginx/postfix submission."
fi

log "AUTOTEST: DKIM DNS record visible"
if dig +short "s1._domainkey.${DOMAIN}" TXT | grep -q "v=DKIM1"; then
  echo "[OK] DKIM TXT contains v=DKIM1"
else
  echo "[WARN] DKIM TXT not found or missing v=DKIM1. DNS not added yet or wrong TXT."
  echo "dig +short s1._domainkey.${DOMAIN} TXT:"
  dig +short "s1._domainkey.${DOMAIN}" TXT || true
fi

log "AUTOTEST: OpenDKIM can verify key"
if opendkim-testkey -d "${DOMAIN}" -s s1 -vvv >/tmp/opendkim_testkey.txt 2>&1; then
  if grep -qi "key OK" /tmp/opendkim_testkey.txt; then
    echo "[OK] opendkim-testkey: key OK"
  else
    echo "[WARN] opendkim-testkey ran, but not 'key OK':"
    cat /tmp/opendkim_testkey.txt
  fi
else
  echo "[WARN] opendkim-testkey failed:"
  cat /tmp/opendkim_testkey.txt || true
fi

log "AUTOTEST: Send outbound mail (must see status=sent)"
TEST_TO="${EMAIL}"
TEST_FROM="noreply@${DOMAIN}"
TEST_SUBJ="AUTOTEST ${DOMAIN} $(date -u +'%F %T UTC')"
TEST_BODY="Hello. This is an автоматический тест. Server: ${MAIL_HOST} IP: ${IP}"

cat <<EOF | /usr/sbin/sendmail -t
From: ${TEST_FROM}
To: ${TEST_TO}
Subject: ${TEST_SUBJ}
MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8

${TEST_BODY}
EOF

sleep 2

# ищем отправку в логах
if grep -E "status=sent" /var/log/mail.log | tail -n 200 | grep -q "${TEST_TO}"; then
  echo "[OK] Postfix shows status=sent to ${TEST_TO}"
  grep -E "to=<${TEST_TO}>|status=sent|dsn=" /var/log/mail.log | tail -n 30
else
  echo "[WARN] Not seeing status=sent to ${TEST_TO} in last logs."
  echo "Last 80 lines of /var/log/mail.log:"
  tail -n 80 /var/log/mail.log
  echo
  echo "Common причины:"
  echo " - провайдер режет исходящий 25 (тогда будет connect timeout)"
  echo " - проблемы DNS (MX/A/PTR)"
  echo " - ip в блоклистах"
fi

log "AUTOTEST: phpList can use sendmail"
if sudo -u www-data test -x /usr/sbin/sendmail; then
  echo "[OK] www-data can execute /usr/sbin/sendmail"
else
  echo "[WARN] www-data can't execute sendmail (permissions issue)"
  ls -la /usr/sbin/sendmail || true
fi
echo "[+] Done."
