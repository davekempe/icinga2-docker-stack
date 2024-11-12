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
MESSAGE="Icinga2 Director Syncrules"
PERFDATA=""


# Your tests go here
OLDIFS=$IFS
IFS=$'\n'
MSG_INSYNC="In sync rules: "
MSG_FAILING="Not in sync rules: \n"

warn=0
crit=0

if [ -n "$1" ] && [ -n "$2" ] ; then
        warn="$1"
        crit="$2"

    total=0
    insync=0
    failing=0
    for rule in `icingacli director syncrule list | tail -n +3 | sed -e "s/->//g" |  paste - - ` ; do
            id=`echo $rule | awk -F '|' '{print $1}' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'`
            name=`echo $rule | awk -F '|' '{print $2}' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'`
            result=`echo $rule | awk -F '|' '{print $3}' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'`

            total=$((total+1))

            if [ "$result" == "in-sync" ]; then
                    MSG_INSYNC="$MSG_INSYNC, $name"
                    insync=$((insync+1))
            elif echo "$result" | grep -q 'failing:' ; then
                    MSG_FAILING="${MSG_FAILING}'${name}' failing with error: \n  $result\n"
                    failing=$((failing+1))
            else
                    MSG_FAILING="${MSG_FAILING}'${name}' has unknown result: \n  $result\n"
                    failing=$((failing+1))
            fi

    done

    MSG_INSYNC=`echo $MSG_INSYNC | sed -e "s/In sync rules: ,/In sync rules: /g"`
    if [ $failing -ge $crit ] && [ $failing -gt 0 ] ; then
        exitCode=$STATE_CRITICAL
    elif [ $failing -ge $warn ] && [ $failing -gt 0 ] ; then
        exitCode=$STATE_WARNING
    elif [ $insync -gt 0 ]; then
            exitCode=$STATE_OK
    else
        MESSAGE="$MESSAGE\nUnable to find any in sync results from the syncrule list but it didn't fail more than $warn times either"
        exitCode=$STATE_CRITICAL
    fi



    MESSAGE="$MESSAGE\n$MSG_INSYNC\n$MSG_FAILING"
    PERFDATA="total=$total;;, insync=$insync;;, failing=$failing;$warn;$crit"

    IFS=$OLDIFS

else
    exitCode=$STATE_UNKNOWN

    checkParam "warn" "$1"
    checkParam "crit" "$2"
 
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
