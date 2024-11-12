#!/bin/bash

PERL5LIB=/opt/ardome/lib/perl:$PERL5LIB 
YESTERDAY=`date --date="yesterday" +%F`
ALL_FAILED_RECORDINGS=`/opt/ardome/bin/adt -F csv --csv 0 --data-only "select ent_title,ent_date,ent_start_time/3600,int((ent_start_time/3600.0-ent_start_time/3600)*60),ent_state from dart.entries where ent_date>'$YESTERDAY' and ent_state not in ('R','D','A','AP','RP')"`
FAILED_RECORDINGS=`echo "$ALL_FAILED_RECORDINGS" | wc -l`
if echo "$ALL_FAILED_RECORDINGS" | grep -q "No rows returned"; then
    FAILED_RECORDINGS=0
fi
WARNING=$1
CRITICAL=$2

E_SUCCESS="0"
E_WARNING="1"
E_CRITICAL="2"
E_UNKNOWN="3"

if [ $FAILED_RECORDINGS -gt 0 ]; then
    echo "CRITICAL - Dart has $FAILED_RECORDINGS failed recordings! | failed_recordings=$FAILED_RECORDINGS"
    echo "$ALL_FAILED_RECORDINGS"
    exit $E_CRITICAL
else
    echo "Okay - All recordings nominal in dart | failed_recordings=$FAILED_RECORDINGS"
    echo "$ALL_FAILED_RECORDINGS"
    exit $E_SUCCESS
fi
