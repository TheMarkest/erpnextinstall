#!/usr/bin/env bash
#
# setup.sh - One-click Fresh ERPNext Docker Installation Script
#
# This script is intended for a fresh Ubuntu (22.04/24.04) instance.
# It installs Docker and Docker Compose, clones the ERPNext Docker repository,
# creates the necessary .env and docker-compose.yml files with correct Redis settings,
# and launches ERPNext containers.
#
# IMPORTANT:
# 1. Ensure your user is added to the 'docker' group. (This script does so.)
#    Then log out and back in (or reboot) before running docker-compose commands,
#    or run this script with sudo.
# 2. The script removes any extra Docker Compose file (like compose.yaml) to avoid conflicts.
#
# Usage:
#   wget https://raw.githubusercontent.com/YourRepo/setup-erpnext/main/setup.sh
#   chmod +x setup.sh
#   ./setup.sh
#
# (Adjust the repository URL above as needed.)
#
set -euo pipefail

# Check if running as root; if not, warn the user.
if [ "$(id -u)" -eq 0 ]; then
  echo "Warning: It is recommended to run this script as a non-root user with sudo privileges."
fi

echo "==> Updating system and installing prerequisites..."
sudo apt update -y
sudo apt upgrade -y
sudo apt install -y curl git

echo "==> Installing Docker..."
if ! command -v docker >/dev/null 2>&1; then
  sudo apt install -y docker.io
  sudo systemctl enable docker
  sudo systemctl start docker
else
  echo "Docker is already installed."
fi

echo "==> Installing Docker Compose..."
if ! command -v docker-compose >/dev/null 2>&1; then
  sudo apt install -y docker-compose
else
  echo "Docker Compose is already installed."
fi

# Add current user to docker group if not already a member.
if ! groups "$USER" | grep -q "\bdocker\b"; then
  echo "==> Adding $USER to docker group. Please log out and log in again for changes to take effect."
  sudo usermod -aG docker "$USER"
fi

# Warn the user if the Docker socket is not accessible.
if [ ! -r /var/run/docker.sock ]; then
  echo "Error: Cannot read /var/run/docker.sock. Please check Docker installation and permissions."
  exit 1
fi

echo "==> Cloning frappe_docker repository..."
if [ ! -d "frappe_docker" ]; then
  git clone https://github.com/frappe/frappe_docker.git
else
  echo "frappe_docker directory already exists, updating..."
  cd frappe_docker && git pull && cd ..
fi
cd frappe_docker

# Remove any conflicting compose file.
if [ -f "compose.yaml" ]; then
  echo "==> Removing conflicting compose.yaml file..."
  rm -f compose.yaml
fi

echo "==> Creating .env file..."
cat <<'EOF' > .env
# Site and admin settings
SITE_NAME=crm.slimrate.com
DB_PASSWORD=SuperSecureDBPassword
ADMIN_PASSWORD=SuperSecureAdminPassword

# ERPNext & Frappe versions
ERPNEXT_VERSION=version-14
FRAPPE_VERSION=version-14

# Redis settings - ensure the containers use these addresses.
REDIS_CACHE=redis://redis-cache:6379
REDIS_QUEUE=redis://redis-queue:6379
REDIS_SOCKETIO=redis://redis-queue:6379

# Other settings
SOCKETIO_PORT=9000
DB_HOST=mariadb
DB_PORT=3306
EOF

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

echo "==> Launching ERPNext containers (this may take a few minutes)..."
docker-compose up -d --build

echo "==> Setup complete!"
echo "Containers status:"
docker-compose ps
echo "
IMPORTANT:
- Verify that all containers (mariadb, redis-cache, redis-queue, backend, websocket, and frontend) are UP.
- Check logs for any issues, e.g.:
    docker logs -f frappe_docker_websocket_1
- Ensure that your DNS (crm.slimrate.com) points to this server's public IP,
  or access the site using http://<YOUR_SERVER_IP> for testing.
- If you experience Docker permission issues, re-login after adding your user to the 'docker' group.
"
exit 0
