#!/bin/bash

check_port_in_use() {
  local port=$1
  if ss -tuln | grep ":$port "; then
    echo "Error: Port $port is already in use. Please modify the defaults in this script, or fix conflict"
    exit 1
  fi
}

export NETBOX_PORT="8001"
export ICINGA_PORT="8002"

# Attempt to fetch the IPv4 address of the interface with the default gateway
LAN_IP=$(ip -4 route get 1.1.1.1 | grep -oP 'src \K\S+')

# Check if the IP was retrieved successfully
if [ -z "$LAN_IP" ]; then
  echo "Error: Unable to determine local IPv4 address."
  exit 1
fi

check_port_in_use $NETBOX_PORT
check_port_in_use $ICINGA_PORT

echo "NetBox will be deployed at: http://$LAN_IP:$NETBOX_PORT"
echo "Icinga will be deployed at: http://$LAN_IP:$ICINGA_PORT"
export LAN_IP=$LAN_IP


# Check if all required environment variables are set
REQUIRED_VARS=("LAN_IP" "NETBOX_PORT")

for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var:-}" ]; then
    echo "Error: Required environment variable '$var' is not set."
    exit 0
  fi
done

echo
echo "--- Cloning NetBox Docker ---"
echo

# Clone netbox-docker
git clone --branch 3.0.2 https://github.com/netbox-community/netbox-docker.git
pushd netbox-docker

echo
echo "--- Generating configuration files ---"
echo

# Create plugin files
cat <<EOF > plugin_requirements.txt
slurpit_netbox
EOF

cat <<EOF > Dockerfile-Plugins
FROM netboxcommunity/netbox:v4.1-3.0.2

COPY ./plugin_requirements.txt /opt/netbox/
RUN /opt/netbox/venv/bin/pip install  --no-warn-script-location -r /opt/netbox/plugin_requirements.txt
EOF


cat <<EOF > docker-compose.override.yml
services:
  netbox:
    image: netbox:v4.1-3.0.2-plugins
    pull_policy: never
    ports:
      - "${NETBOX_PORT}:8080"
    build:
      context: .
      dockerfile: Dockerfile-Plugins
    environment:
      SKIP_SUPERUSER: "false"
      SUPERUSER_API_TOKEN: "1234567890"
      SUPERUSER_EMAIL: ""
      SUPERUSER_NAME: "admin"
      SUPERUSER_PASSWORD: "admin"
    healthcheck:
      test: curl -f http://${LAN_IP}:${NETBOX_PORT}/login/ || exit 1
      start_period: 360s
      timeout: 3s
      interval: 15s
  netbox-worker:
    image: netbox:v4.1-3.0.2-plugins
    pull_policy: never
  netbox-housekeeping:
    image: netbox:v4.1-3.0.2-plugins
    pull_policy: never
EOF

# Update the healthcheck in docker-compose.yml
sed -i 's|http://localhost:8080/login/|http://${LAN_IP}:${NETBOX_PORT}/login/|' docker-compose.yml

echo
echo "--- Building NetBox ---"
echo

docker compose build --no-cache

echo
echo "--- Starting NetBox Docker ---"
echo

docker compose up -d

popd



# Check if all required environment variables are set
REQUIRED_VARS=("LAN_IP" "ICINGA_PORT" "NETBOX_PORT" )

for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var:-}" ]; then
    echo "Error: Required environment variable '$var' is not set."
    exit 0
  fi
done

echo
echo "--- Cloning Icinga2 ---"
echo

git clone -b master https://github.com/davekempe/icinga2-docker-stack/
pushd icinga2-docker-stack

echo
echo "--- Writing configuration ---"
echo

echo "MYSQL_ROOT_PASSWORD=12345678" > secrets_sql.env
echo "NETBOX_URL=http://${LAN_IP}:${NETBOX_PORT}/api" >> secrets_sql.env
echo "NETBOX_APIKEY=1234567890" >> secrets_sql.env

# Remove SSL/TLS
sed -i '/4443:443/d' docker-compose.yml

# Update the outside port
sed -i 's/8080:80/${ICINGA_PORT}:80/' docker-compose.yml

# Uncomment the credentials
sed -i 's/^ *#- ICINGAWEB2_ADMIN_USER=icingaadmin/      - ICINGAWEB2_ADMIN_USER=icingaadmin/' docker-compose.yml
sed -i 's/^ *#- ICINGAWEB2_ADMIN_PASS=icinga/      - ICINGAWEB2_ADMIN_PASS=icinga/' docker-compose.yml

echo
echo "--- Starting Icinga2 ---"
echo

docker compose up -d

echo
echo "--- Waiting for Icinga2 to start ---"
echo

# Variables
URL="http://${LAN_IP}:${ICINGA_PORT}"
TIMEOUT=60  # Timeout in seconds

# Counter for time elapsed
elapsed=0

# Loop to check if the webpage is available
while ! curl --output /dev/null --silent --head --fail "$URL"; do
  # Sleep for 1 second
  sleep 1
  elapsed=$((elapsed + 1))
  echo "${elapsed}"

  # Check if the timeout has been reached
  if [ "$elapsed" -ge "$TIMEOUT" ]; then
    echo "Timeout after waiting $TIMEOUT seconds for $URL"
    exit 1
  fi
done

popd
echo "Icinga is available at http://${LAN_IP}:${ICINGA_PORT}"
echo "username: icingaadmin"
echo "password: icinga"


echo "you can now access netbox here: http://${LAN_IP}:${NETBOX_PORT}"
echo "username: admin"
echo "password: admin"



