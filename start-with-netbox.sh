#!/bin/bash
#
# Quick POC launcher for the Icinga2 stack (+ optional NetBox).
#
# Usage:
#   ./start-with-netbox.sh
#       Spin up a fresh NetBox (netbox-docker) AND the Icinga2 stack, wired together.
#
#   ./start-with-netbox.sh --external-netbox <URL> <TOKEN>
#       Skip deploying NetBox and point Icinga2 at an existing NetBox instance.
#       <URL>   e.g. https://netbox.example.com   (no trailing /api)
#       <TOKEN> a NetBox API token. NetBox 4.5+ "v2" tokens look like
#               nbt_<key>.<secret> and are sent as a Bearer token automatically;
#               legacy "v1" tokens are sent as a Token header.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
export NETBOX_PORT="8001"
export ICINGA_PORT="8002"
export MEERKAT_PORT="8888"

# Pinned versions (bump these to refresh the POC).
NETBOX_DOCKER_REF="5.0.1"                       # netbox-docker release tag
NETBOX_IMAGE="docker.io/netboxcommunity/netbox:v4.6-5.0.1"

# Fixed demo credentials for the bundled NetBox. NetBox 4.6 uses v2 API tokens:
#   key    = exactly 12 alphanumeric chars (no nbt_ prefix here)
#   secret = 40 alphanumeric chars
# Clients authenticate with the full token string: nbt_<key>.<secret>
NETBOX_SUPERUSER="admin"
NETBOX_SUPERUSER_PASSWORD="admin"
NETBOX_API_KEY="icingademo01"
NETBOX_API_SECRET="icinganetboxdemotoken1234567890abcdefghi"
NETBOX_V2_TOKEN="nbt_${NETBOX_API_KEY}.${NETBOX_API_SECRET}"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
EXTERNAL_NETBOX=false
EXTERNAL_NETBOX_URL=""
EXTERNAL_NETBOX_TOKEN=""

usage() {
  cat <<'USAGE'
Quick POC launcher for the Icinga2 stack (+ optional NetBox).

Usage:
  ./start-with-netbox.sh
      Spin up a fresh NetBox (netbox-docker) AND the Icinga2 stack, wired together.

  ./start-with-netbox.sh --external-netbox <URL> <TOKEN>
      Skip deploying NetBox and point Icinga2 at an existing NetBox instance.
      <URL>   e.g. https://netbox.example.com   (no trailing /api)
      <TOKEN> a NetBox API token. NetBox 4.5+ "v2" tokens look like
              nbt_<key>.<secret> and are sent as a Bearer token automatically;
              legacy "v1" tokens are sent as a Token header.
USAGE
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --external-netbox)
      EXTERNAL_NETBOX=true
      EXTERNAL_NETBOX_URL="${2:-}"
      EXTERNAL_NETBOX_TOKEN="${3:-}"
      if [[ -z "$EXTERNAL_NETBOX_URL" || -z "$EXTERNAL_NETBOX_TOKEN" ]]; then
        echo "Error: --external-netbox requires <URL> and <TOKEN>."
        usage 1
      fi
      shift 3
      ;;
    -h|--help)
      usage 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage 1
      ;;
  esac
done

check_port_in_use() {
  local port=$1
  if ss -tuln | grep -q ":$port "; then
    echo "Error: Port $port is already in use. Please modify the defaults in this script, or fix conflict"
    exit 1
  fi
}

# Ensure Docker (with the compose plugin) and a couple of basic tools are present.
# On Debian/Ubuntu we install Docker CE from the upstream get.docker.com script.
ensure_docker() {
  # Basic tools used by this script and the Docker installer.
  if ! command -v curl >/dev/null 2>&1 || ! command -v ss >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      echo "--- Installing prerequisites (curl, iproute2, ca-certificates) ---"
      apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates iproute2 >/dev/null
    fi
  fi

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return 0
  fi

  echo
  echo "--- Docker (or the compose plugin) not found; installing from upstream ---"
  echo

  if [ "$(id -u)" -ne 0 ]; then
    echo "Error: Docker is not installed and this script is not running as root."
    echo "Re-run as root, or install Docker manually: https://docs.docker.com/engine/install/ubuntu/"
    exit 1
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    echo "Error: automatic Docker install only supported on Debian/Ubuntu."
    echo "Install Docker + the compose plugin manually: https://docs.docker.com/engine/install/"
    exit 1
  fi

  # Official Docker convenience script (installs docker-ce + compose plugin).
  curl -fsSL https://get.docker.com | sh

  # Make sure the daemon is up.
  systemctl enable --now docker >/dev/null 2>&1 || service docker start || true

  if ! docker compose version >/dev/null 2>&1; then
    echo "Error: Docker installation did not provide a working 'docker compose'."
    exit 1
  fi
  echo "Docker installed: $(docker --version)"
}

ensure_docker

# Attempt to fetch the IPv4 address of the interface with the default gateway
LAN_IP=$(ip -4 route get 1.1.1.1 | grep -oP 'src \K\S+')

# Check if the IP was retrieved successfully
if [ -z "$LAN_IP" ]; then
  echo "Error: Unable to determine local IPv4 address."
  exit 1
fi
export LAN_IP=$LAN_IP

check_port_in_use "$ICINGA_PORT"
check_port_in_use "$MEERKAT_PORT"
if ! $EXTERNAL_NETBOX; then
  check_port_in_use "$NETBOX_PORT"
fi

# ---------------------------------------------------------------------------
# Determine the NetBox URL + token that Icinga should use
# ---------------------------------------------------------------------------
if $EXTERNAL_NETBOX; then
  NETBOX_URL="${EXTERNAL_NETBOX_URL%/}"
  NETBOX_APIKEY="$EXTERNAL_NETBOX_TOKEN"
  echo "Using external NetBox at: $NETBOX_URL"
else
  NETBOX_URL="http://${LAN_IP}:${NETBOX_PORT}"
  NETBOX_APIKEY="$NETBOX_V2_TOKEN"
  echo "NetBox will be deployed at: $NETBOX_URL"
fi
echo "Icinga will be deployed at:  http://${LAN_IP}:${ICINGA_PORT}"
echo "Meerkat will be deployed at: https://${LAN_IP}:${MEERKAT_PORT}"
echo

# ---------------------------------------------------------------------------
# Deploy NetBox (unless using an external one)
# ---------------------------------------------------------------------------
if ! $EXTERNAL_NETBOX; then
  echo "--- Cloning NetBox Docker (${NETBOX_DOCKER_REF}) ---"
  echo

  if [ ! -d netbox-docker ]; then
    git clone --branch "${NETBOX_DOCKER_REF}" https://github.com/netbox-community/netbox-docker.git
  else
    echo "netbox-docker already cloned, reusing it."
  fi
  pushd netbox-docker > /dev/null

  echo
  echo "--- Generating configuration files ---"
  echo

  # Publish NetBox on NETBOX_PORT and seed a fixed superuser + v2 API token.
  # netbox-docker 5.x mints a v2 token when SUPERUSER_API_KEY + SUPERUSER_API_TOKEN
  # are both set (API_TOKEN_PEPPER_1 is provided by the stock env/netbox.env).
  cat <<EOF > docker-compose.override.yml
services:
  netbox:
    image: ${NETBOX_IMAGE}
    ports:
      - "${NETBOX_PORT}:8080"
    environment:
      SKIP_SUPERUSER: "false"
      SUPERUSER_NAME: "${NETBOX_SUPERUSER}"
      SUPERUSER_EMAIL: "admin@example.com"
      SUPERUSER_PASSWORD: "${NETBOX_SUPERUSER_PASSWORD}"
      SUPERUSER_API_KEY: "${NETBOX_API_KEY}"
      SUPERUSER_API_TOKEN: "${NETBOX_API_SECRET}"
  netbox-worker:
    image: ${NETBOX_IMAGE}
EOF

  echo
  echo "--- Starting NetBox Docker ---"
  echo

  docker compose up -d

  popd > /dev/null
fi

# ---------------------------------------------------------------------------
# Write Icinga secrets / environment
# ---------------------------------------------------------------------------
echo
echo "--- Writing configuration ---"
echo

# Create secrets_sql.env if it doesn't exist (it is gitignored).
if [ ! -f secrets_sql.env ]; then
  MYSQL_ROOT_PASSWORD=$(openssl rand -base64 16 | tr -d /=+ | cut -c -30)
  DEFAULT_MYSQL_PASS=$(openssl rand -base64 16 | tr -d /=+ | cut -c -30)

  {
    echo "MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}"
    echo "DEFAULT_MYSQL_PASS=${DEFAULT_MYSQL_PASS}"
    echo "NETBOX_URL=${NETBOX_URL}"
    echo "NETBOX_APIKEY=${NETBOX_APIKEY}"
    echo "MEERKAT_PORT=${MEERKAT_PORT}"
    # Optional outbound mail. Leave GMAIL_SMTP_PASSWORD empty to disable.
    echo "NOTIFICATION_FROM_ADDRESS=icinga@example.com"
    echo "GMAIL_SMTP_PASSWORD="
  } > secrets_sql.env

  echo "secrets_sql.env created with generated passwords."
else
  echo "secrets_sql.env already exists; updating NetBox settings in place."
  # Keep NetBox URL/token in sync with this run without clobbering other values.
  sed -i "/^NETBOX_URL=/d;/^NETBOX_APIKEY=/d" secrets_sql.env
  echo "NETBOX_URL=${NETBOX_URL}" >> secrets_sql.env
  echo "NETBOX_APIKEY=${NETBOX_APIKEY}" >> secrets_sql.env
  grep -q "^MEERKAT_PORT=" secrets_sql.env || echo "MEERKAT_PORT=${MEERKAT_PORT}" >> secrets_sql.env
fi

echo
echo "--- Building and starting Icinga2 ---"
echo

docker compose up -d --build

echo
echo "--- Waiting for Icinga2 to start ---"
echo

URL="http://${LAN_IP}:${ICINGA_PORT}"
TIMEOUT=120  # seconds

spinner=("(^_^)" "(^o^)" "(^_^;)" "(>_<)" "(^_^)b" "(T_T)")
elapsed=0
while ! curl --output /dev/null --silent --head --fail "$URL"; do
  i=$((elapsed % ${#spinner[@]}))
  printf "\rChecking... ${spinner[$i]} "
  sleep 1
  elapsed=$((elapsed + 1))
  if [ "$elapsed" -ge "$TIMEOUT" ]; then
    echo -e "\n(╯°□°)╯︵ ┻━┻ Timeout after waiting $TIMEOUT seconds for $URL"
    exit 1
  fi
done

echo
echo "================================================================"
echo "Icinga is available at http://${LAN_IP}:${ICINGA_PORT}"
echo "  username: icingaadmin"
echo "  password: icinga"
echo
echo "Meerkat is available at https://${LAN_IP}:${MEERKAT_PORT}"
echo
if $EXTERNAL_NETBOX; then
  echo "Using external NetBox at ${NETBOX_URL}"
else
  echo "NetBox is available at ${NETBOX_URL}"
  echo "  username: ${NETBOX_SUPERUSER}"
  echo "  password: ${NETBOX_SUPERUSER_PASSWORD}"
  echo "  API token (v2): ${NETBOX_V2_TOKEN}"
fi
echo "================================================================"
