#!/usr/bin/env bash
# install.sh – Clean ERPNext Docker setup on Ubuntu
# WARNING: This script removes any existing ERPNext data and volumes.
# It installs Docker/Compose, clones the frappe_docker repo, builds the containers,
# and then creates (or updates) the ERPNext site “crm.slimrate.com” with the proper
# Redis URLs.
#
# Usage:
#   wget https://raw.githubusercontent.com/TheMarkest/erpnextinstall/refs/heads/main/setup.sh
#   chmod +x setup.sh
#   ./setup.sh
#
set -euo pipefail

# ---------- 1. Update System & Install Prerequisites -----------
echo "==> Updating system and installing prerequisites..."
sudo apt update -y && sudo apt upgrade -y
sudo apt install -y curl git

# ---------- 2. Install Docker and Docker Compose -----------
echo "==> Installing Docker..."
if ! command -v docker &>/dev/null; then
    sudo apt install -y docker.io
    sudo systemctl enable docker
    sudo systemctl start docker
else
    echo "Docker is already installed."
fi

echo "==> Installing Docker Compose..."
if ! command -v docker-compose &>/dev/null; then
    sudo apt install -y docker-compose
else
    echo "Docker Compose is already installed."
fi

# ---------- 3. Add current user to the docker group (if needed) -----------
if ! groups "$USER" | grep -qw docker; then
    echo "==> Adding $USER to docker group. Log out and back in for changes to take effect."
    sudo usermod -aG docker "$USER"
fi

# ---------- 4. Clone (or update) the frappe_docker repository -----------
echo "==> Cloning (or updating) the frappe_docker repository..."
if [ ! -d "frappe_docker" ]; then
    git clone https://github.com/frappe/frappe_docker.git
else
    echo "frappe_docker directory exists. Updating..."
    cd frappe_docker && git pull && cd ..
fi
cd frappe_docker

# ---------- 5. Remove any conflicting compose.yaml file -----------
echo "==> Removing any conflicting compose.yaml file..."
rm -f compose.yaml

# ---------- 6. Create a fresh .env file ----------
echo "==> Creating .env file..."
cat <<'EOF' > .env
# Site and passwords
SITE_NAME=crm.slimrate.com
DB_PASSWORD=SuperSecureDBPassword
ADMIN_PASSWORD=SuperSecureAdminPassword

# Version tags
ERPNEXT_VERSION=version-14
FRAPPE_VERSION=version-14

# Redis & Database connection settings – note these use the proper redis:// scheme.
REDIS_CACHE=redis://redis-cache:6379
REDIS_QUEUE=redis://redis-queue:6379
REDIS_SOCKETIO=redis://redis-queue:6379
SOCKETIO_PORT=9000

DB_HOST=mariadb
DB_PORT=3306
EOF

# ---------- 7. Create a docker-compose.yml file ----------
echo "==> Creating docker-compose.yml..."
cat <<'EOF' > docker-compose.yml
version: "3.9"
services:
  mariadb:
    image: mariadb:10.6
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: ${DB_PASSWORD}
      MYSQL_DATABASE: erpnext
      MYSQL_USER: erpnext
      MYSQL_PASSWORD: ${DB_PASSWORD}
    volumes:
      - mariadb-data:/var/lib/mysql

  redis-cache:
    image: redis:latest
    restart: always
    volumes:
      - redis-cache-data:/data

  redis-queue:
    image: redis:latest
    restart: always
    volumes:
      - redis-queue-data:/data

  backend:
    image: frappe/erpnext:${ERPNEXT_VERSION}
    restart: always
    depends_on:
      - mariadb
      - redis-cache
      - redis-queue
    environment:
      DB_HOST: ${DB_HOST}
      DB_PORT: ${DB_PORT}
      REDIS_CACHE: ${REDIS_CACHE}
      REDIS_QUEUE: ${REDIS_QUEUE}
      REDIS_SOCKETIO: ${REDIS_SOCKETIO}
      SOCKETIO_PORT: ${SOCKETIO_PORT}
    volumes:
      - sites:/home/frappe/frappe-bench/sites

  websocket:
    image: frappe/erpnext:${ERPNEXT_VERSION}
    restart: always
    depends_on:
      - backend
      - redis-queue
    command: ["node", "/home/frappe/frappe-bench/apps/frappe/socketio.js"]
    environment:
      REDIS_QUEUE: ${REDIS_QUEUE}
      REDIS_SOCKETIO: ${REDIS_SOCKETIO}
    volumes:
      - sites:/home/frappe/frappe-bench/sites

  frontend:
    image: frappe/erpnext:${ERPNEXT_VERSION}
    restart: always
    depends_on:
      - backend
      - websocket
    command: ["nginx-entrypoint.sh"]
    environment:
      BACKEND: backend:8000
      SOCKETIO: websocket:${SOCKETIO_PORT}
      CLIENT_MAX_BODY_SIZE: 50m
    volumes:
      - sites:/home/frappe/frappe-bench/sites

volumes:
  mariadb-data:
  redis-cache-data:
  redis-queue-data:
  sites:
EOF

# ---------- 8. Launch ERPNext Containers ----------
echo "==> Launching ERPNext containers..."
docker-compose up -d --build

echo "==> Waiting 60 seconds for containers to initialize..."
sleep 60

# ---------- 9. Create or update the ERPNext site ----------
echo "==> Checking for site ${SITE_NAME}..."
if docker-compose exec backend bench --site "${SITE_NAME}" version >/dev/null 2>&1; then
    echo "Site exists. Updating Redis settings..."
    docker-compose exec backend bash -c 'bench --site "${SITE_NAME}" set-config redis_cache "redis://redis-cache:6379"'
    docker-compose exec backend bash -c 'bench --site "${SITE_NAME}" set-config redis_queue "redis://redis-queue:6379"'
    docker-compose exec backend bash -c 'bench --site "${SITE_NAME}" set-config redis_socketio "redis://redis-queue:6379"'
else
    echo "Site does not exist. Creating new site ${SITE_NAME}..."
    docker-compose exec backend bash -c 'export REDIS_CACHE="redis://redis-cache:6379"; export REDIS_QUEUE="redis://redis-queue:6379"; export REDIS_SOCKETIO="redis://redis-queue:6379"; bench new-site "${SITE_NAME}" --mariadb-root-password "${DB_PASSWORD}" --admin-password "${ADMIN_PASSWORD}"'
fi

# ---------- 10. Restart containers to ensure configuration takes effect ----------
echo "==> Restarting containers..."
docker-compose restart

echo "==> ERPNext setup complete!"
docker-compose ps
echo "You can now access your ERPNext site at: http://<YOUR_SERVER_IP> (or update your DNS to point crm.slimrate.com)."
echo "For troubleshooting, check container logs (for example: docker logs -f frappe_docker_websocket_1)."
exit 0
