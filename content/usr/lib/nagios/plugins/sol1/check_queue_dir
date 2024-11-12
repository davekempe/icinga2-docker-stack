#!/usr/bin/perl -wl

use strict;

# check the morpheus process queues - the folder should be empty or have been changed within the last X seconds

die "Usage: $0 <queue directory> [<critical seconds=600> [<warn seconds=300> [<critical files=250> [<warn files=50>]]]]\n\nAlert if a directory is non-empty and not updating\n" unless @ARGV;

my $SPOOL_DIR = shift;
my $crits = shift || 600;
my $warns = shift || 300;
my $critf = shift || 250;
my $warnf = shift || 50;

my $dir_age = time - (stat $SPOOL_DIR)[10];

chdir $SPOOL_DIR;
opendir (my $DIR, $SPOOL_DIR) or nag(2,"CRITICAL: Can't open morpheus directory $SPOOL_DIR");
my @files = grep -f $_, readdir $DIR;
closedir $DIR;

my $count = scalar(@files);

my $result = 2;
$result = 1 if $dir_age < $crits;
$result = 0 if $dir_age < $warns;
$result = 0 if $count == 0;
$result = 1 if $count > $warnf;
$result = 2 if $count > $critf;
my $text = {qw{0 OK 1 WARNING 2 CRITICAL}}->{$result};

print "$text: $SPOOL_DIR has $count file(s), updated $dir_age seconds ago|age=$dir_age;; queue=$count;;";
exit $result;
