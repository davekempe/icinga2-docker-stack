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
    icinga-notifications \
    icinga-notifications-web \
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

EXPOSE 80 443 5665

# Initialize and run Supervisor
ENTRYPOINT ["/opt/run"]
