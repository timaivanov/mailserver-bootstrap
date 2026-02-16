#!/usr/bin/env bash
set -euo pipefail

log()  { echo -e "[+] $*"; }
warn() { echo -e "[!] $*" >&2; }
die()  { echo -e "[x] $*" >&2; exit 1; }

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

# Password generation WITHOUT SIGPIPE (fixes your "тишина")
if [[ -z "${SMTP_PASS}" ]]; then
  # 24 hex chars
  SMTP_PASS="$(openssl rand -hex 12)"
fi

export DEBIAN_FRONTEND=noninteractive

log "Updating packages"
apt-get update -y

log "Installing base packages"
apt-get install -y ca-certificates curl openssl ufw dnsutils debconf-utils

# Preseed postfix to avoid any interactive prompts (fixes hanging installs)
echo "postfix postfix/mailname string ${MAIL_HOST}" | debconf-set-selections
echo "postfix postfix/main_mailer_type select Internet Site" | debconf-set-selections

log "Installing mail stack packages"
apt-get install -y \
  postfix postfix-pcre \
  dovecot-core dovecot-imapd \
  opendkim opendkim-tools \
  opendmarc \
  certbot

log "Setting hostname: ${MAIL_HOST}"
hostnamectl set-hostname "${MAIL_HOST}" || true

log "Configuring firewall (ufw)"
ufw allow 22/tcp >/dev/null || true
ufw allow 25/tcp >/dev/null || true
ufw allow 587/tcp >/dev/null || true
ufw allow 993/tcp >/dev/null || true
ufw --force enable >/dev/null || true

# -----------------------------
# TLS (Let's Encrypt)
# -----------------------------
CERT_CHAIN="/etc/letsencrypt/live/${MAIL_HOST}/fullchain.pem"
CERT_KEY="/etc/letsencrypt/live/${MAIL_HOST}/privkey.pem"

log "Issuing Let's Encrypt cert for ${MAIL_HOST} (requires DNS A record already set)"
if ! certbot certonly --standalone -n --agree-tos -m "postmaster@${DOMAIN}" -d "${MAIL_HOST}"; then
  warn "Certbot failed. TLS on 587/993 may fail until you issue a cert."
  warn "Re-run after DNS is ready: certbot certonly --standalone -d ${MAIL_HOST}"
fi

# -----------------------------
# Dovecot (SASL auth for Postfix + IMAPS)
# -----------------------------
log "Configuring Dovecot"
mkdir -p /etc/dovecot/passwd

HASH="$(doveadm pw -s SHA512-CRYPT -p "${SMTP_PASS}")"
echo "${SMTP_USER}:${HASH}" > "/etc/dovecot/passwd/${DOMAIN}.pass"

# Fix permissions (we hit Permission denied before)
chown root:dovecot "/etc/dovecot/passwd/${DOMAIN}.pass"
chmod 640 "/etc/dovecot/passwd/${DOMAIN}.pass"
chmod 755 /etc/dovecot/passwd

# auth via passwd-file
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

# correct braces (we hit "Garbage after '{'" before)
cat >/etc/dovecot/conf.d/10-master.conf <<'EOF'
service imap-login {
  inet_listener imap { port = 0 }
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

# Dovecot TLS (only if cert exists; if not, it will still start but TLS may complain)
cat >/etc/dovecot/conf.d/10-ssl.conf <<EOF
ssl = required
ssl_cert = <${CERT_CHAIN}
ssl_key = <${CERT_KEY}
EOF

# vmail user
if ! id vmail >/dev/null 2>&1; then
  useradd -r -u 5000 -g mail -d /var/mail/vhosts -s /usr/sbin/nologin vmail || true
fi
mkdir -p /var/mail/vhosts
chown -R vmail:mail /var/mail/vhosts

# ensure postfix auth socket path exists
mkdir -p /var/spool/postfix/private
chown postfix:postfix /var/spool/postfix/private
chmod 755 /var/spool/postfix/private

systemctl enable --now dovecot >/dev/null
systemctl restart dovecot

# sanity: dovecot can read passwd-file
sudo -u dovecot head -n 1 "/etc/dovecot/passwd/${DOMAIN}.pass" >/dev/null \
  || die "Dovecot cannot read passwd-file. Check permissions."

# -----------------------------
# OpenDKIM
# -----------------------------
log "Configuring OpenDKIM"
mkdir -p /etc/opendkim/keys/${DOMAIN}

DKIM_PRIV="/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.private"
DKIM_PUB="/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.txt"

if [[ ! -f "${DKIM_PRIV}" ]]; then
  opendkim-genkey -b 2048 -d "${DOMAIN}" -D "/etc/opendkim/keys/${DOMAIN}" -s "${SELECTOR}"
  mv -f "/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.private" "${DKIM_PRIV}"
  mv -f "/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.txt" "${DKIM_PUB}"
fi

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

# IMPORTANT: refile: maps (this was your working fix)
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

# testkey
opendkim-testkey -d "${DOMAIN}" -s "${SELECTOR}" -k "${DKIM_PRIV}" -vvv >/tmp/opendkim-testkey.txt 2>&1 || true

# -----------------------------
# OpenDMARC
# -----------------------------
log "Configuring OpenDMARC"
mkdir -p /etc/opendmarc /run/opendmarc
chown opendmarc:opendmarc /run/opendmarc
chmod 755 /run/opendmarc

# Fix missing ignore.hosts (we hit that)
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

# -----------------------------
# Postfix
# -----------------------------
log "Configuring Postfix"
postconf -e "myhostname = ${MAIL_HOST}"
postconf -e "mydomain = ${DOMAIN}"
postconf -e "myorigin = \$mydomain"
postconf -e "mydestination = localhost"
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = ipv4"

postconf -e "smtpd_tls_cert_file = ${CERT_CHAIN}"
postconf -e "smtpd_tls_key_file = ${CERT_KEY}"
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

# ensure submission service exists
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

# Disable TLS1.3 on submission (fixes TLSv1.3 early data weirdness)
if ! grep -q 'smtpd_tls_protocols=.*TLSv1.3' /etc/postfix/master.cf; then
  perl -i -pe 'if(/^submission inet/){$in=1} elsif($in && /^\S/){$in=0} if($in && /milter_macro_daemon_name=ORIGINATING/){$_ .= "  -o smtpd_tls_protocols=!SSLv2,!SSLv3,!TLSv1,!TLSv1.1,!TLSv1.3\n  -o smtpd_tls_mandatory_protocols=!SSLv2,!SSLv3,!TLSv1,!TLSv1.1,!TLSv1.3\n"}' /etc/postfix/master.cf
fi

systemctl enable --now postfix >/dev/null
systemctl restart postfix

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
  - Outbound port 25 must be open (provider can block it)
  - Test STARTTLS:
      openssl s_client -starttls smtp -connect ${MAIL_HOST}:587 -servername ${MAIL_HOST}

DKIM TESTKEY (last lines):
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
