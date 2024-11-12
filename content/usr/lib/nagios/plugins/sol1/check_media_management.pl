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
        usage => "Usage: %s -a https://vizone/ -u <viz1_user> -p <viz1_password> [-d|--debug <level>]",
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

my $now = time;
my $res = &viz_req(
    'api/search/item',
    {
        qProfile => 'multi-asset',
        sort => '-search.creationDate',
        #'search.default' => "$datecode{$day}* \" Ingest\"",
        'facet.sr.MediaManagement@asset' => 'required',
        num => 500,
        'search.isDeleted' => 'false', # ignore items marked for deletion
    }
);
my $count = $res->{data}->{feedTotalResults};
$perfdata{"media_manage_required"} = $count;
$perfdata{"media_manage_critical"} = 0;
$perfdata{"media_manage_warning"} = 0;
if ($count) {
    my $worst = undef;
    my $min = undef;
    my %state_messages = (OK => [], WARNING => [], CRITICAL => [], UNKNOWN => []);
    foreach my $e (sort {$a->{retentionDate} cmp $b->{retentionDate} || $a->{title} cmp $b->{title}} @{$res->{data}->{entries}}) {
        my $state = OK;
        my $rd = $e->{retentionDate};
        my ($y,$m,$d) = split /\-/, $rd;
        my $del = timelocal(0,0,0,$d,$m-1,$y-1900);
        my $days = int(($del -$now) / 86400);
        $min = $days if not defined $min or $days < $min;
        if ($days <= 30) {
            $state = CRITICAL;
            $perfdata{"media_manage_critical"}++;
        } elsif ($days <= 90) {
            $state = WARNING;
            $perfdata{"media_manage_warning"}++;
        }
        push @{$state_messages{$state}}, " - $days days on $rd $e->{siteIdentity} '$e->{title}'";
        $worst = $state if not defined $worst or $state > $worst;
    }
    $P->add_message($worst, "$count items require media management");
    $perfdata{"media_manage_min"} = "${min}d";
    $P->add_message($worst, "First item will be deleted in $min days");
    foreach my $state (sort keys %state_messages) {
        foreach my $msg (@{$state_messages{$state}}) {
            $P->add_message($state,$msg);
        }
    }
} else {
    $P->add_message(OK, "No Items Require Media Management");
}

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
