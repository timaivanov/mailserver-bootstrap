#!/usr/bin/env bash
set -Eeuo pipefail

# =============== CONFIG / LOGGING ===============
LOG_FILE="/root/mailserver-setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { echo -e "[+] $*"; }
warn() { echo -e "[!] $*" >&2; }
die()  { echo -e "[x] $*" >&2; exit 1; }

trap 'warn "Failed on line $LINENO. See: $LOG_FILE"; tail -n 120 "$LOG_FILE" || true' ERR

need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root (sudo)."; }

# =============== ARGS ===============
DOMAIN=""
IP=""
MAIL_HOST=""
SELECTOR="s1"
SMTP_USER="mt"
SMTP_PASS=""
DMARC_POLICY="quarantine"
POSTMASTER_EMAIL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2;;
    --ip) IP="${2:-}"; shift 2;;
    --mail-host) MAIL_HOST="${2:-}"; shift 2;;
    --selector) SELECTOR="${2:-}"; shift 2;;
    --smtp-user) SMTP_USER="${2:-}"; shift 2;;
    --smtp-pass) SMTP_PASS="${2:-}"; shift 2;;
    --dmarc-policy) DMARC_POLICY="${2:-}"; shift 2;;
    --email) POSTMASTER_EMAIL="${2:-}"; shift 2;;
    -h|--help)
      cat <<EOF
Usage:
  sudo bash $0 --domain example.com --ip 1.2.3.4 [--mail-host mail.example.com] [--email postmaster@example.com]

Options:
  --domain         Root domain (example.com)
  --ip             Server public IPv4
  --mail-host      Mail hostname (default: mail.\$domain)
  --selector       DKIM selector (default: s1)
  --smtp-user      SMTP user for Mailtrain (default: mt)
  --smtp-pass      SMTP password (default: auto-generate)
  --dmarc-policy   none|quarantine|reject (default: quarantine)
  --email          Let's Encrypt contact email (default: postmaster@domain)
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
[[ -n "$POSTMASTER_EMAIL" ]] || POSTMASTER_EMAIL="postmaster@${DOMAIN}"
[[ "$DMARC_POLICY" =~ ^(none|quarantine|reject)$ ]] || die "--dmarc-policy must be none|quarantine|reject"

# Password generation WITHOUT SIGPIPE
if [[ -z "${SMTP_PASS}" ]]; then
  SMTP_PASS="$(openssl rand -hex 12)" # 24 chars, stable
fi

export DEBIAN_FRONTEND=noninteractive

log "Starting mailserver setup"
log "DOMAIN=$DOMAIN IP=$IP MAIL_HOST=$MAIL_HOST SELECTOR=$SELECTOR"
log "Log: $LOG_FILE"

# =============== PACKAGES ===============
log "APT update"
apt-get update -y

log "Install prerequisites"
apt-get install -y ca-certificates curl openssl ufw dnsutils debconf-utils dos2unix

# Preseed postfix to avoid interactive prompts
echo "postfix postfix/mailname string ${MAIL_HOST}" | debconf-set-selections
echo "postfix postfix/main_mailer_type select Internet Site" | debconf-set-selections

log "Install mail packages"
apt-get install -y postfix postfix-pcre dovecot-core dovecot-imapd opendkim opendkim-tools opendmarc certbot

# =============== HOSTNAME ===============
log "Set hostname"
hostnamectl set-hostname "${MAIL_HOST}" || true

# =============== FIREWALL ===============
log "Configure UFW"
ufw allow 22/tcp >/dev/null || true
ufw allow 80/tcp >/dev/null || true    # certbot standalone
ufw allow 25/tcp >/dev/null || true
ufw allow 587/tcp >/dev/null || true
ufw allow 993/tcp >/dev/null || true
ufw --force enable >/dev/null || true
ufw reload >/dev/null || true
ufw status || true

# =============== CERTBOT (standalone) ===============
CERT_CHAIN="/etc/letsencrypt/live/${MAIL_HOST}/fullchain.pem"
CERT_KEY="/etc/letsencrypt/live/${MAIL_HOST}/privkey.pem"

log "Issue/renew Let's Encrypt cert for ${MAIL_HOST}"
systemctl stop nginx apache2 2>/dev/null || true

if certbot certonly --standalone -n --agree-tos -m "${POSTMASTER_EMAIL}" -d "${MAIL_HOST}"; then
  log "Cert OK: ${CERT_CHAIN}"
else
  warn "Certbot failed. We'll use snakeoil TLS for now."
fi

# TLS fallback
if [[ -f "${CERT_CHAIN}" && -f "${CERT_KEY}" ]]; then
  SSL_CERT_PATH="${CERT_CHAIN}"
  SSL_KEY_PATH="${CERT_KEY}"
else
  SSL_CERT_PATH="/etc/ssl/certs/ssl-cert-snakeoil.pem"
  SSL_KEY_PATH="/etc/ssl/private/ssl-cert-snakeoil.key"
fi

# =============== DOVECOT (SMTP AUTH + IMAPS) ===============
log "Configure Dovecot"

# Create vmail (optional)
if ! id vmail >/dev/null 2>&1; then
  useradd -r -u 5000 -g mail -d /var/mail/vhosts -s /usr/sbin/nologin vmail || true
fi
mkdir -p /var/mail/vhosts
chown -R vmail:mail /var/mail/vhosts

# passwd-file for SMTP AUTH user (Mailtrain)
mkdir -p /etc/dovecot/passwd
HASH="$(doveadm pw -s SHA512-CRYPT -p "${SMTP_PASS}")"
echo "${SMTP_USER}:${HASH}" > "/etc/dovecot/passwd/${DOMAIN}.pass"
chown root:dovecot "/etc/dovecot/passwd/${DOMAIN}.pass"
chmod 640 "/etc/dovecot/passwd/${DOMAIN}.pass"
chmod 755 /etc/dovecot/passwd

# Force auth to passwd-file only (no PAM)
cat >/etc/dovecot/conf.d/10-auth.conf <<'EOF'
disable_plaintext_auth = no
auth_mechanisms = plain login

!include auth-passwdfile.conf.ext
EOF

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

# IMPORTANT: multiline blocks only (fixes "Garbage after '{'")
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

cat >/etc/dovecot/conf.d/10-ssl.conf <<EOF
ssl = required
ssl_cert = <${SSL_CERT_PATH}
ssl_key = <${SSL_KEY_PATH}
EOF

# CRLF protection
dos2unix /etc/dovecot/conf.d/10-auth.conf /etc/dovecot/conf.d/10-master.conf /etc/dovecot/conf.d/10-ssl.conf /etc/dovecot/conf.d/auth-passwdfile.conf.ext >/dev/null 2>&1 || true

mkdir -p /var/spool/postfix/private
chown postfix:postfix /var/spool/postfix/private
chmod 755 /var/spool/postfix/private

systemctl enable --now dovecot >/dev/null
systemctl restart dovecot
systemctl status dovecot --no-pager -l

log "Dovecot config sanity (expect passwd-file)"
doveconf -n | egrep -n 'passdb|passwd-file|pam' || true

# =============== OPENDKIM (IDEMPOTENT) ===============
log "Configure OpenDKIM"

mkdir -p "/etc/opendkim/keys/${DOMAIN}"
DKIM_PRIV="/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.private"
DKIM_PUB="/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.txt"

if [[ -f "${DKIM_PRIV}" && -f "${DKIM_PUB}" ]]; then
  log "OpenDKIM keys already exist: ${DKIM_PRIV}"
else
  tmpdir="$(mktemp -d)"
  opendkim-genkey -b 2048 -d "${DOMAIN}" -D "${tmpdir}" -s "${SELECTOR}"
  install -o opendkim -g opendkim -m 0600 "${tmpdir}/${SELECTOR}.private" "${DKIM_PRIV}"
  install -o opendkim -g opendkim -m 0644 "${tmpdir}/${SELECTOR}.txt" "${DKIM_PUB}"
  rm -rf "${tmpdir}"
fi

# Make sure ownership is correct everywhere
chown -R opendkim:opendkim /etc/opendkim
chmod 0750 /etc/opendkim/keys "/etc/opendkim/keys/${DOMAIN}"
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

systemctl enable --now opendkim >/dev/null
systemctl restart opendkim
systemctl status opendkim --no-pager -l

opendkim-testkey -d "${DOMAIN}" -s "${SELECTOR}" -k "${DKIM_PRIV}" -vvv >/tmp/opendkim-testkey.txt 2>&1 || true

# =============== OPENDMARC ===============
log "Configure OpenDMARC"
mkdir -p /etc/opendmarc /run/opendmarc
chown opendmarc:opendmarc /run/opendmarc
chmod 755 /run/opendmarc

# Fix "No such file" we hit before
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

systemctl enable --now opendmarc >/dev/null
systemctl restart opendmarc
systemctl status opendmarc --no-pager -l || true

# =============== POSTFIX ===============
log "Configure Postfix"
postconf -e "myhostname = ${MAIL_HOST}"
postconf -e "mydomain = ${DOMAIN}"
postconf -e "myorigin = \$mydomain"
postconf -e "mydestination = localhost"
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = ipv4"

postconf -e "smtpd_tls_cert_file = ${SSL_CERT_PATH}"
postconf -e "smtpd_tls_key_file = ${SSL_KEY_PATH}"
postconf -e "smtpd_tls_security_level = may"
postconf -e "smtp_tls_security_level = may"
postconf -e "smtpd_tls_loglevel = 1"
postconf -e "smtpd_tls_received_header = yes"

postconf -e "smtpd_sasl_type = dovecot"
postconf -e "smtpd_sasl_path = private/auth"
postconf -e "smtpd_sasl_auth_enable = yes"
postconf -e "broken_sasl_auth_clients = yes"
postconf -e "smtpd_recipient_restrictions = permit_sasl_authenticated,reject_unauth_destination"

postconf -e "milter_protocol = 6"
postconf -e "milter_default_action = accept"
postconf -e "smtpd_milters = inet:127.0.0.1:8891, inet:127.0.0.1:8893"
postconf -e "non_smtpd_milters = inet:127.0.0.1:8891, inet:127.0.0.1:8893"

# Ensure submission service exists (587)
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

# Disable TLS1.3 on submission to avoid weird STARTTLS client issues
# Add only once.
if ! awk 'BEGIN{in=0;added=0} /^submission inet/{in=1} in && /smtpd_tls_mandatory_protocols/ {added=1} END{exit added?0:1}' /etc/postfix/master.cf; then
  perl -i -pe '
    if(/^submission inet/){$in=1}
    elsif($in && /^\S/){$in=0}
    if($in && /milter_macro_daemon_name=ORIGINATING/){
      $_ .= "  -o smtpd_tls_protocols=!SSLv2,!SSLv3,!TLSv1,!TLSv1.1,!TLSv1.3\n";
      $_ .= "  -o smtpd_tls_mandatory_protocols=!SSLv2,!SSLv3,!TLSv1,!TLSv1.1,!TLSv1.3\n";
    }
  ' /etc/postfix/master.cf
fi

systemctl enable --now postfix >/dev/null
systemctl restart postfix
systemctl status postfix --no-pager -l

# =============== FINAL OUTPUT ===============
log "Prepare final output"

# DKIM value formatting: remove header/footer and collapse whitespace
DKIM_TXT_RAW="$(sed '1d;$d' "${DKIM_PUB}" 2>/dev/null | tr -d '\n' | sed -E 's/[[:space:]]+/ /g' || true)"

OUT="/root/MAILSERVER_${DOMAIN}.txt"
cat > "${OUT}" <<EOF
============================================================
MAIL SERVER SETUP COMPLETE

IP:            ${IP}
MAIL HOST:      ${MAIL_HOST}
DOMAIN:         ${DOMAIN}

SMTP (for Mailtrain):
  Host:          ${MAIL_HOST}
  Port:          587
  Encryption:    STARTTLS
  Auth:          YES
  Username:      ${SMTP_USER}
  Password:      ${SMTP_PASS}

DNS RECORDS TO ADD:
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
  - Set PTR/rDNS for ${IP} to: ${MAIL_HOST}
  - Provider must allow outbound 25 (some block it)
  - Test STARTTLS:
      openssl s_client -starttls smtp -connect ${MAIL_HOST}:587 -servername ${MAIL_HOST}

DKIM TESTKEY (tail):
$(tail -n 8 /tmp/opendkim-testkey.txt 2>/dev/null || true)

Log file:
  ${LOG_FILE}
============================================================
EOF

chmod 600 "${OUT}"

echo
echo "==================== IMPORTANT OUTPUT ===================="
cat "${OUT}"
echo "=========================================================="
echo
log "Saved: ${OUT}"
log "Done."
