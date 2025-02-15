#!/usr/bin/env bash
# install.sh - One-Click Clean ERPNext Docker Setup on Ubuntu
# WARNING: This script removes any existing ERPNext data and volumes!
# It will install Docker, Docker Compose, clone frappe_docker,
# set up environment and docker-compose files, launch containers,
# and update (or create) the ERPNext site with the correct Redis settings.
#
# Usage:
#   wget https://raw.githubusercontent.com/TheMarkest/erpnextinstall/refs/heads/main/setup.sh
#   chmod +x setup.sh
#   ./setup.sh
#
set -euo pipefail

# --- Step 1. Update System and Install Prerequisites ---
echo "==> Updating system and installing prerequisites..."
sudo apt update -y && sudo apt upgrade -y
sudo apt install -y curl git

# --- Step 2. Install Docker and Docker Compose ---
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

# --- Step 3. Add current user to docker group (if not already) ---
if ! groups "$USER" | grep -qw docker; then
  echo "==> Adding $USER to docker group. Please log out and log in again for changes to take effect."
  sudo usermod -aG docker "$USER"
fi

# --- Step 4. Clone the frappe_docker Repository ---
echo "==> Cloning frappe_docker repository..."
if [ ! -d "frappe_docker" ]; then
  git clone https://github.com/frappe/frappe_docker.git
else
  echo "frappe_docker directory already exists, updating..."
  cd frappe_docker && git pull && cd ..
fi
cd frappe_docker

# --- Step 5. Remove any conflicting Docker Compose file (e.g. compose.yaml) ---
echo "==> Removing conflicting compose.yaml file if exists..."
rm -f compose.yaml

# --- Step 6. Create .env File ---
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

# --- Step 7. Create docker-compose.yml File ---
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

# --- Step 8. Launch ERPNext Containers ---
echo "==> Launching ERPNext containers..."
docker-compose up -d --build

echo "==> Waiting 60 seconds for containers to initialize..."
sleep 60

# --- Step 9. Check if the site already exists and update or create accordingly ---
echo "==> Checking if site 'crm.slimrate.com' exists..."
if docker-compose exec backend bench --site crm.slimrate.com version >/dev/null 2>&1; then
    echo "Site exists. Updating site configuration with correct Redis settings..."
    docker-compose exec backend bash -c 'bench --site crm.slimrate.com set-config redis_cache "redis://redis-cache:6379"'
    docker-compose exec backend bash -c 'bench --site crm.slimrate.com set-config redis_queue "redis://redis-queue:6379"'
    docker-compose exec backend bash -c 'bench --site crm.slimrate.com set-config redis_socketio "redis://redis-queue:6379"'
else
    echo "Site does not exist. Creating new site..."
    docker-compose exec backend bash -c 'export REDIS_CACHE="redis://redis-cache:6379"; export REDIS_QUEUE="redis://redis-queue:6379"; export REDIS_SOCKETIO="redis://redis-queue:6379"; bench new-site crm.slimrate.com --mariadb-root-password "$DB_PASSWORD" --admin-password "$ADMIN_PASSWORD"'
fi

# --- Step 10. Restart All Containers ---
echo "==> Restarting all containers..."
docker-compose restart

# --- Step 11. Final Status ---
echo "==> ERPNext setup complete!"
docker-compose ps
echo "Access your ERPNext site at: http://<YOUR_SERVER_IP> or configure DNS for crm.slimrate.com."
echo "If you encounter any issues, check container logs with:"
echo "   docker logs -f frappe_docker_websocket_1"
exit 0
