#!/bin/sh

while :; do
    if [ "$(find /etc/letsencrypt/live/fullchain.pem -mtime +60 2>/dev/null)" ]; then
        echo "[`date '+%Y-%m-%d %H:%M:%S'`] SSL certificate renewal"
        certbot renew --webroot -w /var/www/certbot --quiet

        CERT_PATH=$(find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d | head -n 1)

        if [ -n "$CERT_PATH" ]; then
            cp $CERT_PATH/fullchain.pem /etc/letsencrypt/live/fullchain.pem
            cp $CERT_PATH/privkey.pem /etc/letsencrypt/keys/privkey.pem
            docker restart opensmtpd dovecot >/dev/null 2>&1
        fi
    fi

    sleep 168h
done
