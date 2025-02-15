#!/usr/bin/env bash
# install.sh - One-Click Clean ERPNext Docker Setup on Ubuntu 24.04
# This script is intended for a fresh Ubuntu instance.
# It installs Docker, Docker Compose, clones frappe_docker, creates the necessary .env
# and docker-compose.yml files, launches containers, and creates a new ERPNext site.
# WARNING: This script will remove any existing ERPNext data and volumes!

set -euo pipefail

# 1. Update apt and install prerequisites
echo "==> Updating system and installing prerequisites..."
sudo apt update -y && sudo apt upgrade -y
sudo apt install -y curl git

# 2. Install Docker if not installed
echo "==> Installing Docker..."
if ! command -v docker &>/dev/null; then
  sudo apt install -y docker.io
  sudo systemctl enable docker
  sudo systemctl start docker
else
  echo "Docker is already installed."
fi

# 3. Install Docker Compose if not installed
echo "==> Installing Docker Compose..."
if ! command -v docker-compose &>/dev/null; then
  sudo apt install -y docker-compose
else
  echo "Docker Compose is already installed."
fi

# 4. Add current user to docker group (if not already)
if ! groups "$USER" | grep -qw docker; then
  echo "==> Adding $USER to docker group. Please log out and log in again for changes to take effect."
  sudo usermod -aG docker "$USER"
fi

# 5. Clone frappe_docker repository (if not already cloned)
echo "==> Cloning frappe_docker repository..."
if [ ! -d "frappe_docker" ]; then
  git clone https://github.com/frappe/frappe_docker.git
else
  echo "frappe_docker directory already exists, updating..."
  cd frappe_docker && git pull && cd ..
fi
cd frappe_docker

# 6. Remove any conflicting Docker Compose file (like compose.yaml)
echo "==> Removing conflicting compose.yaml file if exists..."
rm -f compose.yaml

# 7. Create .env file with proper settings
echo "==> Creating .env file..."
cat <<'EOF' > .env
SITE_NAME=crm.slimrate.com
DB_PASSWORD=SuperSecureDBPassword
ADMIN_PASSWORD=SuperSecureAdminPassword
ERPNEXT_VERSION=version-14
FRAPPE_VERSION=version-14
REDIS_CACHE=redis://redis-cache:6379
REDIS_QUEUE=redis://redis-queue:6379
REDIS_SOCKETIO=redis://redis-queue:6379
SOCKETIO_PORT=9000
DB_HOST=mariadb
DB_PORT=3306
EOF

# 8. Create docker-compose.yml file
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

# 9. Launch ERPNext containers
echo "==> Launching ERPNext containers..."
docker-compose up -d --build

# 10. Wait for containers to initialize (adjust sleep time if needed)
echo "==> Waiting for containers to initialize..."
sleep 60

# 11. Create a new ERPNext site with proper environment settings.
# The bench command must see the correct Redis variables. Export them inline.
echo "==> Creating new ERPNext site..."
docker-compose exec backend bash -c 'export REDIS_CACHE="redis://redis-cache:6379"; export REDIS_QUEUE="redis://redis-queue:6379"; export REDIS_SOCKETIO="redis://redis-queue:6379"; bench new-site crm.slimrate.com --mariadb-root-password "$DB_PASSWORD" --admin-password "$ADMIN_PASSWORD"'

# 12. (Optional) Force-update the site configuration with the correct Redis URLs.
echo "==> Updating site configuration for Redis..."
docker-compose exec backend bash -c 'bench --site crm.slimrate.com set-config redis_cache "redis://redis-cache:6379"'
docker-compose exec backend bash -c 'bench --site crm.slimrate.com set-config redis_queue "redis://redis-queue:6379"'
docker-compose exec backend bash -c 'bench --site crm.slimrate.com set-config redis_socketio "redis://redis-queue:6379"'

# 13. Restart all containers so changes take effect.
echo "==> Restarting all containers..."
docker-compose restart

# 14. Final status and instructions.
echo "==> ERPNext setup complete!"
docker-compose ps
echo "Access your ERPNext site at: http://<YOUR_SERVER_IP> or configure DNS for crm.slimrate.com."
echo "Check container logs with 'docker logs -f <container_name>' if needed."

exit 0
