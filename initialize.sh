#!/bin/bash

# Define color highlights
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

# Prompt user for domain and email information
read -p "Enter your top-level domain (e.g., example.com): " DOMAIN
read -p "Enter your email for Let's Encrypt notifications: " EMAIL

# Prompt user for PostgreSQL database details with default values
read -p "Enter the PostgreSQL database name [default: dockmail]: " DB_NAME
DB_NAME=${DB_NAME:-"dockmail"}
read -p "Enter the PostgreSQL database username [default: dockmail]: " DB_USER
DB_USER=${DB_USER:-"dockmail"}
read -p "Enter the PostgreSQL database password [default: dockmail]: " DB_PASS
DB_PASS=${DB_PASS:-"dockmail"}

# Prompt user for timezone
read -p "Enter your timezone (e.g., Asia/Shanghai) [default: UTC]: " TIMEZONE
TIMEZONE=${TIMEZONE:-"UTC"}

# Prompt user for server IP address
DEFAULT_IP=$(wget -qO- https://ipinfo.io/ip || echo "")
if [ -n "$DEFAULT_IP" ]; then
    read -p "Enter the server IP address [default: $DEFAULT_IP]: " IP_ADDRESS
else
    read -p "Enter the server IP address: " IP_ADDRESS
fi
IP_ADDRESS=${IP_ADDRESS:-$DEFAULT_IP}

# Ask if a relay server should be used
read -p "Do you want to use a relay server? (y/N): " USE_RELAY

# Prompt user for relay server details
if [[ "$USE_RELAY" =~ ^[Yy]$ ]]; then
    read -p "Enter the relay name (e.g., sendgrid): " RELAY_NAME
    read -p "Enter the relay server (e.g., smtp.sendgrid.net): " RELAY_SERVER
    read -p "Enter the relay port [default: 587]: " RELAY_PORT
    RELAY_PORT=${RELAY_PORT:-"587"}
    read -p "Enter the relay username: " RELAY_USERNAME
    read -p "Enter the relay password: " RELAY_PASSWORD
fi

# Ensure DOMAIN, EMAIL, and IP_ADDRESS are not empty
if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ] || [ -z "$IP_ADDRESS" ]; then
    echo -e "${RED}Error: Domain, email, and IP address are required.${NC}"
    exit 1
fi

SMTP_DOMAIN="smtp.$DOMAIN"
IMAP_DOMAIN="imap.$DOMAIN"

echo "Configuring for domain: $DOMAIN"
echo "SMTP: $SMTP_DOMAIN"
echo "IMAP: $IMAP_DOMAIN"

# Set environment variables for PostgreSQL and Dovecot
for dir in postgres dovecot; do
    cp "./$dir/.env.example" "./$dir/.env"
    sed -i \
        -e "s|POSTGRES_DB=dockmail|POSTGRES_DB=$DB_NAME|" \
        -e "s|POSTGRES_USER=dockmail|POSTGRES_USER=$DB_USER|" \
        -e "s|POSTGRES_PASSWORD=dockmail|POSTGRES_PASSWORD=$DB_PASS|" \
        -e "s|TZ=UTC|TZ=$TIMEZONE|" \
        "./$dir/.env"
done

# Set OpenSMTPD environment variables
cp ./opensmtpd/.env.example ./opensmtpd/.env
sed -i \
    -e "s|DOMAIN=example.com|DOMAIN=$DOMAIN|" \
    -e "s|TZ=UTC|TZ=$TIMEZONE|" \
    -e "s|IP_ADDRESS=0.0.0.0|IP_ADDRESS=$IP_ADDRESS|" \
    ./opensmtpd/.env

if [ -n "$RELAY_NAME" ]; then
    echo "RELAY_NAME=$RELAY_NAME" >> ./opensmtpd/.env
    echo "RELAY_SERVER=$RELAY_SERVER" >> ./opensmtpd/.env
    echo "RELAY_PORT=$RELAY_PORT" >> ./opensmtpd/.env
    echo "RELAY_USERNAME=$RELAY_USERNAME" >> ./opensmtpd/.env
    echo "RELAY_PASSWORD=$RELAY_PASSWORD" >> ./opensmtpd/.env
fi

# Set Webmail environment variables
cp ./webmail/.env.example ./webmail/.env
sed -i \
    -e "s|example.com|$DOMAIN|g" \
    -e "s|ROUNDCUBEMAIL_DB_NAME=dockmail|ROUNDCUBEMAIL_DB_NAME=$DB_NAME|" \
    -e "s|ROUNDCUBEMAIL_DB_USER=dockmail|ROUNDCUBEMAIL_DB_USER=$DB_USER|" \
    -e "s|ROUNDCUBEMAIL_DB_PASSWORD=dockmail|ROUNDCUBEMAIL_DB_PASSWORD=$DB_PASS|" \
    -e "s|TZ=UTC|TZ=$TIMEZONE|" \
    ./webmail/.env

# Initialize an empty credentials file with read-only permission
echo > ./opensmtpd/credentials
chmod 400 ./opensmtpd/credentials

# Create directories for certificates, keys, and Certbot webroot
mkdir -p ./shared/certs ./shared/keys ./certbot/webroot

# Start Certbot container for SSL certificate generation
echo "Starting Certbot container..."
docker compose up -d certbot
sleep 5

# Run Certbot to generate initial SSL certificates
echo "Requesting SSL certificates..."
docker exec certbot certbot certonly --webroot -w /var/www/certbot \
    -d $SMTP_DOMAIN -d $IMAP_DOMAIN \
    --email $EMAIL --agree-tos --non-interactive

# Wait for the certificate directory to be created
MAX_RETRIES=10
RETRY_COUNT=0
echo "Waiting for certificate directory..."

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    CERT_PATH=$(docker exec certbot /bin/sh -c "ls /etc/letsencrypt/live | grep '$DOMAIN' | head -n 1")
    if [ -n "$CERT_PATH" ]; then
        echo "Certificates generated at /etc/letsencrypt/live/$CERT_PATH"
        break
    else
        RETRY_COUNT=$((RETRY_COUNT + 1))
        echo "Retrying... ($RETRY_COUNT/$MAX_RETRIES)"
        sleep 3
    fi
done

# Check if certificates were generated
if [ -n "$CERT_PATH" ]; then
    docker cp certbot:/etc/letsencrypt/archive/$CERT_PATH/fullchain1.pem ./shared/certs/fullchain.pem
    docker cp certbot:/etc/letsencrypt/archive/$CERT_PATH/privkey1.pem ./shared/keys/privkey.pem
    echo "Certificates copied successfully."
else
    echo -e "${RED}Error: Certificate generation failed.${NC}"
    docker compose stop certbot
    exit 1
fi

# Stop the Certbot container
docker compose stop certbot

# Final message
echo -e "${GREEN}SSL certificates generated and applied.${NC}"
echo -e "Run \`${YELLOW}docker compose up -d${NC}\` to start the services."
