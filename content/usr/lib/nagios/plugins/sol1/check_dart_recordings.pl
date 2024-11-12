#!/usr/bin/perl -w

#
# DART checks to Chris Boyd's Design
#
use constant VERSION => '1.0';
# 1.0 Woody 2023-02-24

use strict;
use Monitoring::Plugin;
use Time::Local qw(timegm_modern);
use Time::HiRes;
use LWP::UserAgent;
use JSON;
use URI;
use Data::Dumper;

my $P = Monitoring::Plugin->new(
        usage => "Usage: %s -a https://vizone/ -i http://ai2/ -u <viz1_user> -p <viz1_password> [-d|--debug <level>]",
        version => VERSION,
        blurb   => "Checks which zimbra accounts have a current backup",
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

$P->add_arg(
        spec    => "extrahours|x=s",
        help    => "Number of extra hours to search before today, e.g. 8 hours = 4pm yesterday",
);

$P->add_arg(
        spec    => "lateflagmins|l=s",
        help    => "Number of minutes after the scheduled start that a race flag is late",
        default => 5,
);

$P->add_arg(
        spec    => "congestionsecs|c=s",
        help    => "Number of seconds after the race should have extended",
);

$P->add_arg(
        spec    => "extendforeversecs|f=s",
        help    => "Number of seconds a race duration with no flags is allowed before warning",
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
    my ($path,$params,$unsuccessful_ok) = @_;

    my $url;
    if ($path =~ /^http/) {
        $url = URI->new($path);
    } else {
        $url = URI->new("$APIURL/$path");
    }
    return _req($url,$params,$unsuccessful_ok);
}

sub _req {
    my ($url,$params,$unsuccessful_ok) = @_;

    $url->query_form(%$params) if $params;

    my $start = Time::HiRes::time;
    my $res = $B->get($url, Accept => 'application/json');
    &debug(4, sprintf("%6s %s => %s (%d bytes / %.2f s)",$res->request->method, $res->request->uri_canonical, $res->status_line, length($res->content), Time::HiRes::time-$start));
    &debug(8, "< ".$res->content);
    my $return = length($res->content) ? eval {$J->decode($res->content)} : '';
    if ($@) {
        &debug(1, "Could not decode content as JSON:\n".$res->content);
    }
    &debug(16, Dumper($return));
    if (!$unsuccessful_ok and !$res->is_success) {
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

sub timejs { # epoch seconds from javascript time
    my $js = shift;
    my @time = ($js =~ /^(\d{4})\-(\d\d)\-(\d\d)T(\d\d):(\d\d):(\d\d)(|\.\d+)Z$/) or return undef;
    my $frac = splice(@time,6);
    $time[1]--;
    return  timegm_modern(reverse @time) + ($frac ? "0$frac" : 0);
}

sub hh_mm { # epoch seconds to local hh:mm
    my $epoch = shift;
    my @time = localtime($epoch);
    return sprintf "%02d:%02d", @time[2,1];
}


# DART check:
#   Crash Recording:
#     Number/list of AI2 crash recording items
#       Critical is today
#       warning yesterday
#       resolution: delete the items after cutting / uploading etc
#     Active crashrecordings on DART
#       "Active Crash Recording of <racecode> on <framestore>"
#   Failed Recording:
#     Number/list of failed recordings on DART
#       critical = "today" +/- 8 hours
#       resolution = delete the failed DART entry after replacing it if necessary
#   Dart Delayed Race
#     race flags late:
#       no flags received more than 5 mins after start (warning)
#         this is useful even if the recording is extended because it is worth a human checking that the flags & therefore cuts are accurate
#       resolutions:
#         race has flags
#         recording stops
#     race can't extend because of congestion
#       AI2 recording should have extended 1 min ago but hasn't
#     race is going to extend forever (missing flags)
#       warning/list if an active race recording is over 30 mins long and has no flags
#       OK when recording is stopped



#
# DART check:
#   Crash Recording:
#


#     Number/list of AI2 crash recording items
#       Critical is today
#       warning yesterday

my %state = (today => CRITICAL, yesterday => WARNING);
my %datecode = (
    today       => 19000100 + sprintf("%04d%02d%02d", (localtime(time))[5,4,3]),
    yesterday   => 19000100 + sprintf("%04d%02d%02d", (localtime(time-86400))[5,4,3]),
);
foreach my $day (sort keys %state) {
    my $res = &viz_req(
        'api/search/item',
        {
            qProfile => 'multi-asset',
            sort => '-search.creationDate',
            'search.default' => "$datecode{$day}* \" Crash Recording\"",
            'facet.asset.materialType@asset' => 'ring',
            num => 3,
            'search.isDeleted' => 'false', # ignore items marked for deletion
        }
    );
    my $count = $res->{data}->{feedTotalResults};
    $perfdata{"CRASH_RECORDINGS_".uc($day)} = $count;
    if ($count) {
        $P->add_message($state{$day}, "$count Crash Recordings for $day ($datecode{$day})");
        foreach my $e (@{$res->{data}->{entries}}) {
            $P->add_message($state{$day}, " - Crash Recording for $day '$e->{title}'");
        }
    } else {
        $P->add_message(OK, "No Crash Recordings for $day ($datecode{$day})");
    }
}

    
#       resolution: delete the items after cutting / uploading etc

my $sources = &viz_req('thirdparty/ingest/source');
my %source = ();
$source{$_->{id}} = $_->{title} foreach @{$sources->{data}->{entries}};

my $recs = &viz_req('thirdparty/ingest/recording');

#     Active crashrecordings on DART
#       "Active Crash Recording of <racecode> on <framestore>"

my @crash = grep {
    $_->{state}->{state} eq 'active' and
    $_->{title} =~ /^C\d{1,2}[RTG]@[A-Z\s]+$/
} @{$recs->{data}->{entries}};
my $count = scalar @crash;
if ($count) {
    $P->add_message(CRITICAL, "$count Active Crash Recording(s) on DART");
    $perfdata{ACTIVE_CRASH_RECORDINGS} = $count;
    foreach my $cr (@crash) {
        my ($race,$code,$track) = ($cr->{title} =~ /^C(\d{1,2})([RTG])@([A-Z\s]+)$/);
        my ($source_id) = reverse split /:/, $cr->{source}->{ref};
        my $Track = ucfirst $track;
        my $animal = {R => "Thoroughbreds", G => "Greyhounds", T => "Harness"}->{$code} || "Code '$code'";
        $P->add_message(CRITICAL, "Active Crash Recording for Race $race at $Track ($animal) on $source{$source_id}")
    }
}

my @race_active = grep {
    $_->{state}->{state} eq 'active' and
    $_->{title} =~ /^\d{1,2}[RTG]@[A-Z\s]+$/
} @{$recs->{data}->{entries}};
my $race_count = scalar @race_active;
$perfdata{ACTIVE_RACE_RECORDINGS} = $race_count;
if ($race_count) {
    $P->add_message(OK, "$race_count Active Race Recording(s) on DART");
    foreach my $r (@race_active) {
        my ($race,$code,$track) = ($r->{title} =~ /^(\d{1,2})([RTG])@([A-Z\s]+)$/);
        my ($source_id) = reverse split /:/, $r->{source}->{ref};
        my $Track = ucfirst $track;
        my $animal = {R => "Thoroughbreds", G => "Greyhounds", T => "Harness"}->{$code} || "Code '$code'";
        $P->add_message(OK, "Active Recording for Race $race at $Track ($animal) on source $source{$source_id}")
    }
}

#   Failed Recording:
#     Number/list of failed recordings on DART
#       critical = "today" +/- 8 hours
#       resolution = delete the failed DART entry after replacing it if necessary
my $yesterday = &viz_req($recs->{data}->{prevLink});

# recent = within 8 hours of today, i.e. ending after 4pm local time
my $now = time;
my ($ss,$mm,$hh,$d,$m,$y) = localtime $now; # today's date
my $midnight = $now - $hh * 3600 - $mm * 60 - $ss; # midnight epoch
my $after_epoch = $midnight - 8 * 3600;

my @failed = grep {
    # compensating for the duration of the clip
    my $after = jsgmtime($after_epoch - $_->{duration});
    $_->{startTime} ge $after;
} grep {
    $_->{state}->{state} ne 'ok' and $_->{state}->{state} ne 'active' and $_->{state}->{state} ne 'scheduled' and $_->{state}->{state} ne 'starting'
} (@{$yesterday->{data}->{entries}},@{$recs->{data}->{entries}});

my $failed_count = scalar @failed;
$perfdata{FAILED_RECORDINGS} = $failed_count;
if ($failed_count) {
    $P->add_message(CRITICAL, "$failed_count Failed Recording(s) on DART");
    foreach my $r (@failed) {
        my ($source_id) = reverse split /:/, $r->{source}->{ref};
        $P->add_message(CRITICAL, "Failed Recording '$r->{state}->{state}' for $r->{title} on source $source{$source_id}")
    }
} else {
    $P->add_message(OK, "No Failed Recordings since ".scalar(localtime($after_epoch)));
}

#   No media in Viz One
#   - find check the recordings for last two days
#   - find the items in Viz One with a search for last two days
#   - match up items
#my $day_before = &viz_req($yesterday->{data}->{prevLink});
#my $day_before_that = &viz_req($day_before->{data}->{prevLink});
my @should_have_media = grep {
    $_->{state}->{state} eq 'ok'
} (
    #@{$day_before_that->{data}->{entries}},
    #@{$day_before->{data}->{entries}},
    @{$yesterday->{data}->{entries}},
    @{$recs->{data}->{entries}},
);
# recent search
my $recent = &viz_req('api/search/item',{qProfile => 'multi-asset',sort => '-search.creationDate',num => 400,'search.isDeleted' => 'false'});
my @recent = @{$recent->{data}->{entries}};
while (timejs($recent[-1]{created}) > $midnight - 86400 and $recent->{data}->{feedNextPage}) {
    $recent = &viz_req($recent->{data}->{feedNextPage});
    push @recent, @{$recent->{data}->{entries}};
}
# process recent into a lookup
my %recent = (); # itm_id => item
foreach my $r (@recent) {
    next if timejs($r->{created}) < $midnight - 86400;
    $recent{$r->{id}} = $r;
}

my @empty = ();
foreach my $rec (@should_have_media) {
    if ($rec->{asset}) {
        my ($itm_id) = reverse split /:/, $rec->{asset}->{ref};
        if (not exists $recent{$itm_id}) {
            #$P->add_message(OK, "$rec->{title} already deleted");
            next;
        }
        my $itm = $recent{$itm_id};
        my $mediaStatus = $itm->{mediaStatus};
        push @empty, [$rec,$itm] unless grep $mediaStatus eq $_, qw(online importing deleting);
    }
}
my $empty_count = scalar @empty;
$perfdata{EMPTY_RECORDINGS} = $empty_count;
if ($empty_count) {
    $P->add_message(CRITICAL, "$empty_count Empty Recording(s) in VizOne");
    foreach my $x (@empty) {
        my ($r,$itm) = @$x;
        my ($source_id) = reverse split /:/, $r->{source}->{ref};
        my $hh_mm = hh_mm(timejs($r->{startTime}));
        $P->add_message(CRITICAL, "Empty Recording [$itm->{mediaStatus}] for '$r->{title}' on source $source{$source_id} (Rec Start $hh_mm)")
    }
    $P->add_message(CRITICAL, "Check the DART folder in the DYNO for the raw recording");
} else {
    $P->add_message(OK, "No Empty Recordings today or yesterday");
}

#   Dart Delayed Race
#     race flags late:
#       no flags received more than 5 mins after scheduled start (warning)
#         this is useful even if the recording is extended because it is worth a human checking that the flags & therefore cuts are accurate
#       resolutions:
#         race has flags
#         recording stops

# curl -k -H Content-Type:application/json http://ai2.docker.skyracing.cloud/api/recordings and grep for race start more than 5 mins in the past and no flags
my $today_races = &ai2_req("/api/recordings");
my @rec_no_flags = grep {
    my $race = $_;
    ($race->{State} eq "RECORDING" or grep {$race->{VizRecordingId} and $race->{VizRecordingId} == $_->{id}} @race_active) and
    not grep {$race->{$_}} qw{BettingClosedFlagTime PTPFlagTime InterimFlagTime FinalFlagTime}
} @$today_races;
my $too_long_ago = jsgmtime($now - (5 + $P->opts->lateflagmins) * 60 - ($_->{PrePadSeconds}||0)); # compensate for manual padding
my @delayed = grep {
    $_->{RecordStartTime} lt $too_long_ago
} @rec_no_flags;

my $delayed_count = scalar @delayed;
$perfdata{DELAYED_RECORDINGS} = $delayed_count;
if ($delayed_count) {
    $P->add_message(WARNING, "$delayed_count Delayed Flag Recording(s) on DART (> ".$P->opts->lateflagmins." min)");
    foreach my $r (@delayed) {
        my $hh_mm = hh_mm(timejs($r->{RecordStartTime}));
        $P->add_message(WARNING, "Delayed Flag Recording '$r->{RaceId}' on source $r->{Framestore} (Rec Start $hh_mm)");
    }
} else {
    $P->add_message(OK, "No Delayed Recordings Active (> ".$P->opts->lateflagmins." min)");
}

#     race can't extend because of congestion
#       AI2 recording should have extended 1 min ago but hasn't
my @unextended = grep {
    # the calculation is too complex to reproduce here. Assuming a problem if it's less than 4 minutes to the end of the recording
    $_->{RecordStartTime} lt jsgmtime($now - $_->{RecordDuration} + 4 * 60)
} @rec_no_flags;
my $unextended_count = scalar @unextended;
$perfdata{UNEXTENDED_RECORDINGS} = $unextended_count;
if ($unextended_count) {
    $P->add_message(CRITICAL, "$unextended_count Recording(s) can't extend on DART");
    foreach my $r (@unextended) {
        $P->add_message(CRITICAL, "Late or can't extend Recording '$r->{RaceId}' on source $r->{Framestore}")
    }
} else {
    $P->add_message(OK, "No Recordings late extending")
}
#     race is going to extend forever (missing flags)
#       warning/list if an active race recording is over 30 mins long and has no flags
#       OK when recording is stopped
my $thirty_mins_ago = jsgmtime($now - 30 * 60);
my @hyperextended = grep {
    # the calculation is too complex to reproduce here. Assuming a problem if it's less than 4 minutes to the end of the recording
    $_->{RecordStartTime} lt $thirty_mins_ago
} @rec_no_flags;
my $hyperextended_count = scalar @hyperextended;
$perfdata{HYPEREXTENDED_RECORDINGS} = $hyperextended_count;
if ($hyperextended_count) {
    $P->add_message(CRITICAL, "$hyperextended_count Race Recording(s) over 30 minutes active on DART");
    foreach my $r (@hyperextended) {
        $P->add_message(CRITICAL, "Long Recording with no flags '$r->{RaceId}' on source $r->{Framestore}")
    }
} else {
    $P->add_message(OK, "No active race recordings over 30 minutes with no flags")
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
