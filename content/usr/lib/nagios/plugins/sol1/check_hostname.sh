#!/bin/bash
#

function checkParam() {
 local name="$1"
 local param="$2"

        if [ -z "$param" ] ; then
                MESSAGE="${MESSAGE} $name"
        fi
}

function trimMessage() {
 MESSAGE="$(echo -e "${MESSAGE}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' )"
}


STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3

exitCode=$STATE_UNKNOWN
MESSAGE="Hostname verification"
PERFDATA=""


if [ -n "$1" ] ; then
    name="$1"
    system_name=`hostname`

    if [ "${name,,}" == "${system_name,,}" ]; then
        exitCode=$STATE_OK
        MESSAGE="$MESSAGE\nGot expected hostname: $system_name"
    else
        exitCode=$STATE_WARNING
        MESSAGE="$MESSAGE\nGot unexpected hostname: $system_name instead of $name"
    fi
else
    exitCode=$STATE_UNKNOWN

    checkParam "hostname" "$1"
 
    trimMessage
    MESSAGE="Missing paramaters ${MESSAGE} ($@)"
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
