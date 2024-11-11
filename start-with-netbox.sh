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
export MEERKAT_PORT="8888"

# Attempt to fetch the IPv4 address of the interface with the default gateway
LAN_IP=$(ip -4 route get 1.1.1.1 | grep -oP 'src \K\S+')

# Check if the IP was retrieved successfully
if [ -z "$LAN_IP" ]; then
  echo "Error: Unable to determine local IPv4 address."
  exit 1
fi

check_port_in_use $NETBOX_PORT
check_port_in_use $ICINGA_PORT
check_port_in_use $MEERKAT_PORT

export LAN_IP=$LAN_IP

echo "NetBox will be deployed at: http://$LAN_IP:$NETBOX_PORT"
echo "Icinga will be deployed at: http://$LAN_IP:$ICINGA_PORT"
echo "Meerkat will be deployed at: https://$LAN_IP:$MEERKAT_PORT"


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
echo "--- Writing configuration ---"
echo

# Check if secrets_sql.env exists; if not, create it
if [ ! -f secrets_sql.env ]; then
  # Generate random passwords for MYSQL_ROOT_PASSWORD and DEFAULT_MYSQL_PASS
  MYSQL_ROOT_PASSWORD=$(openssl rand -base64 16| tr -d /=+ | cut -c -30)
  DEFAULT_MYSQL_PASS=$(openssl rand -base64 16| tr -d /=+ | cut -c -30)

  # Write the environment variables to secrets_sql.env
  {
    echo "MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}"
    echo "DEFAULT_MYSQL_PASS=${DEFAULT_MYSQL_PASS}"
    echo "NETBOX_URL=http://${LAN_IP}:${NETBOX_PORT}"
    echo "NETBOX_APIKEY=1234567890"
    echo "MEERKAT_PORT=${MEERKAT_PORT}"
  } >> secrets_sql.env

  echo "secrets_sql.env created with generated passwords."
else
  echo "secrets_sql.env already exists. Skipping creation."
fi

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

# ASCII art emojis for spinner
spinner=("(^_^)" "(^o^)" "(^_^;)" "(>_<)" "(^_^)b" "(T_T)")

# Reset elapsed time
elapsed=0

# Loop to check if the webpage is available
while ! curl --output /dev/null --silent --head --fail "$URL"; do
  # Update the spinner with ASCII art
  i=$((elapsed % ${#spinner[@]}))
  printf "\rChecking... ${spinner[$i]} "
  
  # Sleep for 1 second
  sleep 1
  elapsed=$((elapsed + 1))

  # Check if the timeout has been reached
  if [ "$elapsed" -ge "$TIMEOUT" ]; then
    echo -e "\n(╯°□°)╯︵ ┻━┻ Timeout after waiting $TIMEOUT seconds for $URL"
    exit 1
  fi
done

echo "Icinga is available at http://${LAN_IP}:${ICINGA_PORT}"
echo "username: icingaadmin"
echo "password: icinga"

echo "Meerkat is available at https://${LAN_IP}:${MEERKAT_PORT}"

echo "you can now access netbox here: http://${LAN_IP}:${NETBOX_PORT}"
echo "username: admin"
echo "password: admin"



