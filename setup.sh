#!/bin/bash
# ultimate_setup.sh – Ultimate ERPNext Docker Setup Script with Advanced Debug Output
#
# This script will:
#   1. Update the system and install prerequisites (curl, git).
#   2. Install Docker and Docker Compose if not already installed.
#   3. Add the current user (root) to the docker group.
#   4. Clone (or update) the official ERPNext Docker repository.
#   5. Remove any conflicting compose file.
#   6. Generate a complete .env file with all required ERPNext configuration.
#   7. Launch the ERPNext containers via docker-compose and wait for initialization.
#   8. Remove any previous site configuration from the backend container.
#   9. Print out the effective Redis configuration inside the backend container for debugging.
#  10. Create the new ERPNext site using bench new-site.
#
# Usage:
#   Save as ultimate_setup.sh, then run:
#     chmod +x ultimate_setup.sh
#     sudo ./ultimate_setup.sh
#
# Note: Adjust repository URLs and default variable values as needed.

set -euo pipefail

# Optional debug output (uncomment next line to enable)
# set -x

# --- Logging functions ---
log()   { echo "==> $1"; }
error() { echo "ERROR: $1" >&2; }

# --- Verify script is running as root ---
if [ "$(id -u)" -ne 0 ]; then
  error "This script must be run as root."
  exit 1
fi

# --- Step 1: Prompt for Configuration Values ---
read -p "Enter your ERPNext site name (e.g., crm.example.com): " SITE_NAME
read -sp "Enter MariaDB root password (for bench new-site): " DB_ROOT_PASSWORD; echo
read -sp "Enter ERPNext admin password: " ADMIN_PASSWORD; echo
read -p "Enter ERPNext version (default: version-14): " ERPNEXT_VERSION
ERPNEXT_VERSION=${ERPNEXT_VERSION:-version-14}

# Use the same DB password for bench if needed
DB_PASSWORD="${DB_ROOT_PASSWORD}"

# Fixed configuration values (modify as necessary)
DB_HOST="mariadb"
DB_PORT="3306"
SOCKETIO_PORT="9000"

# Ensure these Redis URLs are correct and without extra spaces:
REDIS_CACHE="redis://redis-cache:6379"
REDIS_QUEUE="redis://redis-queue:6379"
REDIS_SOCKETIO="redis://redis-queue:6379"

# --- Step 2: Print Effective Configuration (excluding passwords) ---
log "Effective configuration:"
echo "  SITE_NAME       : ${SITE_NAME}"
echo "  ERPNEXT_VERSION : ${ERPNEXT_VERSION}"
echo "  DB_HOST         : ${DB_HOST}"
echo "  DB_PORT         : ${DB_PORT}"
echo "  SOCKETIO_PORT   : ${SOCKETIO_PORT}"
echo "  REDIS_CACHE     : ${REDIS_CACHE}"
echo "  REDIS_QUEUE     : ${REDIS_QUEUE}"
echo "  REDIS_SOCKETIO  : ${REDIS_SOCKETIO}"

# --- Step 3: Update System and Install Prerequisites ---
log "Updating system packages..."
apt-get update && apt-get upgrade -y

log "Installing prerequisites: curl and git..."
apt-get install -y curl git

# --- Step 4: Install Docker if Not Present ---
if ! command -v docker &>/dev/null; then
  log "Installing Docker..."
  apt-get install -y docker.io
else
  log "Docker is already installed."
fi

# --- Step 5: Install Docker Compose if Not Present ---
if ! command -v docker-compose &>/dev/null; then
  log "Installing Docker Compose..."
  apt-get install -y docker-compose
else
  log "Docker Compose is already installed."
fi

# --- Step 6: Add Current User (root) to the docker Group (if not already) ---
if ! groups root | grep -qw "docker"; then
  log "Adding root to the docker group..."
  usermod -aG docker root
  log "Group change applied. Please log out and log in again if needed."
else
  log "Root is already in the docker group."
fi

# --- Step 7: Clone or Update the ERPNext Docker Repository ---
# Use the official ERPNext Docker repository URL:
REPO_DIR="/home/ubuntu/frappe_docker"
OFFICIAL_REPO="https://github.com/frappe/frappe_docker.git"

if [ ! -d "${REPO_DIR}" ]; then
  log "Cloning the official ERPNext Docker repository..."
  git clone "${OFFICIAL_REPO}" "${REPO_DIR}"
else
  log "Updating the ERPNext Docker repository..."
  cd "${REPO_DIR}"
  git pull
  cd /home/ubuntu
fi

# --- Step 8: Remove Conflicting Compose File (if exists) ---
if [ -f "${REPO_DIR}/compose.yaml" ]; then
  log "Removing conflicting compose.yaml file..."
  rm -f "${REPO_DIR}/compose.yaml"
fi

# --- Step 9: Create the .env File ---
log "Creating .env file in ${REPO_DIR}..."
cat > "${REPO_DIR}/.env" <<EOF
# ERPNext Environment Configuration
SITE_NAME=${SITE_NAME}
DB_PASSWORD=${DB_PASSWORD}
ERPNEXT_VERSION=${ERPNEXT_VERSION}
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
SOCKETIO_PORT=${SOCKETIO_PORT}
REDIS_CACHE=${REDIS_CACHE}
REDIS_QUEUE=${REDIS_QUEUE}
REDIS_SOCKETIO=${REDIS_SOCKETIO}
EOF

log "Generated .env file content:"
cat "${REPO_DIR}/.env"

# --- Step 10: Verify docker-compose.yml Exists ---
if [ ! -f "${REPO_DIR}/docker-compose.yml" ]; then
  error "docker-compose.yml not found in ${REPO_DIR}. Exiting."
  exit 1
fi

# --- Step 11: Launch ERPNext Containers ---
log "Launching ERPNext containers..."
cd "${REPO_DIR}"
docker-compose up -d --build

# --- Step 12: Wait for Containers to Initialize ---
log "Waiting 60 seconds for containers to initialize..."
sleep 60

# --- Step 13: Remove Existing Site Config File from Backend Container ---
log "Removing any existing sites/common_site_config.json from the backend container..."
docker-compose exec backend rm -f sites/common_site_config.json || true

# --- Step 14: Advanced Debug Output – Print Redis Settings in Backend Container ---
log "Debug: Printing effective Redis configuration inside the backend container..."
docker-compose exec backend bash -c '
  echo "Effective Redis configuration (from sites/common_site_config.json if available):"
  if [ -f sites/common_site_config.json ]; then
    grep -E "redis_cache|redis_queue|redis_socketio" sites/common_site_config.json || echo "Not found"
  else
    echo "sites/common_site_config.json does not exist yet."
  fi
'

# --- Step 15: Create New ERPNext Site ---
log "Creating new ERPNext site '${SITE_NAME}'..."
docker-compose exec backend bench new-site "${SITE_NAME}" \
  --mariadb-root-password "${DB_ROOT_PASSWORD}" \
  --admin-password "${ADMIN_PASSWORD}"

log "ERPNext site '${SITE_NAME}' created successfully!"
log "Setup complete. You can now access your ERPNext site at http://<your_server_public_IP>"
