#!/usr/bin/env bash
set -euo pipefail

# mailserver-setup.sh
# Ubuntu 22.04/24.04 friendly
# Installs: Postfix (submission 587), Dovecot (AUTH only), OpenDKIM, OpenDMARC, Certbot
# Generates DKIM key + prints DNS records + prints SMTP creds at end
# Idempotent-ish (safe to re-run)

log() { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
die() { echo "[x] $*" >&2; exit 1; }

need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root (use sudo)."; }

DOMAIN=""
IP=""
MAIL_HOST=""
SELECTOR="s1"
SMTP_USER="mt"
SMTP_PASS=""
DMARC_POLICY="quarantine"

usage() {
  cat <<EOF
Usage:
  sudo ./mailserver-setup.sh --domain example.com --ip 1.2.3.4 [--mail-host mail.example.com] [--selector s1] [--smtp-user mt] [--smtp-pass '...'] [--dmarc-policy quarantine|reject|none]

Defaults:
  --mail-host = mail.<domain>
  --selector  = s1
  --smtp-user = mt
  --smtp-pass = random
  --dmarc-policy = quarantine
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2;;
    --ip) IP="${2:-}"; shift 2;;
    --mail-host) MAIL_HOST="${2:-}"; shift 2;;
    --selector) SELECTOR="${2:-}"; shift 2;;
    --smtp-user) SMTP_USER="${2:-}"; shift 2;;
    --smtp-pass) SMTP_PASS="${2:-}"; shift 2;;
    --dmarc-policy) DMARC_POLICY="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "Unknown arg: $1";;
  esac
done

need_root
[[ -n "$DOMAIN" ]] || die "--domain is required"
[[ -n "$IP" ]] || die "--ip is required"
[[ -n "$MAIL_HOST" ]] || MAIL_HOST="mail.${DOMAIN}"
[[ "$DMARC_POLICY" =~ ^(none|quarantine|reject)$ ]] || die "--dmarc-policy must be none|quarantine|reject"

# Generate password if not provided
if [[ -z "${SMTP_PASS}" ]]; then
  # 24 chars base64-ish, safe for most clients
  SMTP_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
fi

export DEBIAN_FRONTEND=noninteractive

log "Updating packages"
apt-get update -y
apt-get install -y \
  postfix postfix-pcre \
  dovecot-core dovecot-imapd \
  opendkim opendkim-tools \
  opendmarc \
  certbot \
  ca-certificates curl openssl \
  ufw \
  dnsutils \
  pwgen

# Ensure hostname points to MAIL_HOST (optional but helps)
log "Setting hostname to ${MAIL_HOST}"
hostnamectl set-hostname "${MAIL_HOST}" || true

log "Configuring firewall (ufw)"
ufw allow 22/tcp >/dev/null || true
ufw allow 25/tcp >/dev/null || true
ufw allow 587/tcp >/dev/null || true
ufw allow 143/tcp >/dev/null || true
ufw allow 993/tcp >/dev/null || true
ufw --force enable >/dev/null || true

# Paths
DKIM_DIR="/etc/opendkim/keys/${DOMAIN}"
DKIM_PRIV="${DKIM_DIR}/${SELECTOR}.private"
DKIM_PUB="${DKIM_DIR}/${SELECTOR}.txt"

log "Preparing directories"
mkdir -p /etc/opendkim /etc/opendkim/keys
mkdir -p "${DKIM_DIR}"

# ---- TLS certificate (Let's Encrypt) ----
# We need port 80 for certbot standalone. We'll temporarily open it.
log "Obtaining Let's Encrypt cert for ${MAIL_HOST} (standalone on :80)"
ufw allow 80/tcp >/dev/null || true

# Stop anything that might use :80 (nginx/apache) - ignore if not installed
systemctl stop nginx 2>/dev/null || true
systemctl stop apache2 2>/dev/null || true

if ! certbot certonly --standalone -n --agree-tos --register-unsafely-without-email -d "${MAIL_HOST}"; then
  warn "Certbot failed. You can re-run later: certbot certonly --standalone -d ${MAIL_HOST}"
  warn "Continuing with self-signed cert for now."
  mkdir -p /etc/ssl/localcerts
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -subj "/CN=${MAIL_HOST}" \
    -keyout /etc/ssl/localcerts/mail.key \
    -out /etc/ssl/localcerts/mail.crt
  CERT_CHAIN="/etc/ssl/localcerts/mail.crt"
  CERT_KEY="/etc/ssl/localcerts/mail.key"
else
  CERT_CHAIN="/etc/letsencrypt/live/${MAIL_HOST}/fullchain.pem"
  CERT_KEY="/etc/letsencrypt/live/${MAIL_HOST}/privkey.pem"
fi

# optional close :80 after cert
ufw delete allow 80/tcp >/dev/null 2>&1 || true

# ---- Postfix main.cf ----
log "Configuring Postfix (main.cf)"
postconf -e "myhostname = ${MAIL_HOST}"
postconf -e "mydomain = ${DOMAIN}"
postconf -e "myorigin = \$mydomain"
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = all"
postconf -e "mydestination = localhost"
postconf -e "mynetworks = 127.0.0.0/8 [::1]/128"
postconf -e "home_mailbox = Maildir/"

# TLS for SMTP server
postconf -e "smtpd_tls_cert_file = ${CERT_CHAIN}"
postconf -e "smtpd_tls_key_file = ${CERT_KEY}"
postconf -e "smtpd_tls_security_level = may"
postconf -e "smtp_tls_security_level = may"
postconf -e "smtpd_tls_loglevel = 1"
postconf -e "smtpd_tls_received_header = yes"
postconf -e "smtpd_tls_protocols = !SSLv2,!SSLv3"
postconf -e "smtpd_tls_mandatory_protocols = !SSLv2,!SSLv3"
postconf -e "smtpd_tls_mandatory_ciphers = high"
postconf -e "tls_preempt_cipherlist = yes"

# Basic anti-open-relay
postconf -e "smtpd_relay_restrictions = permit_sasl_authenticated,reject_unauth_destination"
postconf -e "smtpd_recipient_restrictions = permit_sasl_authenticated,reject_unauth_destination"

# ---- Dovecot AUTH socket for Postfix SASL ----
log "Configuring Dovecot for SMTP AUTH"
# Create passwd-file for smtp auth user
DOVECOT_PASSWD="/etc/dovecot/passwd"
touch "$DOVECOT_PASSWD"
chmod 600 "$DOVECOT_PASSWD"

# Generate hash
HASH="$(doveadm pw -s SHA512-CRYPT -p "${SMTP_PASS}")"
# Replace or add user
grep -qE "^${SMTP_USER}:" "$DOVECOT_PASSWD" \
  && sed -i "s#^${SMTP_USER}:.*#${SMTP_USER}:${HASH}:1000:1000::/var/mail/${SMTP_USER}::#" "$DOVECOT_PASSWD" \
  || echo "${SMTP_USER}:${HASH}:1000:1000::/var/mail/${SMTP_USER}::" >> "$DOVECOT_PASSWD"

# Minimal dovecot config pieces
# Enable imap so you can login if needed; still safe.
sed -i 's/^#\?protocols = .*/protocols = imap/' /etc/dovecot/dovecot.conf

# Auth: passwd-file
cat >/etc/dovecot/conf.d/10-auth.conf <<'EOF'
disable_plaintext_auth = yes
auth_mechanisms = plain login
!include auth-passwdfile.conf.ext
EOF

cat >/etc/dovecot/conf.d/auth-passwdfile.conf.ext <<EOF
passdb {
  driver = passwd-file
  args = ${DOVECOT_PASSWD}
}
userdb {
  driver = static
  args = uid=vmail gid=vmail home=/var/mail/%u
}
EOF

# Create vmail user/group if missing
if ! getent group vmail >/dev/null; then groupadd -g 5000 vmail; fi
if ! id -u vmail >/dev/null 2>&1; then useradd -u 5000 -g 5000 -m -d /var/mail vmail; fi
mkdir -p /var/mail
chown -R vmail:vmail /var/mail

# Configure auth socket for postfix
cat >/etc/dovecot/conf.d/10-master.conf <<'EOF'
service imap-login {
  inet_listener imap {
    port = 143
  }
  inet_listener imaps {
    port = 993
    ssl = yes
  }
}

service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}
EOF

cat >/etc/dovecot/conf.d/10-ssl.conf <<EOF
ssl = required
ssl_cert = <${CERT_CHAIN}
ssl_key = <${CERT_KEY}
EOF

# Postfix SASL via dovecot
postconf -e "smtpd_sasl_type = dovecot"
postconf -e "smtpd_sasl_path = private/auth"
postconf -e "smtpd_sasl_auth_enable = yes"
postconf -e "smtpd_tls_auth_only = yes"

# ---- Enable submission (587) in master.cf ----
log "Configuring submission service in master.cf"
# Ensure submission section exists and is enabled with proper overrides
if ! grep -qE '^[[:space:]]*submission[[:space:]]+inet' /etc/postfix/master.cf; then
  cat >>/etc/postfix/master.cf <<'EOF'

submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o smtpd_sender_restrictions=permit_sasl_authenticated,reject
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
EOF
else
  # Un-comment if commented
  sed -i 's/^[#]\(submission[[:space:]]\+inet\)/\1/' /etc/postfix/master.cf
fi

# ---- OpenDKIM ----
log "Configuring OpenDKIM"
# Generate key if not exists
if [[ ! -f "$DKIM_PRIV" ]]; then
  log "Generating DKIM keys (selector=${SELECTOR}, domain=${DOMAIN})"
  (cd "$DKIM_DIR" && opendkim-genkey -s "$SELECTOR" -d "$DOMAIN")
  # opendkim-genkey outputs ${SELECTOR}.private and ${SELECTOR}.txt
fi

# Tables + hosts
cat >/etc/opendkim/TrustedHosts <<EOF
127.0.0.1
localhost
${IP}
${MAIL_HOST}
.${DOMAIN}
EOF

cat >/etc/opendkim/KeyTable <<EOF
${SELECTOR}._domainkey.${DOMAIN} ${DOMAIN}:${SELECTOR}:${DKIM_PRIV}
EOF

cat >/etc/opendkim/SigningTable <<EOF
*@${DOMAIN} ${SELECTOR}._domainkey.${DOMAIN}
EOF

# OpenDKIM config with explicit refile: maps (fixes "no signing table match" surprises)
cat >/etc/opendkim.conf <<EOF
Syslog                  yes
SyslogSuccess           yes
LogWhy                  yes

UMask                   002
Mode                    sv
Canonicalization        relaxed/simple
SubDomains              no
OversignHeaders         From

UserID                  opendkim:opendkim
Socket                  inet:8891@127.0.0.1
PidFile                 /run/opendkim/opendkim.pid

KeyTable                refile:/etc/opendkim/KeyTable
SigningTable            refile:/etc/opendkim/SigningTable
ExternalIgnoreList      refile:/etc/opendkim/TrustedHosts
InternalHosts           refile:/etc/opendkim/TrustedHosts
EOF

# Permissions
chown -R opendkim:opendkim /etc/opendkim
chmod 750 /etc/opendkim/keys || true
chmod 750 "$DKIM_DIR" || true
chmod 600 "$DKIM_PRIV" || true

# Ensure runtime dir exists and is writable (fixes pidfile/rundir issues)
mkdir -p /run/opendkim
chown opendkim:opendkim /run/opendkim
chmod 755 /run/opendkim

# ---- OpenDMARC ----
log "Configuring OpenDMARC"
mkdir -p /etc/opendmarc /run/opendmarc
touch /etc/opendmarc/ignore.hosts

cat >/etc/opendmarc.conf <<EOF
AuthservID              ${MAIL_HOST}
PidFile                 /run/opendmarc/opendmarc.pid
RejectFailures          false
Syslog                  true
TrustedAuthservIDs      ${MAIL_HOST}
Socket                  inet:8893@127.0.0.1
IgnoreHosts             /etc/opendmarc/ignore.hosts
EOF

chown -R opendmarc:opendmarc /run/opendmarc || true

# ---- Hook milters into Postfix ----
log "Connecting milters to Postfix"
postconf -e "milter_protocol = 6"
postconf -e "milter_default_action = accept"
postconf -e "smtpd_milters = inet:127.0.0.1:8891, inet:127.0.0.1:8893"
postconf -e "non_smtpd_milters = inet:127.0.0.1:8891, inet:127.0.0.1:8893"

# ---- Restart services ----
log "Restarting services"
systemctl enable --now opendkim opendmarc dovecot postfix >/dev/null
systemctl restart opendkim opendmarc dovecot postfix

# ---- Self-checks ----
log "Self-check: DKIM private key readable + testkey"
opendkim-testkey -d "${DOMAIN}" -s "${SELECTOR}" -k "${DKIM_PRIV}" -vvv >/tmp/opendkim-testkey.txt 2>&1 || true

log "Ports listening check"
ss -lntp | egrep ':(25|587|143|993|8891|8893)\b' || true

# Extract DKIM TXT value (single line, safe for DNS UI)
# opendkim-genkey file contains:  s1._domainkey IN TXT ( "v=DKIM1; ... " "p=..." ) ;
DKIM_TXT_RAW="$(cat "$DKIM_PUB" | tr -d '\n' | sed -E 's/.*\(\s*"//; s/"\s*\).*//; s/"\s*"//g')"

# Print final outputs
cat <<EOF

============================================================
✅ MAIL SERVER READY (best effort)

SERVER:
  IP:            ${IP}
  MAIL HOST:      ${MAIL_HOST}
  DOMAIN:         ${DOMAIN}

SMTP (for Mailtrain):
  Host:          ${MAIL_HOST}   (IMPORTANT: use hostname, NOT IP)
  Port:          587
  Encryption:    STARTTLS
  Auth:          YES
  Username:      ${SMTP_USER}
  Password:      ${SMTP_PASS}

TLS CERT:
  Cert:          ${CERT_CHAIN}
  Key:           ${CERT_KEY}

DKIM:
  Selector:      ${SELECTOR}
  Private key:   ${DKIM_PRIV}

DNS RECORDS TO ADD (at your DNS provider):
  A:
    Name:        mail
    Type:        A
    Value:       ${IP}

  MX:
    Name:        @
    Type:        MX
    Priority:    10
    Value:       ${MAIL_HOST}.

  SPF (TXT):
    Name:        @
    Type:        TXT
    Value:       v=spf1 mx ip4:${IP} -all

  DKIM (TXT):
    Name:        ${SELECTOR}._domainkey
    Type:        TXT
    Value:       ${DKIM_TXT_RAW}

  DMARC (TXT):
    Name:        _dmarc
    Type:        TXT
    Value:       v=DMARC1; p=${DMARC_POLICY}; adkim=s; aspf=s; rua=mailto:postmaster@${DOMAIN}; ruf=mailto:postmaster@${DOMAIN}; fo=1

NOTES:
  - Ensure rDNS/PTR for ${IP} is set to: ${MAIL_HOST}.
  - Outbound port 25 must be open (provider can block it).
  - To test STARTTLS from Mac:
      openssl s_client -starttls smtp -connect ${MAIL_HOST}:587 -servername ${MAIL_HOST}

DKIM TESTKEY OUTPUT (last lines):
$(tail -n 8 /tmp/opendkim-testkey.txt 2>/dev/null || true)

============================================================

EOF
