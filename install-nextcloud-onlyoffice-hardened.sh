#!/usr/bin/env bash
set -euo pipefail

#############################################
# CONFIGURATION SECTION
#############################################
# Set these variables using environment or prompt if not set
DOMAIN="${DOMAIN:-}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-}"
DB_NAME="${DB_NAME:-nextcloud}"
DB_USER="${DB_USER:-nc_user}"
DB_PASS="${DB_PASS:-}"
NC_ADMIN_USER="${NC_ADMIN_USER:-admin}"
NC_ADMIN_PASS="${NC_ADMIN_PASS:-}"
ONLYOFFICE_JWT="${ONLYOFFICE_JWT:-}"

if [[ -z "$DOMAIN" || -z "$DB_ROOT_PASSWORD" || -z "$DB_PASS" || -z "$NC_ADMIN_PASS" || -z "$ONLYOFFICE_JWT" ]]; then
  echo "You must export DOMAIN, DB_ROOT_PASSWORD, DB_PASS, NC_ADMIN_PASS, and ONLYOFFICE_JWT as environment variables."
  exit 1
fi

#############################################
# SAFETY AND IDPOTENCY CHECKS
#############################################

msg() { echo -e "\n>>>> $1\n"; }

is_installed() { dpkg -s "$1" &>/dev/null; }
file_exists_warn() { [[ -f "$1" ]] && msg "Warning: $1 exists. Consider backing up before continuing."; }
dir_exists_warn() { [[ -d "$1" ]] && msg "Warning: $1 exists. Consider backing up before continuing."; }

msg "Checking for root privileges"
[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }

msg "System update and minimal upgrade"
apt update && apt upgrade -y

msg "Installing basic dependencies"
DEBIAN_FRONTEND=noninteractive apt install -y software-properties-common apt-transport-https ca-certificates curl gnupg lsb-release

# NGINX
msg "Installing NGINX"
is_installed nginx || apt install -y nginx

# PHP 8.3
msg "Installing PHP 8.3 and modules"
if ! php -v 2>/dev/null | grep -q 8.3; then
  add-apt-repository ppa:ondrej/php -y
  apt update
fi
DEBIAN_FRONTEND=noninteractive apt install -y \
  php8.3 php8.3-fpm php8.3-cli php8.3-common php8.3-gd php8.3-mysql \
  php8.3-curl php8.3-xml php8.3-zip php8.3-mbstring php8.3-bz2 php8.3-intl php8.3-gmp \
  php8.3-imagick php8.3-bcmath php8.3-redis

# MariaDB
msg "Installing MariaDB"
is_installed mariadb-server || apt install -y mariadb-server mariadb-client

msg "Configuring MariaDB"
mysql_root_ready=$(mysql -u root -e "SELECT user FROM mysql.user WHERE user='root';" | grep root || true)
if [[ -z "$mysql_root_ready" ]]; then
  msg "Error: MariaDB root account not found."
  exit 1
fi

# Create DB and user if not exists
mysql -u root <<MYSQL_EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
MYSQL_EOF

# Nextcloud download and install
msg "Downloading Nextcloud"
cd /tmp
# --- Begin patch: pull ZIP from nextcloud-releases/server official repo ---
NEXTCLOUD_LATEST_JSON=$(curl -fsSL https://api.github.com/repos/nextcloud-releases/server/releases/latest)
if ! command -v jq >/dev/null 2>&1; then
  apt install -y jq
fi
NEXTCLOUD_URL=$(echo "$NEXTCLOUD_LATEST_JSON" | jq -r '.assets[] | select(.name|test("\\.zip$")) | .browser_download_url' | head -1)
if [[ -z "$NEXTCLOUD_URL" ]]; then
  echo "Unable to find Nextcloud ZIP URL from nextcloud-releases/server repo"; exit 1
fi
NEXTCLOUD_ZIP=$(basename "$NEXTCLOUD_URL")
wget -O "$NEXTCLOUD_ZIP" "$NEXTCLOUD_URL"

msg "Extracting Nextcloud"
dir_exists_warn "/var/www/nextcloud"
if [[ -d /var/www/nextcloud ]]; then
  mv "/var/www/nextcloud" "/var/www/nextcloud.$(date +%s).bak"
fi
apt install -y unzip

unzip "$NEXTCLOUD_ZIP" -d /var/www/
mkdir -p /var/www/nextcloud/data
chown -R www-data:www-data /var/www/nextcloud

msg "Configuring NGINX for Nextcloud"
/etc/init.d/nginx stop || true # Ensure nginx is not running with old config
file_exists_warn "/etc/nginx/sites-available/nextcloud.conf"
cat >/etc/nginx/sites-available/nextcloud.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    root /var/www/nextcloud/;
    client_max_body_size 512M;
    fastcgi_buffers 64 4K;
    index index.php;
    location / {
        try_files \$uri \$uri/ /index.php\$request_uri;
    }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    }
    location ~ /\.ht {
        deny all;
    }
}
EOF

ln -sf /etc/nginx/sites-available/nextcloud.conf /etc/nginx/sites-enabled/nextcloud.conf
[ -e /etc/nginx/sites-enabled/default ] && rm -f /etc/nginx/sites-enabled/default

msg "Test NGINX config and start"
nginx -t && systemctl restart nginx

# OnlyOffice Document Server
msg "Installing OnlyOffice Document Server dependencies (nodejs, fonts)"
is_installed fonts-dejavu-core || apt install -y fonts-dejavu-core

msg "Adding OnlyOffice repo and key"
curl -sL https://download.onlyoffice.com/repo/onlyoffice.key | gpg --dearmor -o /usr/share/keyrings/onlyoffice.gpg
echo "deb [signed-by=/usr/share/keyrings/onlyoffice.gpg] https://download.onlyoffice.com/repo/debian/ squeeze main" \
    > /etc/apt/sources.list.d/onlyoffice.list

apt update
is_installed onlyoffice-documentserver || apt install -y onlyoffice-documentserver

msg "Configuring OnlyOffice JWT"
onlyoffice_cfg="/etc/onlyoffice/documentserver/local.json"
if [[ -f "$onlyoffice_cfg" ]]; then
  sed -i "s/\(\"secret\":\s*\)\"[^\"]*\"/\1\"${ONLYOFFICE_JWT}\"/" "$onlyoffice_cfg"
else
  echo "Warning: OnlyOffice config file not found at $onlyoffice_cfg"
fi

msg "Configuring NGINX for OnlyOffice"
file_exists_warn "/etc/nginx/sites-available/onlyoffice.conf"
cat >/etc/nginx/sites-available/onlyoffice.conf <<EOF
server {
    listen 8080;
    server_name ${DOMAIN};
    access_log /var/log/nginx/onlyoffice-access.log;
    error_log /var/log/nginx/onlyoffice-error.log;
    include /etc/nginx/includes/onlyoffice-documentserver.conf;
}
EOF

ln -sf /etc/nginx/sites-available/onlyoffice.conf /etc/nginx/sites-enabled/onlyoffice.conf
nginx -t && systemctl reload nginx

msg "Restarting services"
systemctl restart nginx
systemctl restart php8.3-fpm
systemctl restart mariadb
is_installed supervisor && systemctl restart supervisor

# Nextcloud OCC install if not already installed
if ! sudo -u www-data php /var/www/nextcloud/occ status 2>&1 | grep -q "installed: true"; then
  msg "Configuring Nextcloud (OCC maintenance:install)"
  sudo -u www-data php /var/www/nextcloud/occ maintenance:install \
    --database "mysql" \
    --database-name "${DB_NAME}" \
    --database-user "${DB_USER}" \
    --database-pass "${DB_PASS}" \
    --admin-user "${NC_ADMIN_USER}" \
    --admin-pass "${NC_ADMIN_PASS}"
else
  msg "Nextcloud already installed. Skipping OCC install."
fi

msg "Installing/Enabling OnlyOffice app in Nextcloud"
sudo -u www-data php /var/www/nextcloud/occ app:install onlyoffice || true
sudo -u www-data php /var/www/nextcloud/occ app:enable onlyoffice

msg "Applying OnlyOffice plugin configuration in Nextcloud"
sudo -u www-data php /var/www/nextcloud/occ config:system:set onlyoffice DocumentServerUrl --value="http://${DOMAIN}:8080/"
sudo -u www-data php /var/www/nextcloud/occ config:system:set onlyoffice jwt_secret --value="${ONLYOFFICE_JWT}"

msg "Firewall: opening required ports (80/8080)"
if command -v ufw >/dev/null; then
  ufw allow 80/tcp
  ufw allow 8080/tcp
fi

cat <<END

==========================================
  INSTALLATION COMPLETE
  Nextcloud:   http://${DOMAIN}
  OnlyOffice:  http://${DOMAIN}:8080
==========================================

- Passwords and secrets were not stored in this script.
- If running behind a proxy, confirm proxy headers and HTTPS.
- Consider setting up SSL certificates or secure proxy.
- Harden MariaDB/Nextcloud per best security practices.

END
