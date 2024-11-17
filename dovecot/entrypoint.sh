#!/bin/sh
set -e

# Set default values
DB_NAME=${POSTGRES_DB:-"dockmail"}
DB_USER=${POSTGRES_USER:-"dockmail"}
DB_PASS=${POSTGRES_PASSWORD:-"dockmail"}
CONFIG_DIR="/etc/dovecot"
CONFIG_FILE="$CONFIG_DIR/dovecot.conf.ext"

# Create config directory
mkdir -p "$CONFIG_DIR"

# Generate dovecot configuration file
echo "driver = pgsql" > "$CONFIG_FILE"
echo "connect = host=postgres dbname=$DB_NAME user=$DB_USER password=$DB_PASS\n" >> "$CONFIG_FILE"
echo "# Query user password" >> "$CONFIG_FILE"
echo "password_query = SELECT username AS user, password, 'SHA256-CRYPT' AS scheme FROM users WHERE username = '%u' OR aliases @> '[\"%u\"]';\n" >> "$CONFIG_FILE"
echo "# Query user information" >> "$CONFIG_FILE"
echo "user_query = SELECT home, id AS uid, group_id AS gid FROM users WHERE username = '%u' OR aliases @> '[\"%u\"]';" >> "$CONFIG_FILE"

# Start dovecot
dovecot -F
