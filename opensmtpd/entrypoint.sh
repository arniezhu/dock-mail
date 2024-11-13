#!/bin/sh
set -e

# Set variables
DKIM_KEYS_DIR="/etc/rspamd/keys"
DKIM_PRIVATE_KEY="$DKIM_KEYS_DIR/dkim_private.pem"
DOMAIN=${DOMAIN:-"example.com"}
DKIM_SELECTOR=${DKIM_SELECTOR:-"mail"}
TZ=${TZ:-"UTC"}

# Validate timezone file
if [[ ! -f "/usr/share/zoneinfo/$TZ" ]]; then
    echo "Fatal: Invalid timezone '$TZ'" >&2
    exit 1
fi

# Set timezone symlink
ln -fs "/usr/share/zoneinfo/$TZ" /etc/localtime || {
    echo "Fatal: Failed to create timezone symlink" >&2
    exit 1
}

# Write timezone config
echo "$TZ" > /etc/timezone || {
    echo "Fatal: Failed to write timezone config" >&2
    exit 1
}

# Set ownership of SSL certificate files to root
chown root:root /etc/ssl/tls-certs/fullchain.pem
chown root:root /etc/ssl/private/privkey.pem

# Generate individual CA certificate files from fullchain.pem
echo "Update CA certificates"
awk 'BEGIN {n=0;} /BEGIN CERTIFICATE/ {n++} {print > "/usr/local/share/ca-certificates/ca-cert-" n ".crt"}' \
    /etc/ssl/tls-certs/fullchain.pem
update-ca-certificates

# DKIM key setup
if [ ! -f "$DKIM_PRIVATE_KEY" ]; then
    echo "DKIM private key not found, generate a new one"
    mkdir -p "$DKIM_KEYS_DIR"
    openssl genrsa -out "$DKIM_PRIVATE_KEY" 2048
    chown rspamd:rspamd "$DKIM_PRIVATE_KEY"
    chmod 600 "$DKIM_PRIVATE_KEY"
    openssl rsa -in "$DKIM_PRIVATE_KEY" -pubout -out "$DKIM_KEYS_DIR/dkim_public.pem"

    # Remove header/footer from the public key, remove line breaks, and split for DNS
    sed -e '/^-----BEGIN PUBLIC KEY-----$/d' \
        -e '/^-----END PUBLIC KEY-----$/d' "$DKIM_KEYS_DIR/dkim_public.pem" | tr -d '\n' > /tmp/dkim_public_key.txt
    # Generate the DNS record with proper formatting
    {
        echo "$DKIM_SELECTOR._domainkey.$DOMAIN IN TXT ("
        awk -v prefix="v=DKIM1; k=rsa; p=" '{print prefix $0}' /tmp/dkim_public_key.txt | fold -w 255 | \
        awk '{print "\"" $0 "\""}'
        echo ")"
    } > "$DKIM_KEYS_DIR/${DKIM_SELECTOR}._domainkey.${DOMAIN}.txt"
    rm /tmp/dkim_public_key.txt
else
    echo "Use existing DKIM private key"
    chown rspamd:rspamd "$DKIM_PRIVATE_KEY"
    chmod 600 "$DKIM_PRIVATE_KEY"
fi

# Ensure Rspamd DKIM configuration exists
cat <<EOF > /etc/rspamd/local.d/dkim_signing.conf
# Enable DKIM signing for $DOMAIN
domain {
    $DOMAIN {
        selector = "$DKIM_SELECTOR";
        path = "$DKIM_PRIVATE_KEY";
    }
}

# Additional settings for signing behavior
allow_username_mismatch = true;
sign_local = true;
sign_inbound = false;
use_domain = "envelope";
allow_hdrfrom_mismatch = false;
EOF

echo "Rspamd DKIM configuration created at /etc/rspamd/local.d/dkim_signing.conf"

# Start Rspamd
echo "Start Rspamd"
exec su-exec rspamd rspamd -f &

# Set up domains, users, and hostnames
echo "$DOMAIN" > /etc/mail/domains
echo -e "@$DOMAIN\tvmail" > /etc/mail/users

cat <<EOF >  /etc/mail/hostnames
127.0.0.1	localhost
$(hostname -i)	smtp.$DOMAIN
$IP_ADDRESS	smtp.$DOMAIN
EOF

# Define configuration file path
CONFIG_FILE="/etc/mail/smtpd.conf"

# Set up relay server information
if [[ -n "$RELAY_NAME" && -n "$RELAY_SERVER" && -n "$RELAY_PORT" && -n "$RELAY_USERNAME" && -n "$RELAY_PASSWORD" ]]; then
    echo -e "$RELAY_NAME\t$RELAY_USERNAME:$RELAY_PASSWORD" > /etc/mail/relay_auth
    cp /etc/mail/smtpd.conf /etc/mail/smtpd_updated.conf
    sed -i "s|\(action \"relay_auth\" relay helo-src <helo_table>\)|table relay_auth file:/etc/mail/relay_auth\n\1 host smtp+tls://$RELAY_NAME@$RELAY_SERVER:$RELAY_PORT auth <relay_auth>|" /etc/mail/smtpd_updated.conf
    CONFIG_FILE="/etc/mail/smtpd_updated.conf"
fi

# Start OpenSMTPD
echo "Start OpenSMTPD"
exec smtpd -d -f "$CONFIG_FILE" #-T all
