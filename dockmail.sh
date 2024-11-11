#!/bin/bash

# Define color highlights
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Database connection information
DB_HOST="localhost"
DB_PORT="6543"

# Load environment variables
if [ -f "./postgres/.env" ]; then
    export $(grep -v '^#' "./postgres/.env" | xargs)
    DB_NAME=${POSTGRES_DB:-"dockmail"}
    DB_USER=${POSTGRES_USER:-"dockmail"}
    DB_PASS=${POSTGRES_PASSWORD:-"dockmail"}
    export PGPASSWORD=$DB_PASS
else
    echo -e "${RED}DockMail service not initialized.${NC}" && exit 1
fi

if [ -f "./opensmtpd/.env" ]; then
    export $(grep -v '^#' "./opensmtpd/.env" | xargs)
else
    echo -e "${RED}DockMail service not initialized.${NC}" && exit 1
fi

# Function to update credentials for OpenSMTPD
update_credentials() {
    local username="$1"
    local password="$2"
    local credentials_file="./opensmtpd/credentials"

    # Check if password is empty (indicating delete request)
    if [ -z "$password" ]; then
        chmod 600 $credentials_file
        sed -i.bak "/^$username\t/d" "$credentials_file"
        chmod 400 "$credentials_file"
        rm -f "${credentials_file}.bak"
        echo "Removed credential for $username."
        return
    fi

    # Encrypt the password using smtpctl
    encrypted_password=$(docker exec opensmtpd smtpctl encrypt "$password")
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to encrypt the password.${NC}"
        return 1
    fi

    # Check if the username already exists and update or insert accordingly
    chmod 600 $credentials_file
    if grep -q "^$username\s" "$credentials_file"; then
        sed -i.bak "s|^$username\t.*|$username\t$encrypted_password|" "$credentials_file"
        rm -f "${credentials_file}.bak"
        echo "Updated credential for $username."
    else
        echo -e "$username\t$encrypted_password" >> "$credentials_file"
        echo "Added credential for $username."
    fi
    chmod 400 $credentials_file

    # Restart OpenSMTPD container
    docker restart opensmtpd > /dev/null 2>&1
}

# Function to add a new user
function add_user() {
    read -p "Enter username: " username
    read -p "Enter password: " password
    read -p "Enter nickname: " nickname

    # Check if username or password is empty
    if [[ -z "$username" || -z "$password" ]]; then
        echo -e "${RED}Username and password cannot be empty.${NC}"
        return
    fi

    # Check if username contains only valid characters
    if [[ ! "$username" =~ ^[a-zA-Z0-9._-]+$ || "$username" =~ [.]$ || "$username" =~ ^[.] || "$username" =~ [..] ]]; then
        echo -e "${RED}Username format is incorrect.${NC}"
        return
    fi

    # Prompt for group ID and ensure it's not lower than 1001
    read -p "Enter group ID (default is 1001): " input_group_id
    if [[ -z "$input_group_id" ]]; then
        group_id=1001
    elif [[ "$input_group_id" -ge 1001 ]]; then
        group_id=$input_group_id
    else
        echo -e "${RED}Group ID must be 1001 or higher.${NC}"
        return
    fi

    # Convert to email address
    username="$username@$DOMAIN"

    # Check if the user already exists
    user_exists=$(psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c \
      "SELECT 1 FROM users WHERE username='$username';")

    if [[ $user_exists -eq 1 ]]; then
        echo -e "${RED}User '$username' already exists.${NC}"
        return
    fi

    # Hash the password using SHA256-CRYPT inside the Dovecot container
    hashed_password=$(docker exec dovecot doveadm pw -s SHA256-CRYPT -p "$password")

    # Mailbox directory for user
    home="/var/mail/$username/mailbox"

    # Insert the new user into the database and return the user ID
    user_id=$(psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -A -c \
        "INSERT INTO users (username, password, nickname, home, group_id) VALUES \
        ('$username', '$hashed_password', '$nickname', '$home', $group_id) RETURNING id;" | head -n 1)

    if [[ -z "$user_id" || ! "$user_id" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Failed to add user.${NC}"
        return
    fi

    # Get the UID and GID of the Dovecot user.
    user_info=$(docker exec dovecot id dovecot)
    uid=$(echo "$user_info" | awk '{print $1}' | cut -d= -f2 | cut -d'(' -f1)
    gid=$(echo "$user_info" | awk '{print $2}' | cut -d= -f2 | cut -d'(' -f1)

    # Create the mailbox directory
    docker exec dovecot mkdir -p $home
    docker exec dovecot chown -R "$uid:$gid" "$home"
    docker exec dovecot chmod -R 775 $home

    # Update credentials for OpenSMTPD
    update_credentials "$username" "$password"

    # User added successfully
    echo -e "${GREEN}User '$username' added successfully with ID '$user_id'.${NC}"
}

# Function to change a user's password
function change_password() {
    read -p "Enter username: " username
    read -p "Enter new password: " password

    # Check if username or new password is empty
    if [[ -z "$username" || -z "$password" ]]; then
        echo -e "${RED}Username and new password cannot be empty.${NC}"
        return
    fi

    # Convert to email address
    username="$username@$DOMAIN"

    # Check if the user exists
    user_exists=$(psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c \
      "SELECT 1 FROM users WHERE username='$username';")

    if [[ $user_exists -ne 1 ]]; then
        echo -e "${RED}User '$username' does not exist.${NC}"
        return
    fi

    # Hash the password using SHA256-CRYPT inside the Dovecot container
    hashed_password=$(docker exec dovecot doveadm pw -s SHA256-CRYPT -p "$password")

    # Update credentials for OpenSMTPD
    update_credentials "$username" "$password"

    # Update the user's password in the database
    psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c \
      "UPDATE users SET password='$hashed_password' WHERE username='$username';" \
      && echo -e "${GREEN}Password for user '$username' has been successfully updated.${NC}" \
      || echo -e "${RED}Failed to change password.${NC}"
}

# Function to modify a user's nickname
function modify_nickname() {
    read -p "Enter username: " username
    read -p "Enter new nickname: " nickname

    # Check if username or new nickname is empty
    if [[ -z "$username" ]]; then
        echo -e "${RED}Username cannot be empty.${NC}"
        return
    fi

    # Convert to email address
    username="$username@$DOMAIN"

    # Check if the user exists
    user_exists=$(psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c \
      "SELECT 1 FROM users WHERE username='$username';")

    if [[ $user_exists -ne 1 ]]; then
        echo -e "${RED}User '$username' does not exist.${NC}"
        return
    fi

    # Update the user's nickname in the database
    psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c \
        "UPDATE users SET nickname='$nickname' WHERE username='$username';" \
        && echo -e "${GREEN}Nickname for user '$username' has been successfully modified to '$nickname'.${NC}" \
        || echo -e "${RED}Failed to modify nickname.${NC}"
}

# Function to list all users
function list_users() {
    # Query to list users
    psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c \
        "SELECT id, group_id, username, nickname, created_at FROM users ORDER BY id ASC;"
}

# Function to delete a user
function delete_user() {
    read -p "Enter username: " username

    # Convert to email address
    username="$username@$DOMAIN"

    # Retrieve the home directory and check if the user exists
    IFS=',' read -r home user_exists < <(psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -A -F ',' -c \
        "SELECT home, 1 FROM users WHERE username='$username';")

    if [[ -z "$user_exists" ]]; then
        echo -e "${RED}User '$username' does not exist.${NC}"
        return
    fi

    # Update credentials for OpenSMTPD
    update_credentials "$username" ""

    # Delete the user from the database
    psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c "DELETE FROM users WHERE username='$username';" \
        && echo -e "${GREEN}User '$username' has been successfully deleted from the database.${NC}" \
        || echo -e "${RED}Failed to delete user from the database.${NC}"

    # Remove the user's home directory
    if [[ -n "$home" && "$home" =~ ^/var/mail/ && ! "$home" =~ \.\. ]]; then
        docker exec dovecot rm -rf "$home" \
        && echo -e "${GREEN}User's home directory '$home' has been successfully removed.${NC}" \
        || echo -e "${RED}Failed to remove user's home directory '$home'.${NC}"
    fi
}

# User menu
echo "User Management"
echo "1. Add User"
echo "2. Delete User"
echo "3. Change password"
echo "4. Modify nickname"
echo "5. List Users"
read -p "Choose an option: " choice

case $choice in
    1) add_user ;;
    2) delete_user ;;
    3) change_password ;;
    4) modify_nickname ;;
    5) list_users ;;
    *) echo "Invalid option" ;;
esac
