#!/usr/bin/perl -w

#
# Viz One API checks to Chris Boyd's Design
#
use constant VERSION => '1.0';
# 1.0 Woody 2023-02-24
# 1.1 Woody 2023-08-23 rename and add transfer checks

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
        blurb   => "Viz One API based checks",
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

$P->add_arg(
        spec    => "check|C=s",
        help    => "Which check to run, e.g. transfer",
        required => 1,
);

$P->add_arg(
        spec    => "destination|dest|D=s",
        help    => "Which transfer destination to monitor",
);

$P->add_arg(
        spec    => "hours|H=s",
        help    => "How far back to look at transfers",
        default => 24,
);

$P->add_arg(
        spec    => "minutes|M=s",
        help    => "How far back to look at transfers",
        default => 0,
);

$P->add_arg(
        spec    => "number|N=s",
        help    => "How many transfers to search for",
        default => 1500,
);

$P->add_arg(
        spec    => "critical|c=s",
        help    => "Equal or exceeding this number will raise a critical alarm (ignored by transfer check)",
);

$P->add_arg(
        spec    => "warning|w=s",
        help    => "Equal or exceeding this number will raise a warning alarm (ignored by transfer check)",
);

$P->getopts;

$DEBUG = $P->opts->debug if $P->opts->debug;

my $VERBOSE = $P->opts->verbose;

my $CHECK = $P->opts->check;
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

sub epochjsgm { # epoch seconds from js gmtime
    my $jstime = shift;
    my @time = ($jstime =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)/);
    $time[1] -= 1;
    $time[0] -= 1900;
    return Time::Local::timegm(reverse @time);
}

sub _transfer {
    # curl -u $USER:$PASSWORD -H accept:application/json "https://vizone.skyracing.cloud/api/search/transfer?num=25&start=1&qProfile=transfer&qFacet=on&qHighlightMode=vms&sort=-search.creationDate&facet.transfer.finalDestinations=exp-web_ott_race&facet.transfer"
    my $param = {
        num => $P->opts->number,
        qProfile => 'transfer',
        sort => '-search.creationDate',
    };
    if ($P->opts->destination) {
        $param->{'facet.transfer.finalDestinations'} = $P->opts->destination;
    }

    my $res = &viz_req(
        'api/search/transfer',
        $param,
    );

    my $before = time - $P->opts->hours * 3600 - $P->opts->minutes * 60;
    return grep {not (($P->opts->hours or $P->opts->minutes) and epochjsgm($_->{created}) < $before)} @{$res->{data}->{entries}};
}

sub transfer {
    my @entries = &_transfer;

    # work out which races have been sent ok last
    my %data = ();
    foreach my $e (@entries) {
        if (my ($race) = $e->{itemTitle} =~ /(\d{8}\w{3}[RTG]\d\d(S|T|))/) {
            $data{$race} //= {};
            my $list = $data{$race}{$e->{state}} //= [];
            push @$list, $e;
        } else {
            push @extra, "Couldn't get a race out of $e->{itemTitle}";
        }
    }
    $perfdata{$_} = 0 foreach qw(first_time auto_recovered manual_recovered not_recovered);
    my $worst = 0;

    foreach my $racecode (sort {(values(%{$data{$b}}))[0][0]{created} cmp (values(%{$data{$a}}))[0][0]{created}} keys %data) {
        if (keys %{$data{$racecode}} == 1 and exists $data{$racecode}{O}) { # only success
            my @xfr = @{$data{$racecode}{O}};
            my @xfs = grep {@{$_->{destinationStorageHandles}} == 1 and $_->{destinationStorageHandles}[0] eq $P->opts->destination} map {@{$_->{steps}}} @xfr;
            my %xfs = ();
            $xfs{$_->{stepId}} = $_ foreach @xfs;

            $perfdata{first_time}++;

            #$P->add_message(OK, "$racecode had only successful transfer steps: ".join " , ", sort keys %xfs);
            next;
        } else {
            &debug(2,"$racecode had mixed success with transfer steps");
            my @xfr = map {@$_} values %{$data{$racecode}};
            my @xfs = grep {
                @{$_->{destinationStorageHandles}} == 1 and $_->{destinationStorageHandles}[0] eq $P->opts->destination
            } map {
                my $xfr = $_;
                (map {({%$_,state => $xfr->{state}, transferId => $xfr->{id}, xfr => $xfr})} @{$xfr->{steps}})
            } @xfr;
            my %xfs = ();
            $xfs{$_->{stepId}} = $_ foreach @xfs;
            my $final_state = undef;
            my $final_desc = undef;
            my $success_user = undef;
            foreach my $stepId (sort keys %xfs) {
                my $step = $xfs{$stepId};
                my $state = $step->{state};
                my $state_desc = {qw{E Errored C Cancelled O OK}}->{$state} || "Unknown ($state}";
                $final_state = $state_desc;
                my $start = epochjsgm($step->{xfr}->{created});
                $step->{duration} ||= 0;
                my $end = $start + $step->{duration};
                my $start_string = localtime $start;
                $final_desc = "$step->{transferId}/$stepId @ $start_string for $step->{duration} seconds by $step->{xfr}->{owner}";
                if ($state eq 'O') {
                    $success_user //= $step->{xfr}->{owner};
                }
                &debug(2," - $racecode transfer ($state_desc) $final_desc");
            }
            my $icinga_state = ($final_state eq 'OK') ? OK : CRITICAL;
            $worst = $icinga_state if $worst < $icinga_state;
            if ($final_state eq 'OK') {
                if ($success_user eq 'SYSTEM+autoingest2') {
                    $perfdata{auto_recovered}++;
                } elsif ( my ($user) = ($success_user =~ /^[A-Z]+\+(.*)$/) ) {
                    $perfdata{manual_recovered} ++;
                    $perfdata{"manual_recovered_$user"} = ($perfdata{"manual_recovered_$user"}||0) + 1;
                }
            } else {
                    $perfdata{not_recovered} ++;
            }

            $P->add_message($icinga_state, "$racecode - most recent transfer $final_desc in state '$final_state'");
            &debug(16,Dumper({$racecode => $data{$racecode}}));
        }
    }
    if ($worst == 0) {
        my $message = "No failed transfers";
        $message .= " to ".$P->opts->destination if $P->opts->destination;
        $message .= " in last ".$P->opts->number." transfers";
        if ($P->opts->hours or $P->opts->minutes) {
            $message .= " /";
            $message .= " ".$P->opts->hours." hours" if $P->opts->hours;
            $message .= " ".$P->opts->minutes." minutes" if $P->opts->minutes;
        }

        $P->add_message(OK, $message);
    }
    &debug(16,Dumper(\%data));
}

sub transfer_simple {
    my @entries = &_transfer;

    my %state = (O => [], E => [], C => []);
    # classify into states
    foreach my $e (@entries) {
        my $xfr_state = $e->{state};
        $state{$xfr_state} ||= [];
        push @{$state{$xfr_state}}, $e;
    }

    my $total = scalar(@entries);
    my $goodcount = scalar(@{$state{O}});
    my $badcount = $total - $goodcount;

    my $icinga_state = OK;
    if ($P->opts->critical and $badcount >= $P->opts->critical) {
        $icinga_state = CRITICAL;
    } elsif ($P->opts->warning and $badcount >= $P->opts->warning) {
        $icinga_state = WARNING;
    }
    $P->add_message(OK, "$goodcount/$total successful transfers");
    $P->add_message($icinga_state, "$badcount/$total failed transfers");

    foreach my $e (@entries) {
        my $state = $e->{state};
        my $state_desc = {qw{E Errored C Cancelled O OK}}->{$state} || "Unknown ($state}";
        my $created = localtime epochjsgm($e->{created});
        my $desc = "$e->{id} @ $created by $e->{owner} $e->{title}";
        $P->add_message($state eq 'O' ? OK : $icinga_state, "[$state_desc] $desc");
    }

    foreach my $state (keys %state) {
        $perfdata{"transfer_$state"} = scalar @{$state{$state}};
    }
}

if ($CHECK eq 'transfer') {
    &transfer;
} elsif ($CHECK eq 'transfer_simple') {
    &transfer_simple;
} else {
    $P->add_message(CRITICAL,"Don't know how to run check '$CHECK'");
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
