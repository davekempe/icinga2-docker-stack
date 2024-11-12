#!/usr/bin/perl -w

#
# DART checks to Chris Boyd's Design
#
use constant VERSION => '1.0';
# 1.0 Woody 2023-02-24

use strict;
use Monitoring::Plugin;
use Time::Local qw(timelocal);
use LWP::UserAgent;
use JSON;
use URI;
use Data::Dumper;

my $P = Monitoring::Plugin->new(
        usage => "Usage: %s -a https://vizone/ -i http://ai2/ -u <viz1_user> -p <viz1_password> [-d|--debug <level>]",
        version => VERSION,
        blurb   => "Checks whether there are any manual cut items left over",
        shortname => ' ',
);

my $B = LWP::UserAgent->new();

my $J = JSON->new->ascii(1)->pretty(1)->canonical(1);

# debug is bitwise
our $DEBUG = 0;
sub DEBUG {return $DEBUG}
our %DBG_STR = (
        1       => 'WARN',
        2       => 'INFO',
        4       => 'URL',
        8       => 'JSON',
        16      => 'PERL',
        32      => 'CACHE',
);

my %perfdata = ();

my @extra = (); # extra output

sub debug {
        my ($level, @stuff) = @_;
        unless (($level) = (grep {$level == $_ or $level eq $DBG_STR{$_}} keys %DBG_STR)) {
                unshift @stuff,$_[0]; # no level was passed in
                $level = 1;
        }

        return unless ($level & DEBUG);
        printf STDERR ("%5s: %s\n",$DBG_STR{$level},$_) foreach @stuff;
}

$P->add_arg(
        spec    => "debug|d=i",
        help    => "Debug level, bitwise: ".join("|",map "$_=$DBG_STR{$_}",sort {$a <=> $b} keys %DBG_STR),
);

$P->add_arg(
        spec    => "apiurl|a=s",
        help    => "Viz One API web address",
        required => 1,
);

$P->add_arg(
        spec    => "ai2url|i=s",
        help    => "AI2 API web address",
        required => 1,
);

$P->add_arg(
        spec    => "username|user|u=s",
        help    => "Viz One API user",
        required => 1,
);

$P->add_arg(
        spec    => "password|pass|p=s",
        help    => "Viz One API password",
        required => 1,
);

$P->getopts;

$DEBUG = $P->opts->debug if $P->opts->debug;

my $VERBOSE = $P->opts->verbose;

my $AI2URL = $P->opts->ai2url;
my $APIURL = $P->opts->apiurl;
my $V1USER = $P->opts->username;
my $V1PASS = $P->opts->password;

{
    no warnings 'redefine';

    sub LWP::UserAgent::get_basic_credentials {
        my ($self, $realm, $url) = @_;

        return $V1USER,$V1PASS;
    }
}

sub command_lines { # run a command and get the output as a list of strings
        my $cmd = shift;
        my @lines = ();
        open CMD, "$cmd|" or return;
        while (<CMD>) {
                chomp;chomp;
                push @lines,$_;
        }
        close CMD;
        return @lines;
}

sub ai2_req { # call an API against AI2 and parse the resulting json
    my ($path,$params) = @_;

    my $url;
    if ($path =~ /^http/) {
        $url = URI->new($path);
    } else {
        $url = URI->new("$AI2URL/$path");
    }
    return _req($url,$params);
}

sub viz_req { # call an API against Viz One and parse the resulting json
    my ($path,$params) = @_;

    my $url;
    if ($path =~ /^http/) {
        $url = URI->new($path);
    } else {
        $url = URI->new("$APIURL/$path");
    }
    return _req($url,$params);
}

sub _req {
    my ($url,$params) = @_;

    $url->query_form(%$params) if $params;

    my $res = $B->get($url, Accept => 'application/json');
    &debug(4, sprintf("%6s %s => %s (%d bytes)",$res->request->method, $res->request->uri_canonical, $res->status_line, length($res->content)));
    &debug(8, "< ".$res->content);
    my $return = length($res->content) ? eval {$J->decode($res->content)} : '';
    if ($@) {
        &debug(1, "Could not decode content as JSON:\n".$res->content);
    }
    &debug(16, Dumper($return));
    if (!$res->is_success) {
        die $res->status_line . "\n\n" . $res->content;
    }
    return unless defined wantarray or length $res->content;
    return $return;
}

sub jsgmtime { # javascript time from epoch seconds
    my $epoch = shift;
    my ($ss,$mm,$hh,$d,$m,$y) = gmtime($epoch);
    return sprintf "%4d-%02d-%02dT%02d:%02d:%02d", $y + 1900, $m + 1, $d, $hh, $mm , $ss;
}

my $now = time;
my %state = (yesterday => WARNING, today => OK);
my %datecode = (
    "day before" => 19000100 + sprintf("%04d%02d%02d", (localtime($now-86400*2))[5,4,3]),
    yesterday    => 19000100 + sprintf("%04d%02d%02d", (localtime($now-86400))[5,4,3]),
    #today        => 19000100 + sprintf("%04d%02d%02d", (localtime($now))[5,4,3]),
);
foreach my $day (sort keys %datecode) {
    my $state = $state{$day} // CRITICAL;
    my $res = &viz_req(
        'api/search/item',
        {
            qProfile => 'multi-asset',
            sort => '-search.creationDate',
            'search.default' => "$datecode{$day}* \" Ingest\"",
            'facet.asset.materialType@asset' => 'ring',
            num => 5,
            'search.isDeleted' => 'false', # ignore items marked for deletion
        }
    );
    my $count = $res->{data}->{feedTotalResults};
    $perfdata{"INGEST_RECORDINGS_".uc(join '_', split /\s/, $day)} = $count;
    if ($count) {
        $P->add_message($state, "$count Ingest Recordings for $day ($datecode{$day})");
        foreach my $e (@{$res->{data}->{entries}}) {
            $P->add_message($state, " - Ingest Recording for $day '$e->{title}'");
        }
    } else {
        $P->add_message(OK, "No Ingest Recordings for $day ($datecode{$day})");
    }
}

#       resolution: delete the items after cutting / uploading etc

# do the exit
sub do_exit {
        my $unknown = shift;
        my $code = $P->check_messages;
        my @messages = ();
        my $first = not $unknown;
        foreach my $c (qw(critical warning ok)) {
                my @list = @{$P->messages->{$c}};
                next unless @list;
                if ($first) {
                        push @messages, shift @list;
                        $first = 0;
                }
                push @messages, map "  ".uc($c)." - $_", @list;
        }
        if ($unknown) {
                unshift @messages, $unknown;
                $code = UNKNOWN;
        }
        my $messages = join "\n", @messages, @extra;
        my $perfdata = join " ", map "$_=$perfdata{$_}", sort keys %perfdata;
        $messages .= "|$perfdata" if $perfdata;
        $P->plugin_exit($code, $messages);
}

do_exit();
