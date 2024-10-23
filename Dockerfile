# Dockerfile for icinga2 with icingaweb2
# https://github.com/jjethwa/icinga2

FROM debian:bookworm

ENV APACHE2_HTTP=REDIRECT \
    ICINGA2_FEATURE_GRAPHITE=false \
    ICINGA2_FEATURE_GRAPHITE_HOST=graphite \
    ICINGA2_FEATURE_GRAPHITE_PORT=2003 \
    ICINGA2_FEATURE_GRAPHITE_URL=http://graphite \
    ICINGA2_FEATURE_GRAPHITE_SEND_THRESHOLDS="true" \
    ICINGA2_FEATURE_GRAPHITE_SEND_METADATA="false" \
    ICINGA2_USER_FULLNAME="Icinga2" \
    ICINGA2_FEATURE_DIRECTOR="true" \
    ICINGA2_FEATURE_DIRECTOR_KICKSTART="true" \
    ICINGA2_FEATURE_DIRECTOR_USER="icinga2-director" \
    ICINGA2_LOG_LEVEL="information" \
    MYSQL_ROOT_USER=root

RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
    apache2 \
    apt-transport-https \
    bc \
    ca-certificates \
    curl \
    dnsutils \
    file \
    gnupg \
    jq \
    libdbd-mysql-perl \
    libdigest-hmac-perl \
    libnet-snmp-perl \
    locales \
    logrotate \
    lsb-release \
    bsd-mailx \
    mariadb-client \
    mariadb-server \
    netbase \
    openssh-client \
    openssl \
    php-curl \
    php-ldap \
    php-mysql \
    php-mbstring \
    php-gmp \
    procps \
    pwgen \
    python3 \
    python3-requests \
    python3-pynetbox \
    snmp \
    msmtp \
    sudo \
    supervisor \
    telnet \
    unzip \
    wget \
    cron \
    && apt-get -y --purge remove exim4 exim4-base exim4-config exim4-daemon-light \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN export DEBIAN_FRONTEND=noninteractive \
    && curl -s https://packages.icinga.com/icinga.key \
    | apt-key add - \
    && echo "deb https://packages.icinga.com/debian icinga-$(lsb_release -cs) main" > /etc/apt/sources.list.d/$(lsb_release -cs)-icinga.list \
    && echo "deb-src https://packages.icinga.com/debian icinga-$(lsb_release -cs) main" >> /etc/apt/sources.list.d/$(lsb_release -cs)-icinga.list \
    && echo "deb http://deb.debian.org/debian $(lsb_release -cs)-backports main" > /etc/apt/sources.list.d/$(lsb_release -cs)-backports.list \
    && apt-get update \
    && apt-get install -y --install-recommends \
    icinga2 \
    icingacli \
    icingaweb2 \
    monitoring-plugins \
    nagios-nrpe-plugin \
    nagios-plugins-contrib \
    nagios-snmp-plugins \
    libmonitoring-plugin-perl \
    icinga-director \
    icinga-graphite \
    icingadb \
    icingadb-web \
    icingadb-redis\
    python3-loguru\
    python3-requests\
    python3-jinja2\
    python3-rt\
    git\
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /usr/share/icingaweb2/modules/ \
    # Module Netbox
    && mkdir -p /usr/share/icingaweb2/modules/netbox/ \
    && wget -q --no-cookies -O - "https://github.com/sol1/icingaweb2-module-netbox/archive/refs/tags/v4.0.8.1.tar.gz" \
    | tar xz --strip-components=1 --directory=/usr/share/icingaweb2/modules/netbox -f - \
    && true

# meerkat
RUN mkdir -p /opt/sol1/meerkat/dl \
    # Module Netbox
    && RELEASE_URL=`curl https://api.github.com/repos/meerkat-dashboard/meerkat/releases/latest | jq -r '.assets[0].browser_download_url' || true`\
    && INSTALL_DIR=/opt/sol1/meerkat\
    && USER=meerkat\
    && curl -sL $RELEASE_URL | tar xz -C "$INSTALL_DIR/dl"\
    && useradd -d "$INSTALL_DIR" -s /usr/sbin/nologin $USER \
    && mkdir -p "$INSTALL_DIR/dashboards" \
    && mkdir -p "$INSTALL_DIR/dashboards-background" \
    && mkdir -p "$INSTALL_DIR/dashboards-sound" \
    && mkdir -p "$INSTALL_DIR/log" \
    && cp $INSTALL_DIR/dl/meerkat/meerkat $INSTALL_DIR/meerkat \
    && chmod +x $INSTALL_DIR/meerkat \
    && cp $INSTALL_DIR/dl/meerkat/contrib/meerkat.toml.example $INSTALL_DIR/meerkat.toml \
    && sed -i "s|^HTTPAddr = \"0.0.0.0:8080\"|HTTPAddr = \"0.0.0.0:8888\"|g; s|^#IcingaInsecureTLS = true|IcingaInsecureTLS = true|g" $INSTALL_DIR/meerkat.toml \
    && "$INSTALL_DIR/dl/meerkat/contrib/generate-ssl.sh" "meerkat" "$INSTALL_DIR/ssl" $INSTALL_DIR/meerkat.toml \
    && chown -R $USER "$INSTALL_DIR"\
    && true




RUN mkdir -p /opt/sol1/notifications/ \
    # Sol1 enhanced notification scripts
    && cd /opt/sol1/notifications/ \
    && git clone https://github.com/sol1/sol1-icinga-notifications.git .\
    && ./deploy.sh --all\
    && true


ADD content/ /
RUN chmod +x /usr/local/bin/ini_set \
    && echo "ini_set script permissions:" \
    && ls -l /usr/local/bin/ini_set

# Final fixes
RUN true \
    && sed -i 's/vars\.os.*/vars.os = "Docker"/' /etc/icinga2/conf.d/hosts.conf \
    && mv /etc/icingaweb2/ /etc/icingaweb2.dist \
    && mv /etc/icinga2/ /etc/icinga2.dist \
    && mkdir -p /etc/icinga2 \
    && usermod -aG icingaweb2 www-data \
    && usermod -aG nagios www-data \
    && usermod -aG icingaweb2 nagios \
    && mkdir -p /var/log/icinga2 \
    && chmod 755 /var/log/icinga2 \
    && chown nagios:nagios /var/log/icinga2 \
    && mkdir -p /var/cache/icinga2 \
    && chmod 755 /var/cache/icinga2 \
    && chown nagios:nagios /var/cache/icinga2 \
    && touch /var/log/cron.log \
    && rm -rf \
    /var/lib/mysql/* \
    && chmod u+s,g+s \
    /bin/ping \
    /bin/ping6 \
    /usr/lib/nagios/plugins/check_icmp \
    && /sbin/setcap cap_net_raw+p /bin/ping

EXPOSE 80 443 5665 8888

# Initialize and run Supervisor
ENTRYPOINT ["/opt/run"]
