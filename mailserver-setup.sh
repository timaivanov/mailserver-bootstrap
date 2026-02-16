#!/usr/bin/env bash
set -euo pipefail

# =============================
# Mail server bootstrap (Postfix + Dovecot SASL + OpenDKIM + OpenDMARC + Let's Encrypt)
# Ubuntu 22.x
# =============================

log() { echo -e "[+] $*"; }
warn() { echo -e "[!] $*" >&2; }
die() { echo -e "[x] $*" >&2; exit 1; }

need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root (sudo)."; }

DOMAIN=""
IP=""
MAIL_HOST=""
SELECTOR="s1"
SMTP_USER="mt"
SMTP_PASS=""
DMARC_POLICY="quarantine"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2;;
    --ip) IP="${2:-}"; shift 2;;
    --mail-host) MAIL_HOST="${2:-}"; shift 2;;
    --selector) SELECTOR="${2:-}"; shift 2;;
    --smtp-user) SMTP_USER="${2:-}"; shift 2;;
    --smtp-pass) SMTP_PASS="${2:-}"; shift 2;;
    --dmarc-policy) DMARC_POLICY="${2:-}"; shift 2;;
    -h|--help)
      cat <<EOF
Usage:
  sudo bash $0 --domain example.com --ip 1.2.3.4 [--mail-host mail.example.com]
Options:
  --domain         Root domain (example.com)
  --ip             Server public IP
  --mail-host      Mail hostname (default: mail.\$domain)
  --selector       DKIM selector (default: s1)
  --smtp-user      SMTP user for Mailtrain (default: mt)
  --smtp-pass      SMTP password (default: auto-generate)
  --dmarc-policy   none|quarantine|reject (default: quarantine)
EOF
      exit 0
      ;;
    *) die "Unknown arg: $1";;
  esac
done

need_root
[[ -n "$DOMAIN" ]] || die "--domain is required"
[[ -n "$IP" ]] || die "--ip is required"
[[ -n "$MAIL_HOST" ]] || MAIL_HOST="mail.${DOMAIN}"
[[ "$DMARC_POLICY" =~ ^(none|quarantine|reject)$ ]] || die "--dmarc-policy must be none|quarantine|reject"

if [[ -z "${SMTP_PASS}" ]]; then
  SMTP_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
fi

export DEBIAN_FRONTEND=noninteractive

log "Updating packages"
apt-get update -y

log "Installing packages"
apt-get install -y \
  postfix postfix-pcre \
  dovecot-core dovecot-imapd \
  opendkim opendkim-tools \
  opendmarc \
  certbot \
  ca-certificates curl openssl \
  ufw \
  dnsutils

log "Setting hostname to ${MAIL_HOST}"
hostnamectl set-hostname "${MAIL_HOST}" || true

log "Configuring firewall (ufw)"
ufw allow 22/tcp >/dev/null || true
ufw allow 25/tcp >/dev/null || true
ufw allow 587/tcp >/dev/null || true
ufw allow 993/tcp >/dev/null || true
ufw --force enable >/dev/null || true

# -----------------------------
# TLS cert (Let's Encrypt)
# -----------------------------
CERT_CHAIN="/etc/letsencrypt/live/${MAIL_HOST}/fullchain.pem"
CERT_KEY="/etc/letsencrypt/live/${MAIL_HOST}/privkey.pem"

log "Issuing Let's Encrypt cert for ${MAIL_HOST} (requires A record already pointed to this server)"
if ! certbot certonly --standalone -n --agree-tos -m "postmaster@${DOMAIN}" -d "${MAIL_HOST}"; then
  warn "Certbot failed. You can re-run later:"
  warn "  certbot certonly --standalone -d ${MAIL_HOST}"
  warn "Continuing (Postfix/Dovecot will still be configured, but TLS may fail until cert exists)."
fi

# -----------------------------
# Dovecot: passwd-file user + auth socket for Postfix
# -----------------------------
log "Configuring Dovecot (imap + auth socket for Postfix)"

mkdir -p /etc/dovecot/passwd

# Create passwd-file entry (SHA512-CRYPT)
HASH="$(doveadm pw -s SHA512-CRYPT -p "${SMTP_PASS}")"
echo "${SMTP_USER}:${HASH}" > "/etc/dovecot/passwd/${DOMAIN}.pass"

# Permissions: root:dovecot 640 (we hit this issue already)
chown root:dovecot "/etc/dovecot/passwd/${DOMAIN}.pass"
chmod 640 "/etc/dovecot/passwd/${DOMAIN}.pass"
chmod 755 /etc/dovecot/passwd

cat >/etc/dovecot/conf.d/auth-passwdfile.conf.ext <<EOF
passdb {
  driver = passwd-file
  args = scheme=SHA512-CRYPT username_format=%u /etc/dovecot/passwd/${DOMAIN}.pass
}
userdb {
  driver = static
  args = uid=vmail gid=vmail home=/var/mail/vhosts/%d/%n
}
EOF

# Minimal, correct-format 10-master.conf (we hit "Garbage after '{'" before)
cat >/etc/dovecot/conf.d/10-master.conf <<'EOF'
service imap-login {
  inet_listener imap {
    port = 0
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

# TLS for dovecot
cat >/etc/dovecot/conf.d/10-ssl.conf <<EOF
ssl = required
ssl_cert = <${CERT_CHAIN}
ssl_key = <${CERT_KEY}
EOF

# vmail user for mailbox paths (even if you don't use IMAP actively, safe)
if ! id vmail >/dev/null 2>&1; then
  useradd -r -u 5000 -g mail -d /var/mail/vhosts -s /usr/sbin/nologin vmail || true
fi
mkdir -p /var/mail/vhosts
chown -R vmail:mail /var/mail/vhosts

systemctl restart dovecot
systemctl enable dovecot >/dev/null || true

# Ensure auth socket dir exists (we hit missing /var/spool/postfix/private)
mkdir -p /var/spool/postfix/private
chown postfix:postfix /var/spool/postfix/private
chmod 755 /var/spool/postfix/private

# -----------------------------
# OpenDKIM
# -----------------------------
log "Configuring OpenDKIM"

mkdir -p /etc/opendkim/keys/${DOMAIN}

DKIM_PRIV="/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.private"
DKIM_PUB="/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.txt"

# generate key if not exists
if [[ ! -f "${DKIM_PRIV}" ]]; then
  opendkim-genkey -b 2048 -d "${DOMAIN}" -D "/etc/opendkim/keys/${DOMAIN}" -s "${SELECTOR}"
  mv -f "/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.private" "${DKIM_PRIV}"
  mv -f "/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.txt" "${DKIM_PUB}"
fi

chown -R opendkim:opendkim /etc/opendkim
chmod 0750 /etc/opendkim/keys /etc/opendkim/keys/${DOMAIN}
chmod 0600 "${DKIM_PRIV}"

cat >/etc/opendkim/TrustedHosts <<EOF
127.0.0.1
localhost
${IP}
${MAIL_HOST}
EOF

cat >/etc/opendkim/KeyTable <<EOF
${SELECTOR}._domainkey.${DOMAIN} ${DOMAIN}:${SELECTOR}:${DKIM_PRIV}
EOF

cat >/etc/opendkim/SigningTable <<EOF
*@${DOMAIN} ${SELECTOR}._domainkey.${DOMAIN}
EOF

# IMPORTANT: use refile: maps (this was the exact fix we needed)
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

systemctl restart opendkim
systemctl enable opendkim >/dev/null || true

# DKIM testkey output for report
opendkim-testkey -d "${DOMAIN}" -s "${SELECTOR}" -k "${DKIM_PRIV}" -vvv >/tmp/opendkim-testkey.txt 2>&1 || true

# -----------------------------
# OpenDMARC
# -----------------------------
log "Configuring OpenDMARC"

mkdir -p /etc/opendmarc
mkdir -p /run/opendmarc
chown opendmarc:opendmarc /run/opendmarc
chmod 755 /run/opendmarc

# we hit missing ignore.hosts previously, so create it explicitly
cat >/etc/opendmarc/ignore.hosts <<EOF
127.0.0.1
localhost
${MAIL_HOST}
EOF

cat >/etc/opendmarc.conf <<EOF
AuthservID              ${MAIL_HOST}
PidFile                 /run/opendmarc/opendmarc.pid
RejectFailures          false
Syslog                  true
TrustedAuthservIDs      ${MAIL_HOST}
Socket                  inet:8893@127.0.0.1
IgnoreHosts             /etc/opendmarc/ignore.hosts
EOF

systemctl restart opendmarc
systemctl enable opendmarc >/dev/null || true

# -----------------------------
# Postfix
# -----------------------------
log "Configuring Postfix"

# Basic identity
postconf -e "myhostname = ${MAIL_HOST}"
postconf -e "mydomain = ${DOMAIN}"
postconf -e "myorigin = \$mydomain"
postconf -e "mydestination = localhost"
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = ipv4"

# TLS
postconf -e "smtpd_tls_cert_file = ${CERT_CHAIN}"
postconf -e "smtpd_tls_key_file = ${CERT_KEY}"
postconf -e "smtpd_tls_security_level = may"
postconf -e "smtp_tls_security_level = may"
postconf -e "smtpd_tls_loglevel = 1"
postconf -e "smtpd_tls_received_header = yes"

# SASL via dovecot socket
postconf -e "smtpd_sasl_type = dovecot"
postconf -e "smtpd_sasl_path = private/auth"
postconf -e "smtpd_sasl_auth_enable = yes"
postconf -e "broken_sasl_auth_clients = yes"
postconf -e "smtpd_recipient_restrictions = permit_sasl_authenticated,reject_unauth_destination"

# Milters: DKIM + DMARC
postconf -e "milter_protocol = 6"
postconf -e "milter_default_action = accept"
postconf -e "smtpd_milters = inet:127.0.0.1:8891, inet:127.0.0.1:8893"
postconf -e "non_smtpd_milters = inet:127.0.0.1:8891, inet:127.0.0.1:8893"

# submission service in master.cf
log "Configuring submission service in master.cf"
if ! grep -qE '^submission\s+inet' /etc/postfix/master.cf; then
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
fi

# Disable TLS1.3 on submission (we hit TLSv1.3 early data issues)
if ! grep -q 'smtpd_tls_protocols=.*TLSv1.3' /etc/postfix/master.cf; then
  perl -i -pe 'if(/^submission inet/){$in=1} elsif($in && /^\S/){$in=0} if($in && /milter_macro_daemon_name=ORIGINATING/){$_ .= "  -o smtpd_tls_protocols=!SSLv2,!SSLv3,!TLSv1,!TLSv1.1,!TLSv1.3\n  -o smtpd_tls_mandatory_protocols=!SSLv2,!SSLv3,!TLSv1,!TLSv1.1,!TLSv1.3\n"}' /etc/postfix/master.cf
fi

systemctl restart postfix
systemctl enable postfix >/dev/null || true

# -----------------------------
# Final report
# -----------------------------
log "Preparing final report"

DKIM_TXT_RAW="$(sed '1d;$d' "${DKIM_PUB}" 2>/dev/null | tr -d '\n' | sed -E 's/[[:space:]]+/ /g' || true)"

OUT="/root/MAILSERVER_${DOMAIN}.txt"

cat > "${OUT}" <<EOF
============================================================
MAIL SERVER SETUP COMPLETE

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

chmod 600 "${OUT}"

echo
echo "==================== IMPORTANT OUTPUT ===================="
cat "${OUT}"
echo "=========================================================="
echo
log "Saved also to: ${OUT}"
