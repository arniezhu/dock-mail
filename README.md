# DockMail

**DockMail** is a lightweight, Docker-based email server solution using `OpenSMTPD` for **SMTP** and `Dovecot` for **IMAP**. It supports **DKIM** for email security and includes `Roundcube` as a web-based client.

## Features

- **Lightweight**: Optimized for performance with minimal components.
- **Secure**: Built-in **DKIM** support for email integrity.
- **User-Friendly**: Webmail access via **Roundcube** for a modern interface.

## Installation Guide

### Prerequisites

- Ensure that **Docker**, **Docker Compose 2.x.x**, and **Nginx** are installed and properly configured to avoid compatibility issues.

### Step 1: Configure DNS Records

#### 1.1 A Records for Mail Services

Ensure that the following A records are configured in your DNS:

| Subdomain        | Type | Value            |
|------------------|------|------------------|
| mail.example.com | A    | \<server IP\>    |
| smtp.example.com | A    | \<server IP\>    |
| imap.example.com | A    | \<server IP\>    |

- Replace `<server IP>` with the IP address of your server where **DockMail** is deployed.
- If you are using Cloudflare DNS, the `mail` subdomain can be proxied, but `smtp` and `imap` subdomains must not be proxied.
- The `mail` subdomain can be different from the `smtp` and `imap` subdomains; they do not have to share the same domain name.

#### 1.2 MX Record

Add the following MX record to ensure that emails sent to your domain are correctly routed to the SMTP server:

| Name        | Type | Priority | Value            |
|-------------|------|----------|------------------|
| example.com | MX   | 10       | smtp.example.com |

#### 1.3 SPF Record

Add an SPF record to specify which mail servers are allowed to send emails on behalf of your domain:

| Name        | Type | Value                              |
|-------------|------|------------------------------------|
| example.com | TXT  | v=spf1 a mx ip4:\<server IP\> -all |

### Step 2: Configure Nginx for Webmail and Certbot

Below are two separate Nginx configurations: one for handling Webmail traffic and another for Certbot's SSL validation.

#### 2.1 Nginx Configuration for Webmail

```nginx
server {
    listen 80;
    server_name mail.example.com;

    root /path/to/webmail/webroot;
    index index.php index.html;

    location / {
        try_files $uri $uri/ /index.php?$args;
    }
    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass 127.0.0.1:8999;
        fastcgi_param SCRIPT_FILENAME /var/www/html$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT /var/www/html;
    }
    location ~ /\.ht {
        deny all;
    }
}
```

#### 2.2 Nginx Configuration for Certbot HTTP-01 Validation (SMTP and IMAP)

```nginx
server {
    listen 80;
    server_name smtp.example.com imap.example.com;

    location /.well-known/acme-challenge/ {
        alias /path/to/certbot/webroot/.well-known/acme-challenge/;
    }
    location / {
        deny all;
    }
}
```

- **Explanation**: This configuration allows Certbot to perform `HTTP-01 validation` for SSL certificates by redirecting `.well-known/acme-challenge/` requests to Certbot’s service.

### Step 3: Execute the `initialize.sh` Script

The `initialize.sh` script sets up SSL certificates for the IMAP and SMTP subdomains and modifies the OpenSMTPD configuration to use the provided domain.

#### 3.1 Run the Script

1. Make the script executable:

   ```bash
   chmod +x initialize.sh
   ```

2. Run the script:

   ```bash
   ./initialize.sh
   ```

3. After successful execution:

   - SSL certificates will be generated for `imap.example.com` and `smtp.example.com`.
   - OpenSMTPD configuration will be updated with your specified domain.


#### 3.2 Script Functions

- Generate SSL certificates for `imap.example.com` and `smtp.example.com` using Certbot.
- Update OpenSMTPD configuration with the specified domain.

### 3.3: Open Firewall Ports

To ensure that your mail services are accessible, make sure to open the following ports in your server's firewall:
- **Port 25**: For SMTP communication.
- **Port 587**: For SMTP with STARTTLS.
- **Port 143**: For IMAP.
- **Port 993**: For IMAPS.

You can use the following commands to open these ports (assuming `ufw` as the firewall tool):

```bash
sudo ufw allow 25
sudo ufw allow 587
sudo ufw allow 143
sudo ufw allow 993
sudo ufw reload
```

### Step 4: Start and Verify Docker Services

Start the email server:

```bash
docker compose up -d
```

- Verify that all services are running:

```bash
docker compose ps
```

Ensure that **OpenSMTPD**, **Dovecot**, and **Webmail** containers are running without errors.

#### 4.1 Troubleshooting

If any service is not running or encounters an error, use the following command to check detailed logs:

```bash
docker compose logs -f [service_name]
```

For example:
```bash
docker compose logs -f opensmtpd
```

### Step 5: Configure DKIM Public Key in DNS

The public DKIM key is generated during the setup process and can be found in the following file:

```bash
sudo cat opensmtpd/rspamd/keys/mail._domainkey.example.com.txt
```

Copy the content of this file and add it as a TXT record in your DNS settings:

| Name                  | Type | Value                              |
|-----------------------|------|----------------------------------- |
| mail._domainkey       | TXT  | "v=DKIM1; k=rsa; p=\<public_key\>" |

Make sure to replace `<public_key>` with the Base64-encoded public key found in the file.

### Step 6: Add Users

The `dockmail.sh` script provides a convenient way to manage users (add, delete, modify, list) in the DockMail system.

#### 6.1 Make the script executable

First, make the script executable:

```bash
chmod +x dockmail.sh
```

#### 6.2 Run the script to add a new user

To add a new email user, execute:

```bash
./dockmail.sh
```

- Follow the prompts to enter the username, password, and optional nickname.

#### 6.3 Script Functions

- **Add User**: Create a new user with specified username and password.
- **Delete User**: Remove an existing user from the database.
- **Change Password**: Update the password for an existing user.
- **Modify Nickname**: Update the user's nickname.
- **List Users**: Display a list of existing users.

## Additional Information

- To verify the DKIM setup, you can use [DKIM Validator](https://www.dmarcanalyzer.com/dkim/dkim-check/) or similar tools.
- For troubleshooting, check the logs of individual services using:

```bash
docker compose logs -f opensmtpd
docker compose logs -f dovecot
docker compose logs -f webmail
```
