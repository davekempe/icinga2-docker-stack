#!/usr/bin/perl -w

#
# Check for gitlab open issues
#
use constant VERSION => '1.0';
# 1.0 Woody 2023-05-02

use strict;
use Monitoring::Plugin;
use Time::Local qw(timelocal);
use LWP::UserAgent;
use JSON;
use URI;
use Data::Dumper;

my $P = Monitoring::Plugin->new(
        usage   => "Usage: %s -a|--apiurl <gitlab url> -T|--token <gitlab api access token> -i|--id <project id> [-d|--debug <level>] [-w|--warning <issues>] [-c|--critical <issues>] [-v]",
        version => VERSION,
        blurb   => "Checks for open gitlab issues",
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
        help    => "gitlab API web address",
        required => 1,
);

$P->add_arg(
        spec    => "token|T=s",
        help    => "gitlab API token",
);

$P->add_arg(
        spec    => "id|i=s",
        help    => "gitlab project id",
        required => 1,
);

$P->add_arg(
        spec    => "warning|w=s",
        help    => "Number of issues to trigger a warning",
);

$P->add_arg(
        spec    => "critical|c=s",
        help    => "Number of issues to trigger a critical alert",
);

$P->getopts;

$DEBUG = $P->opts->debug if $P->opts->debug;

my $VERBOSE = $P->opts->verbose;

my $APIURL = $P->opts->apiurl;
my $TOKEN = $P->opts->token;
my $PROJ = $P->opts->id;

sub gitlab_req { # call an API against gitlab and parse the result
    my ($path,$params) = @_;

    my $url = URI->new("$APIURL/$path");
    $url->query_form(%$params) if $params;

    my $res = $B->get($url, Accept => 'application/json', "PRIVATE-TOKEN" => $TOKEN);
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

my $res = &gitlab_req( "api/v4/projects/$PROJ/issues", {state => 'opened'} );
my $count = @{$res};
$perfdata{open_issues} = $count;
if ($count) {
    my $state = OK;
    if ($P->opts->critical and $count >= $P->opts->critical) {
        $state = CRITICAL;
    } elsif ($P->opts->warning and $count >= $P->opts->warning) {
        $state = WARNING;
    }
    $P->add_message($state, "$count Open Issues");
    foreach my $e (@{$res}) {
        $P->add_message($state, "$e->{issue_type}$e->{references}->{short} <a href=\"$e->{web_url}\">'$e->{title}'</a> $e->{web_url}");
    }
} else {
    $P->add_message(OK, "No open issues");
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
