#!/usr/bin/perl -l

use strict;
use XML::LibXML;

my $UNKNOWN  = 3;
my $CRITICAL = 2;
my $WARNING  = 1;
my $OK       = 0;

# Initialise return value as unknown by default
my $ret = $UNKNOWN;
my $errmsg = "Unexpected error";

my $host = "localhost";

if ($ARGV[0] and $ARGV[0] !~ /^\d+$/) {
    $host = shift;
}

my $WARNSIZ  = defined($ARGV[0]) ? $ARGV[0] : 2500;
my $CRITSIZ  = defined($ARGV[1]) ? $ARGV[1] : 5000;
my $CONSUMER_CHECK = $ARGV[2] || 0;
my @QUEUES = splice @ARGV, 3;
my %QUEUE = map {($_ => 1)} @QUEUES;

sub queue {
    # Exit with unknown status if fetching the queue info XML fails
    my $x = `curl -sk http://admin:admin\@$host:8161/admin/xml/queues.jsp` || exit $UNKNOWN;

    my $p = XML::LibXML->new();
    my $d = $p->parse_string($x);

    my @q = sort {
        $b->[1] <=> $a->[1]
    } grep {
        not @QUEUES or $QUEUE{$_->[0]}
    } map {
        [
            $_->getAttribute("name"),
            ($_->getElementsByTagName("stats"))[0]->getAttribute("size"),
            ($_->getElementsByTagName("stats"))[0]->getAttribute("consumerCount")
        ]
    } $d->getElementsByTagName("queue");
    return @q;
}

my @q = queue();

my $sum = 0;
$sum += $_->[1] foreach @q;

my %perfdata = ();
$perfdata{total} = $sum unless @QUEUES == 1;
$perfdata{$_->[0]} = $_->[1] foreach @q;

# Check the length of the queue against defined thresholds.
# Exit with return code accordingly with a useful comment contents of the
# queue.
if (not $CRITSIZ and not $WARNSIZ) {
        $errmsg = "INFO:    Viz One message queue length is $sum";
        $ret = $OK;
} elsif ($sum >= $CRITSIZ) {
        $ret = $CRITICAL;
        $errmsg = "CRITICAL: VizOne message queue length is $sum (>= $CRITSIZ)";
} elsif ($sum >= $WARNSIZ) {
        $ret = $WARNING;
        $errmsg = "WARNING: VizOne message queue length is $sum (>= $WARNSIZ, < $CRITSIZ)";
} elsif (defined $sum) {
        $ret = $OK;
        $errmsg = "OK:      VizOne message queue length is $sum (< $WARNSIZ, < $CRITSIZ)";
        if (not $sum) {
            $errmsg .= "\nINFO:    No queued messages";
        }
} else {
        $errmsg = "Unexpected error determining queue size";
}
if (not @QUEUES) {
    $errmsg .= "\nINFO:    $_->[0]: $_->[1]" foreach grep {$_->[1]} @q;
}

# check consumers
my $giveup = time + 15;
# wait around for a good consumer check, assuming it's just intermittent
if ($CONSUMER_CHECK) {
    while (time < $giveup) {
        if (my @c = grep {not $_->[2] and $_->[1]} @q) { # some queues without consumers
            $errmsg .= "\nINFO:    $_->[0] ($_->[1]) has no consumers, will check again" foreach @c;
            sleep 3;
            @q = &queue();
        } else {
            last;
        }
    }
}
foreach my $q (@q) {
    if ($q->[2] or not $CONSUMER_CHECK or not $q->[1]) {
        $errmsg .= "\nINFO:    $q->[0] ($q->[1] messages) has $q->[2] consumer(s)"
            if $QUEUE{$q->[0]} or not $q->[2] == 1;
    } else {
        my $pre = {1 => "WARNING:", 2 => "CRITICAL:"}->{$CONSUMER_CHECK} || "UNKNOWN:";
        my $msg = "$pre $q->[0] ($q->[1] messages) has no consumers";
        if ($ret < $CONSUMER_CHECK) {
            $ret = $CONSUMER_CHECK;
            $errmsg = "$msg\n$errmsg";
        } else {
            $errmsg .= "\n$msg";
        }
    }
}

my $perfdata = join " ", map {"$_=$perfdata{$_}"} sort {$perfdata{$b} <=> $perfdata{$a}} keys %perfdata;
print "$errmsg|$perfdata";
exit $ret;
