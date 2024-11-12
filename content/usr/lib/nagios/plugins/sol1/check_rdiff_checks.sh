#!/bin/bash
#
# Check everything on a backup server has a backup check
# based on /backupdir/customer/backup dirctory format
# Prerequisites: user and ssh keys on backup server
# Usage: command server.domain "/dir/dir" "cust1 cust2/dir1"
#        - exclude is optional

function checkParam() {
        local name="$1"
        local param="$2"

        if [ -z "$param" ]; then
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
MESSAGE=""

LOGIN_USER="nagioschecker"

if [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ]; then
        backupServer="$1"
        backupRoot="$2"
        depth="$3" # directory depth to look for rdiff-backup-data folders
        exclude=`echo "$4" | sed -e "s/,/ /g"`

        declare -a backups_missing=()
        declare -a backups_found=()
        declare -a backups_excluded=()

        # Log in to a backup server using the backup user and get list of backup dirs
        backupDirs=`find ${backupRoot} -mindepth $depth -maxdepth $depth -type d -name rdiff-backup-data 2> /dev/null | sed -e "s:${backupRoot}/::" | sed -e "s:/rdiff-backup-data::" | sort`
        icinga2Dirs=`icinga2 object list --type Host --name "$backupServer" 2>/dev/null | grep "rdiff_backup_dir" | sed -e 's/"//g'`

        echo "Backup Dirs:\n $backupDirs"
        echo "Icinga Vars:\n $icinga2Dirs"

        if [ $? -eq 0 ]; then
                MESSAGE=""
                for dir in ${backupDirs}; do
                        excluded=false
                        if [ -n "$exclude" ]; then
                                for part in $(seq 1 $depth) ; do # test each part of a path for exclusions
                                        if echo " ${exclude}" 2>/dev/null | grep -q -w `echo " $dir" | cut -f1-$part -d"/"` ; then      # Skip excluded name
                                                backups_excluded+=("$dir")
                                                excluded=true
                                        fi
                                done
                        fi

                        if [ $excluded = false ]; then
                                stub=`echo "$dir" | sed "s|${backupRoot}||g"`
                                if ! echo "${icinga2Dirs}" | grep -q "${stub}" ; then # Critical on missing backup checks for host
                                        backups_missing+=("$dir")
                                        exitCode=$STATE_CRITICAL
                                else
                                        backups_found+=("$dir")
                                fi
                        fi
                done

                if [ ${exitCode} -eq $STATE_CRITICAL ]; then
                        MESSAGE="Missing backup checks for `echo $MESSAGE | sed -e 's/ *$//g'`"
                else
                        MESSAGE="No missing backup checks"
                        exitCode=$STATE_OK
                fi

                MESSAGE="$MESSAGE\n\nMissing backups:"
                for missing in "${backups_missing[@]}"; do
                        MESSAGE="$MESSAGE\n$missing"
                done

                MESSAGE="$MESSAGE\n\nFound backups:"
                for found in "${backups_found[@]}"; do
                        MESSAGE="$MESSAGE\n$found"
                done

                MESSAGE="$MESSAGE\n\nExcluded backups:"
                for excluded in "${backups_excluded[@]}"; do
                        MESSAGE="$MESSAGE\n$excluded"
                done

        else
                MESSAGE="Error finding backups directories"
                exitCode=$STATE_CRITICAL
        fi
else
        exitCode=$STATE_UNKNOWN
        checkParam "server" "$1"
        checkParam "directory" "$1"
        checkParam "depth" "$1"

        trimMessage
        MESSAGE="Missing paramaters ${MESSAGE} ($@)"
fi

trimMessage

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

