#!/bin/bash

# Get the expiry date in OpenSSL's date format
EXP_DATE=$(openssl x509 -noout -enddate -in /var/lib/openvpn-server/openssl/ca.crt | grep -oP "=.*" | tr -d =)
EXP_DATE=( $EXP_DATE )

# Extract the bits we need
EXP_DAY=${EXP_DATE[1]}
EXP_MONTH=${EXP_DATE[0]}
EXP_YEAR=${EXP_DATE[3]}

# Convert it to seconds
EXP_DATE_SHORT=$(echo "$EXP_DAY $EXP_MONTH $EXP_YEAR")
EXP_DATE_SECONDS=$(date -d "$EXP_DATE_SHORT" +%s)

# Current date
CURR_DATE=$(date +%s)

# Calculate the difference and convert to days
DIFF=$((($EXP_DATE_SECONDS - $CURR_DATE) / 86400))

if (( $DIFF > 30 )); then
        STATUS="OpenVPN master SSL certificate OK, days until expiry is $DIFF"
        EXIT=0
elif (( $DIFF > 7 )); then
        STATUS="Warning - $DIFF days until OpenVPN master SSL certificate expires"
        EXIT=1
else
        STATUS="Critical - $DIFF days until OpenVPN master SSL certificate expires"
        EXIT=2
fi

echo "$STATUS"
exit $EXIT
