#!/bin/bash

OIFS=$IFS
E_SUCCESS="0"
E_WARNING="1"
E_CRITICAL="2"
E_UNKNOWN="3"

LOG="/var/lib/openvpn-server/openvpn/status.log"
CLIENT=$1
IFS=","
CLIENTINFO=$(cat $LOG | sed '/^ROUTING TABLE$/,$d' | grep -i $CLIENT)
CLIENTINFOARRAY=($CLIENTINFO)
IFS=$OIFS
CLIENTIP=${CLIENTINFOARRAY[1]}
CLIENTSINCE=${CLIENTINFOARRAY[6]}

function Echo_Status() {
	grep CLIENT_LIST $LOG|grep -v ^HEADER

}



if [ $CLIENT = "" ]; then
        echo "CRITICAL: No VPN client specified"
        exit ${E_CRITICAL}
fi

if [ ! -f $LOG ]; then
        echo "CRITICAL: VPN status log not found"
        exit ${E_CRITICAL}
fi

if [ ! -z $CLIENTIP ]; then
        echo "OK: $CLIENT connected as $CLIENTIP since $CLIENTSINCE"
	Echo_Status
        exit ${E_SUCCESS}
else
        echo "CRITICAL: $CLIENT not connected"
	Echo_Status
        exit ${E_CRITICAL}
fi

