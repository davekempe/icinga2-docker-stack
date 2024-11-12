#!/bin/bash
#
# check that zone config deployment has succeeded

function trimMessage() {
 MESSAGE="$(echo -e "${MESSAGE}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' )"
}


STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3

exitCode=$STATE_UNKNOWN
MESSAGE="Icinga2 Config Deployment"
PERFDATA=""


# Your tests go here
if [ ! -f /var/lib/icinga2/api/zones-stage-startup.log ] ; then
    MESSAGE="$MESSAGE no zone stage startup file, assuming that's fine"
    exitCode=$STATE_OK
elif grep -q "information/cli: Finished validating the configuration file(s)." /var/lib/icinga2/api/zones-stage-startup.log ; then
    success=`grep "information/cli: Finished validating the configuration file(s)." /var/lib/icinga2/api/zones-stage-startup.log`
    time=`echo $success | cut -c 2-20`

    MESSAGE="$MESSAGE Validation complete @ $time\n$success"
    #WARNINGS=`grep -i warning /var/lib/icinga2/api/zones-stage-startup.log`
    #MESSAGE="$MESSAGE\n\nWarnings:\n$WARNINGS"
    exitCode=$STATE_OK

    if [ -f /var/lib/icinga2/api/zones-stage-startup-last-failed.log ] ; then
        lastfail=`head -1 /var/lib/icinga2/api/zones-stage-startup-last-failed.log | cut -c 2-20`
        MESSAGE="$MESSAGE\n\nLast Failure @ $lastfail"
    fi
else
    BROKEN=`cat /var/lib/icinga2/api/zones-stage-startup-last-failed.log`
    MESSAGE="$MESSAGE problem:\n$BROKEN"
    exitCode=$STATE_CRITICAL
fi

trimMessage

# Add performance data | 'label'=value[UOM];[warn];[crit];[min];[max], 'label'=value[UOM];[warn];[crit];[min];[max]
MESSAGE="$MESSAGE | $PERFDATA"

if [ $exitCode -eq $STATE_UNKNOWN ]; then
    echo "UNKNOWN - $MESSAGE"
elif [ $exitCode -eq $STATE_CRITICAL ]; then
    echo "CRITICAL - $MESSAGE"
elif [ $exitCode -eq $STATE_WARNING ]; then
    echo "WARNING - $MESSAGE"
elif [ $exitCode -eq $STATE_OK ]; then
    echo "OK - $MESSAGE"
fi

exit $exitCode
