#!/bin/bash
# setup.sh - A fresh installer for ERPNext using frappe_docker
# This script updates the system, installs Docker and Docker Compose if missing,
# clones (or updates) the frappe_docker repository, creates a clean .env file
# (ensuring no extra spaces in Redis URLs), launches the containers, and creates
# a new ERPNext site.

set -euo pipefail

# --- Configuration Variables ---
# If SITE_NAME is not already set, prompt the user:
if [ -z "${SITE_NAME:-}" ]; then
  read -p "Enter your site name (e.g., crm.example.com): " SITE_NAME
fi

# Set the MariaDB root and ERPNext admin passwords (change as needed):
MARIADB_ROOT_PASSWORD="SuperSecureDBPassword"
ADMIN_PASSWORD="SuperSecureAdminPassword"

# --- Step 1: Update system and install prerequisites ---
echo "==> Updating system and installing prerequisites..."
apt-get update && apt-get upgrade -y

# Install curl and git if missing
apt-get install -y curl git

# --- Step 2: Install Docker if not installed ---
if ! command -v docker &>/dev/null; then
  echo "==> Installing Docker..."
  apt-get install -y docker.io
else
  echo "==> Docker is already installed."
fi

# --- Step 3: Install Docker Compose if not installed ---
if ! command -v docker-compose &>/dev/null; then
  echo "==> Installing Docker Compose..."
  apt-get install -y docker-compose
else
  echo "==> Docker Compose is already installed."
fi

# --- Step 4: Clone (or update) the frappe_docker repository ---
REPO_DIR="frappe_docker"
if [ ! -d "$REPO_DIR" ]; then
  echo "==> Cloning frappe_docker repository..."
  git clone https://github.com/TheMarkest/frappe_docker.git "$REPO_DIR"
else
  echo "==> Updating frappe_docker repository..."
  cd "$REPO_DIR"
  git pull
  cd ..
fi

# --- Step 5: Remove any conflicting compose.yaml file if it exists ---
if [ -f "$REPO_DIR/compose.yaml" ]; then
  echo "==> Removing conflicting compose.yaml file..."
  rm -f "$REPO_DIR/compose.yaml"
fi

# --- Step 6: Create a clean .env file ---
echo "==> Creating .env file..."
cat > "$REPO_DIR/.env" <<EOF
# ERPNext Environment Configuration
SITE_NAME=${SITE_NAME}
REDIS_CACHE=redis://redis-cache:6379
REDIS_QUEUE=redis://redis-queue:6379
REDIS_SOCKETIO=redis://redis-queue:6379
EOF
echo "==> .env file created with:"
cat "$REPO_DIR/.env"

# --- Step 7: Create (or update) docker-compose.yml ---
# (This script assumes the repo contains a template; if not, ensure the provided
# docker-compose.yml is correct.)
echo "==> Creating docker-compose.yml..."
# (For this example, we assume the repository’s own scripts/templates handle this.)
# You could add custom generation code here if needed.

# --- Step 8: Launch ERPNext containers ---
echo "==> Launching ERPNext containers..."
cd "$REPO_DIR"
docker-compose up -d --build

# --- Step 9: Wait for containers to initialize ---
echo "==> Waiting 60 seconds for containers to initialize..."
sleep 60

# --- Step 10: Remove any existing site config inside the backend container ---
echo "==> Removing existing sites/common_site_config.json inside backend container..."
docker-compose exec backend rm -f sites/common_site_config.json || true

# (Optional: Print effective Redis configuration from the container for debugging)
echo "==> Debug: Printing effective Redis configuration inside backend container..."
docker-compose exec backend bash -c 'echo "REDIS_CACHE: $(grep ^REDIS_CACHE sites/common_site_config.json 2>/dev/null)"; echo "REDIS_QUEUE: $(grep ^REDIS_QUEUE sites/common_site_config.json 2>/dev/null)"; echo "REDIS_SOCKETIO: $(grep ^REDIS_SOCKETIO sites/common_site_config.json 2>/dev/null)"' || true

# --- Step 11: Create the new ERPNext site ---
echo "==> Creating new ERPNext site ${SITE_NAME}..."
docker-compose exec backend bench new-site ${SITE_NAME} --mariadb-root-password "${MARIADB_ROOT_PASSWORD}" --admin-password "${ADMIN_PASSWORD}"

echo "==> Setup complete! Access your ERPNext site at http://<your_server_ip>"
