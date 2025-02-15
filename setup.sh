#!/usr/bin/env bash
#
# setup.sh - One-click ERPNext Docker Installation
#
# Tested on Ubuntu 22.04 / 24.04
# This script will install Docker, Docker Compose, clone frappe_docker,
# create .env and docker-compose.yml, then launch ERPNext containers.

set -e  # Exit on error
set -u  # Treat unset variables as errors

# 1. Update and Install System Dependencies
echo "==> Updating apt and installing prerequisites..."
sudo apt update -y
sudo apt upgrade -y
sudo apt install -y curl git

echo "==> Installing Docker..."
if ! command -v docker &> /dev/null; then
  sudo apt install -y docker.io
  sudo systemctl enable docker
  sudo systemctl start docker
fi

echo "==> Installing Docker Compose..."
if ! command -v docker-compose &> /dev/null; then
  sudo apt install -y docker-compose
fi

# 2. Add current user to Docker group (avoids 'sudo' for Docker commands)
sudo usermod -aG docker $USER

# 3. Clone frappe_docker
echo "==> Cloning frappe_docker..."
if [ ! -d "frappe_docker" ]; then
  git clone https://github.com/frappe/frappe_docker.git
fi
cd frappe_docker

# 4. Create .env File
echo "==> Creating .env file..."
cat <<EOF > .env
# Adjust these values as needed
SITE_NAME=crm.slimrate.com
DB_PASSWORD=SuperSecureDBPassword
ADMIN_PASSWORD=SuperSecureAdminPassword

ERPNEXT_VERSION=version-14
FRAPPE_VERSION=version-14

# Redis addresses
REDIS_CACHE=redis://redis-cache:6379
REDIS_QUEUE=redis://redis-queue:6379
REDIS_SOCKETIO=redis://redis-queue:6379

SOCKETIO_PORT=9000
DB_HOST=mariadb
DB_PORT=3306
EOF

# 5. Create docker-compose.yml
echo "==> Creating docker-compose.yml..."
rm -f docker-compose.yml  # remove any old compose file
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

# 6. Launch Containers
echo "==> Launching ERPNext containers..."
docker-compose up -d --build

# 7. Print Final Instructions
echo "
==================================================
ERPNext containers are now starting in background.

Check container status:
  docker-compose ps

If all containers are healthy, open your site at:
  http://<YOUR_SERVER_IP>

Remember to set up DNS if you're using crm.slimrate.com, 
and optionally configure SSL with a reverse proxy or 
Let's Encrypt. For logs:
  docker logs -f <container_name>
==================================================
"

exit 0
