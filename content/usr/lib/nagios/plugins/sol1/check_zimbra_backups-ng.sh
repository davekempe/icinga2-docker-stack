#!/bin/bash
# Zimbra per-account backup check.
# Vesion 1.4 update by Matt
# - Add file checks
# - Add check boilerplate
# Vesion 1.3 rewritten by Oli
# Setup cron job to list accounts existing at 3AM for each server.
# Compares the backed up accounts against that list, rather than a new list each time which potentially contains new accounts
# 	Does a remote check by default (relies on the host running this script having ssh keys to zimbra@remote_host)
# 	Does a local check if the server is set as "localhost"
#59 02 * * * zimbra zmprov -l gaa -s subsoil.colo.sol1.net > /tmp/originalmailboxes.txt


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

function checkexitstatus () {
        if [ "$?" != "0" ] ; then 
		echo "UNKNOWN - Failed to check server $hostname"
                exit $STATE_UNKNOWN
        fi
}

function checkfileage () {
	local file="$1"
	local warn="$2"
	local crit="$3"
	local message=""
	local state=3
	
	# If we have a remote target use it
	if [ -n "$4" ] ; then
		message=`ssh $4 "/usr/lib/nagios/plugins/check_file_age -w $warn -c $crit -f ${file}"`
	else
		message=`/usr/lib/nagios/plugins/check_file_age -w $warn -c $crit -f "$file"`
	fi

	state="$?"

	if [ "$state" != "0" ] ; then
		echo "$message"
		exit $state
	fi
}

function checkaccountbackup() {
	local account="$1"
 	local ok_msg="$2"
	
	while [ `ps aux | grep -v "grep" | grep "zxsuite backup getAccountInfo" | wc -l` -gt $CONCURRENT_ACCOUNTINFO_CHECKS ] ; do
		sleep 1
	done

 	local getAccountInfo=`su zimbra -l -c "zxsuite backup getAccountInfo $account"`
 	local getAccountInfo_no_backup=`echo $getAccountInfo | grep -o "Can't find the backup folder for the account"`
        

	if [ "$getAccountInfo_no_backup" == "Can't find the backup folder for the account" ] ; then
		MESSAGE="${MESSAGE} account ${account} backup does not exist\n"
		exitCode=$STATE_CRITICAL
		
	else
		if [ "`echo $getAccountInfo | grep -o 'end date now'`" != "end date now" ] ; then
			MESSAGE="${MESSAGE} account ${account} backup not up to date\n"
			exitCode=$STATE_CRITICAL
		elif [ "$ok_msg" == "true" ] ; then
			MESSAGE="${MESSAGE} account ${account} backup ok\n"
		fi
	fi
}

STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3

exitCode=$STATE_UNKNOWN
MESSAGE=""

CONCURRENT_ACCOUNTINFO_CHECKS=20

if [ -n "$0" ] ; then


	TIMESTAMP=`date +%Y%m%d_%H%M%S`
	ZMHOSTNAME=`su zimbra -l -c "zmhostname"`
	LASTSCANHOURS=24
	CLEANUPOLDERTHANDAYS=7

	# zxsuite backup getBackupInfo
	TMP_GETBACKUPINFO="/tmp/zxsuite_backup_getBackupInfo.${TIMESTAMP}"
	su zimbra -l -c "zxsuite backup getBackupInfo > ${TMP_GETBACKUPINFO}"

	getBackupInfo_numActiveBackupedAccounts=`grep numActiveBackupedAccounts ${TMP_GETBACKUPINFO} | awk '{print $2}'`
	getBackupInfo_numCheckedAccounts=`grep numCheckedAccounts ${TMP_GETBACKUPINFO} | awk '{print $2}' | head -n1`
	getBackupInfo_lastScan=`grep lastScan ${TMP_GETBACKUPINFO} | awk '{print $2,$3}'`

	
	# zxsuite backup getAvailableAccounts
	TMP_GETAVAILABLEACCOUNTS="/tmp/zxsuite_backup_getAvailableAccounts.${TIMESTAMP}"
	su zimbra -l -c "zxsuite backup getAvailableAccounts > ${TMP_GETAVAILABLEACCOUNTS}"

	getAvailableAccounts_accountMapAccounts=`grep -A5000 accountMap ${TMP_GETAVAILABLEACCOUNTS} | grep -E "\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,6}\b"`

	
	# zxsuite backup getAvailableAccounts
	TMP_ZMPROV_GAA="/tmp/zmprov_gaa.${TIMESTAMP}"
	su zimbra -l -c "zmprov -l gaa -s $ZMHOSTNAME > ${TMP_ZMPROV_GAA}"



	### TESTS ###
	# Make sure there are backup accounts
	if [ $getBackupInfo_numActiveBackupedAccounts -eq 0 ]; then
		MESSAGE=" numActiveBackupedAccounts: is zero\n"
		exitCode=$STATE_CRITICAL
	else
		# make sure the number of active backed up accounts matches the number of checked accounts
		if [ $getBackupInfo_numActiveBackupedAccounts -eq $getBackupInfo_numCheckedAccounts ]; then
			MESSAGE=" numActiveBackupedAccounts: is $getBackupInfo_numActiveBackupedAccounts\n"
			exitCode=$STATE_OK
		else
			MESSAGE=" numActiveBackupedAccounts: is $getBackupInfo_numActiveBackupedAccounts but numCheckedAccounts is $getBackupInfo_numCheckedAccounts (needs checking)\n"
			exitCode=$STATE_WARNING
		fi
	fi


	# Make sure the last scan isn't too old
	if [ `date -d "$getBackupInfo_lastScan" +%s` -lt `date -d "-$LASTSCANHOURS hours" +%s` ] ; then
		MESSAGE="${MESSAGE} lastScan: was run at $getBackupInfo_lastScan which is more than $LASTSCANHOURS hours old\n"

		# if the last scan isn't recent then check each account has been backed up individually
		for email in `grep -oE "\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,6}\b" ${TMP_GETAVAILABLEACCOUNTS}` ; do
			checkaccountbackup "$email" &
		done
		wait

		if [ $exitCode == $STATE_OK ] ; then
			MESSAGE="${MESSAGE} all accounts that are backed up checked individually and are up to date \n"
		else
			exitCode=$STATE_CRITICAL
		fi
	fi


	# Make sure all zmprov accounts are backed up
	# Add exclusions for linked external accounts here
	for a in `cat ${TMP_ZMPROV_GAA} | grep -v -e 'galsync' -e 'spam-ham' -e 'spam-spam' -e 'virus-quarantine' -e '.gmail.com@' -e '.com.au@' -e '.edu.au@' -e '.screenrights.org@'` ; do
		if ! grep -q ${a} <<< $getAvailableAccounts_accountMapAccounts ; then
			checkaccountbackup "$a"	"true"
			MESSAGE="${MESSAGE} account ${a} missing from account map\n"
			if [ $exitCode != $STATE_CRITICAL ] ; then
				exitCode=$STATE_WARNING
			fi
		fi
	done


	# clean up
	find /tmp/ -type f -name "zxsuite_backup_getBackupInfo.*" -mtime +$CLEANUPOLDERTHANDAYS -exec rm {} \;
	find /tmp/ -type f -name "zxsuite_backup_getAvailableAccounts.*" -mtime +$CLEANUPOLDERTHANDAYS -exec rm {} \;
	find /tmp/ -type f -name "zmprov_gaa.*" -mtime +$CLEANUPOLDERTHANDAYS -exec rm {} \;


#	SERVER=$1
#	hostname="$SERVER"
#
#	BACKUP_TXT="/tmp/$SERVER-backups.txt"
#	STATUS_TXT="/tmp/$SERVER-status.txt"
#	MAILBOXES_TXT="/tmp/originalmailboxes.txt"
#
#	rm -f ${STATUS_TXT}
#
#
#	if [ "$SERVER" == "localhost" ] ; then
#		hostname="`hostname` ($SERVER)"
#		su zimbra -l -c "zmbackupquery -v $SERVER |grep @ | cut -d ' ' -f 3- | cut -d ':' -f 1| sort |uniq > ${BACKUP_TXT}"
#		checkexitstatus
#		checkfileage ${BACKUP_TXT} 60 60
#		checkfileage ${MAILBOXES_TXT} $((25 * 60 * 60)) $((32 * 60 * 60))
#
#		su zimbra -l -c "comm -23 <(sort ${MAILBOXES_TXT}) <(sort ${BACKUP_TXT})" > ${STATUS_TXT}
#		checkexitstatus
#	else
#		ssh zimbra@$SERVER "zmbackupquery -v $SERVER |grep @ | cut -d ' ' -f 3- | cut -d ':' -f 1| sort |uniq > ${BACKUP_TXT}"
#		checkexitstatus
#		checkfileage ${BACKUP_TXT} 60 60 zimbra@$SERVER
#		checkfileage ${MAILBOXES_TXT} $((25 * 60 * 60)) $((32 * 60 * 60)) zimbra@$SERVER
#
#		ssh zimbra@$SERVER "comm -23 <(sort ${MAILBOXES_TXT}) <(sort ${BACKUP_TXT})" > ${STATUS_TXT}
#		checkexitstatus
#
#	fi
#	checkfileage ${STATUS_TXT} 60 60
#
#
#	if [ $(wc -l ${STATUS_TXT} |cut -f 1 -d " ") -gt 0 ] ; then
#		MESSAGE="$hostname: $(wc -l ${STATUS_TXT} |cut -f 1 -d " ") accounts do not have a backup: `cat ${STATUS_TXT} | sed ':a;N;$!ba;s/\n/ /g'`"
#		exitCode=$STATE_CRITICAL
#	else
#		MESSAGE="$hostname: all accounts have a backup"
#		exitCode=$STATE_OK
#	fi

else
    exitCode=$STATE_UNKNOWN

    checkParam "server" "$1"
 
    trimMessage
    MESSAGE="Missing paramaters ${MESSAGE} ($@)"
fi

trimMessage
MESSAGE="$ZMHOSTNAME \n $MESSAGE"

if [ $exitCode -eq $STATE_UNKNOWN ]; then
    printf "UNKNOWN - $MESSAGE\n"
elif [ $exitCode -eq $STATE_CRITICAL ]; then
    printf "CRITICAL - $MESSAGE\n"
elif [ $exitCode -eq $STATE_WARNING ]; then
    printf "WARNING - $MESSAGE\n"
elif [ $exitCode -eq $STATE_OK ]; then
    printf "OK - $MESSAGE\n"
fi

exit $exitCode
