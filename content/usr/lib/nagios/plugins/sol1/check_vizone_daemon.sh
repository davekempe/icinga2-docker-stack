#!/bin/bash

DAEMON=$1

ALL=`ardemctl --terse status $DAEMON`
STATE=`echo $ALL | cut -d: -f 3`
if [[ "$STATE" == "UP-RESPAWN" ]]; then
        EXTRA="Was $ALL - slept 15 secs"
        sleep 15
        ALL=`ardemctl --terse status $DAEMON`
        STATE=`echo $ALL | cut -d: -f 3`
fi
SINCE=`echo $ALL | cut -d: -f 6`
NOW=`date +%s`
AGE=`expr $NOW - $SINCE`
RESTARTOK=120

STATUS="Unexpected error"
EXITCODE="127"

if [[ "$STATE" == "UP" ]]; then
        STATUS="OK Vizone has $DAEMON running $AGE seconds.|uptime=$AGE"
        EXITCODE=0
elif [[ "$STATE" == "UP-RESPAWN" ]]; then
        if [ $AGE -lt $RESTARTOK ]; then
                STATUS="OK Vizone has $DAEMON restarting $AGE < $RESTARTOK seconds."
                PERF="restarting=$AGE"
                EXITCODE=0
        else
                STATUS="WARNING Vizone has $DAEMON restarting $AGE >= $RESTARTOK seconds."
                PERF="restarting=$AGE"
                EXITCODE=1
        fi
else
        STATUS="$DOWNCOUNT $DAEMON daemons are down ($STATE) $AGE seconds!"
        PERF="down=$DOWNCOUNT,downtime=$AGE"
        EXITCODE=2
fi

echo $STATUS
echo $ALL
echo $EXTRA
echo "|$PERF"
exit $EXITCODE
