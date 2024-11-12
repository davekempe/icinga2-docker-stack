#!/usr/bin/perl -wl

use strict;
use POSIX;

my $UNKNOWN=3;
my $CRITICAL=2;
my $WARNING=1;
my $OK=0;
my $pre = {
        0 => "OK:      ",
        1 => "WARNING: ",
        2 => "CRITICAL:",
        3 => "UNKNOWN: ",
        INFO => "INFO:    ",
};

my %multiplier = (
        seconds => 1,
        minutes => 60,
        hours => 3600,
        days => 86400,
        weeks => 86400*7,
        months => 86400*30,
        years => 86400*365.25,
);

my $DAEMON=shift||"";

my $ret = undef;
my @output = ();
my %perfdata = ();

# example output
# time="2024-10-11T11:13:40+11:00" level=warning msg="The \"DOCKER_HOSTNAME\" variable is not set. Defaulting to a blank string."
# time="2024-10-11T11:13:40+11:00" level=warning msg="The \"DOCKER_HOSTNAME\" variable is not set. Defaulting to a blank string."
# time="2024-10-11T11:13:40+11:00" level=warning msg="The \"DOCKER_HOSTNAME\" variable is not set. Defaulting to a blank string."
# time="2024-10-11T11:13:40+11:00" level=warning msg="The \"DOCKER_HOSTNAME\" variable is not set. Defaulting to a blank string."
# time="2024-10-11T11:13:40+11:00" level=warning msg="The \"DOCKER_HOSTNAME\" variable is not set. Defaulting to a blank string."
# time="2024-10-11T11:13:40+11:00" level=warning msg="The \"DOCKER_HOSTNAME\" variable is not set. Defaulting to a blank string."
# SERVICE            STATUS       CREATED AT                       PORTS                                              
# analytics-daemon   Up 2 weeks   2024-09-25 17:49:50 +1000 AEST   127.0.0.1:8086->8084/tcp                           
# fileop-api         Up 2 weeks   2024-09-25 17:27:55 +1000 AEST   0.0.0.0:8085->8084/tcp                             
# fileop-monitor     Up 9 days    2024-09-25 17:27:55 +1000 AEST                                                      
# maintenance        Up 2 weeks   2024-09-25 15:34:18 +1000 AEST                                                      
# tasks-core         Up 2 weeks   2024-09-25 17:49:50 +1000 AEST   127.0.0.1:8022->8022/tcp, 0.0.0.0:8084->8084/tcp   
# tasks-processes    Up 9 days    2024-10-01 15:11:00 +1000 AEST                                                      
# tasks-site         Up 2 weeks   2024-09-25 17:49:50 +1000 AEST   0.0.0.0:8082->8084/tcp                             
# tasks-web          Up 2 weeks   2024-09-25 17:49:50 +1000 AEST   0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp           
# tasks-ws-ui        Up 2 weeks   2024-09-25 17:49:50 +1000 AEST                                                      
# redis              Up 6 weeks   2024-08-20 19:45:25 +1000 AEST   0.0.0.0:6379->6379/tcp                             

my $now = time();
open my $mayctl, "/usr/bin/sudo -u mayam /mayam/bin/mayctl status -v -w 100 $DAEMON 2>/dev/null|" or exit 3;
while (<$mayctl>) {
        next if /^\s*$/;
        next if /^time=/;
        next if /^SERVICE\s+STATUS\s+/;
        my ($service, $status_time, $created, $ports) = split /\s{2,}/;

        my ($date,$ctime,$offset,$zone) = split /\s/,$created;
        my ($y,$m,$d) = split /\-/,$date;
        my $epoch = POSIX::mktime(reverse(split /:/,$ctime),$d,$m-1,$y-1900);
        #push @output, "$pre->{INFO} $service $created => $epoch (".localtime($epoch).")";

        if ($status_time =~ /^Up About a (\w+)$/) {
                $status_time = "Up 1 ${1}s";
        }
        my ($status,$time,$units) = split /\s/,$status_time;
        $perfdata{"$service"} = $epoch ? ($now - $epoch) : $time * $multiplier{$units};

        my $alert = $UNKNOWN;
        if ($status eq "Up") {
                $alert = $OK;
                $ret = $alert if not defined $ret;
        } else {
                $alert = $CRITICAL;
                $ret = $alert if not defined $ret or $alert > $ret;
        }
        push @output, "$pre->{$alert} $service is $status (for $time $units since $date $ctime)";
        push @output, "$pre->{INFO} $service has ports $ports" if $ports;
}
close $mayctl;

my $errmsg = join "\n",@output;
$ret //= $UNKNOWN; # default to unknown but retain OK
if (not $errmsg) {
        if ($DAEMON) {
                $errmsg = "$pre->{$ret} No matching daemon for $DAEMON in mayctl output";
        } else {
                $errmsg = "$pre->{$ret} Could not understand mayctl output";
        }
}

my $perfdata = join " ", map {"$_=$perfdata{$_}"} sort {$perfdata{$b} <=> $perfdata{$a}} keys %perfdata;
print "$errmsg|$perfdata";
exit $ret;
