#!/usr/bin/perl -w

#
# AI2 checks to Chris Boyd's Design
#
use constant VERSION => '1.0';
# 1.0 Woody 2023-05-15

use strict;
use Monitoring::Plugin;
use Time::Local qw(timelocal_modern timegm_modern);
use LWP::UserAgent;
use JSON;
use URI;
use Data::Dumper;
use Net::FTP;
use Mojo::DOM;

# from https://docstore.mik.ua/orelly/perl4/cook/ch07_24.htm#perlckbk2-CHP-7-SECT-23
use IO::Handle;
use IO::Select;
use Symbol qw(qualify_to_ref);

sub sysreadline(*;$) {
    my($handle, $timeout) = @_;
    $handle = qualify_to_ref($handle, caller( ));
    my $infinitely_patient = (@_ == 1 || $timeout < 0);
    my $start_time = time( );
    my $selector = IO::Select->new( );
    $selector->add($handle);
    my $line = "";
SLEEP:
    until (at_eol($line)) {
        unless ($infinitely_patient) {
            return $line if time( ) > ($start_time + $timeout);
        }
        # sleep only 1 second before checking again
        next SLEEP unless $selector->can_read(0.1);
INPUT_READY:
        while ($selector->can_read(0.0)) {
            my $was_blocking = $handle->blocking(0);
CHAR:       while (sysread($handle, my $nextbyte, 1)) {
                $line .= $nextbyte;
                last CHAR if $nextbyte eq "\n";
            }
            $handle->blocking($was_blocking);
            # if incomplete line, keep trying
            next SLEEP unless at_eol($line);
            last INPUT_READY;
        }
    }
    return $line;
}
sub at_eol($) { $_[0] =~ /\n\z/ }

my $P = Monitoring::Plugin->new(
        usage => "Usage: %s -i http://ai2/ [-d|--debug <level>]",
        version => VERSION,
        blurb   => "Check and report on various interesting races from today's AI2 data",
        shortname => ' ',
);

my $I = LWP::UserAgent->new(timeout => 10); # internal traffic - no proxy
my $E = LWP::UserAgent->new(timeout => 45); # external traffic - may be a proxy

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
        32      => 'FTP',
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
);

$P->add_arg(
        spec    => "username|user|u=s",
        help    => "Viz One API user",
);

$P->add_arg(
        spec    => "password|pass|p=s",
        help    => "Viz One API password",
);

$P->add_arg(
        spec    => "ai2url|i=s",
        help    => "AI2 API web address",
);

$P->add_arg(
        spec    => "check|C=s",
        help    => "Which AI2 Check to run (feature|abandon|upcoming|akamai_overdue|weird)",
        required => 1,
);

$P->add_arg(
        spec    => "sdakamaiurl|S=s",
        help    => "Akamai SD FTP URL (required for akamai_overdue check)",
);

$P->add_arg(
        spec    => "hdakamaiurl|H=s",
        help    => "Akamai HD FTP URL (required for akamai_overdue check)",
);

$P->add_arg(
        spec    => "ottakamaiurl|O=s",
        help    => "Akamai OTT FTP URL (required for akamai_overdue check)",
);

$P->add_arg(
        spec    => "warning|w=i",
        help    => "Warning Level for check (seconds for akamai))",
);

$P->add_arg(
        spec    => "critical|c=i",
        help    => "critical Level for check (seconds for akamai))",
);

$P->add_arg(
        spec    => "greenwash|g=s",
        help    => "Check time periods (HH:MM-HH:MM - comma separated to supress reporting warnings or criticals, instead just log as info. e.g. 07:00-08:15,00:00-01:01",
);

$P->add_arg(
        spec    => "proxy|P=s",
        help    => "use a proxy for web traffic <hostname>:<port>",
);

$P->add_arg(
        spec    => "select|s=s",
        help    => "For relevant checks, only look at things of this type, e.g. trial, future, race_vision, steward_vision - comma separated, default is to look at all",
);

$P->add_arg(
        spec    => "unselect|U=s",
        help    => "For relevant checks, do not look at things of this type, e.g. trial, future, race_vision, steward_vision - comma separated, default is to look at all",
);

$P->add_arg(
    spec    => "greennotes|G=s",
    help    => "If any of these regexes appear in the notes / add notes field of a non-deleted race ingest/web cut/archive, downgrade a warning or a critical to OK",
);

$P->add_arg(
    spec    => "gitlaburl|l=s",
    help    => "gitlab API web address",
    default => "https://gitlab.skyracing.cloud",
);

$P->add_arg(
    spec    => "token|T=s",
    help    => "gitlab API token",
);

$P->getopts;

$DEBUG = $P->opts->debug if $P->opts->debug;

my $VERBOSE = $P->opts->verbose;

my $AI2URL = $P->opts->ai2url;
my $CHECK = $P->opts->check;
my $APIURL = $P->opts->apiurl;
my $V1USER = $P->opts->username;
my $V1PASS = $P->opts->password;
my $GLAURL = $P->opts->gitlaburl;
my $TOKEN = $P->opts->token;
my $GITLAB = undef;

{
    no warnings 'redefine';

    sub LWP::UserAgent::get_basic_credentials {
        my ($self, $realm, $url) = @_;

        return $V1USER,$V1PASS;
    }
}

sub gitlab_req { # call an API against gitlab and parse the result
    my ($path,$params) = @_;

    my $url = URI->new("$GLAURL/$path");
    $url->query_form(%$params) if $params;

    my $res = $I->get($url, Accept => 'application/json', "PRIVATE-TOKEN" => $TOKEN);
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

sub viz_req { # call an API against Viz One and parse the resulting json
    my ($path,$params,$raw) = @_;

    my $url;
    if ($path =~ /^http/) {
        $url = URI->new($path);
    } else {
        $url = URI->new("$APIURL/$path");
    }
    return _req($I,$url,$params,{},$raw);
}

my %STATE_TRACK_CODES = ();
my %EXTRA_TRACK_CODES = (
    ACT => {'Canberra Acton' => 'CAB'},
    NSW => {
        'Wagga Riverside' => 'WAG',
        'Beaumont Newcastle' => 'NEW',
        'Royal Randwick' => 'RAN',
        'Rosehill Gardens' => 'ROS',
        'Ladbrokes Gardens' => 'GDN',
    },
    QLD => {
        'Aquis Park Gold Coast Poly' => 'GCO',
        'Aquis Park Gold Coast' => 'GCO',
        'Sunshine Coast@Inner Track' => 'SUN',
        'Sunshine Coast Poly Track' => 'SUN',
        'Toowoomba Inner Track' => 'TOO',
        'Aquis Beaudesert' => 'BEA',
        'Ladbrokes Cannon Park' => 'CAI',
        'Rockhampton Night' => 'ROC',
    },
    VIC => {},
);

sub state_track_codes {
    my $return = _state_track_codes(@_);
    &debug(2,"state_track_codes(".join(',',@_).") -> ".join ',',@$return);
    return $return;
}
sub _state_track_codes {
    my ($state, $query) = @_;
    if (not keys %STATE_TRACK_CODES) {
        my $all_track_codes = &viz_req("api/metadata/dictionary/~TrackCode/")->{data}->{entries};
        foreach my $entry (@$all_track_codes) {
            my ($code,$track,$state) = ($entry->{value} =~ /^(\w{3})\s\-\s(.*)\s\((\w+)\)$/) or next;
            $STATE_TRACK_CODES{$state} ||= {code => {}, track => {}};
            my $codelist = $STATE_TRACK_CODES{$state}{code}{uc $code} ||= [];
            push @$codelist, $track;
            my $tracklist = $STATE_TRACK_CODES{$state}{track}{uc $track} ||= [];
            push @$tracklist, uc $code;
        }
        foreach my $state (keys %EXTRA_TRACK_CODES) {
            $STATE_TRACK_CODES{$state} ||= {code => {}, track => {}};
            foreach my $track (keys %{$EXTRA_TRACK_CODES{$state}}) {
                my $code = $EXTRA_TRACK_CODES{$state}{$track};
                $STATE_TRACK_CODES{$state}{code}{uc $code} = $track;
                my $tracklist = $STATE_TRACK_CODES{$state}{track}{uc $track} ||= [];
                push @$tracklist, uc $code;
            }
        }
    }
    if (exists $STATE_TRACK_CODES{$state}) {
        if (exists $STATE_TRACK_CODES{$state}{code}{uc $query}) {
            return $STATE_TRACK_CODES{$state}{code}{uc $query};
        } elsif (exists $STATE_TRACK_CODES{$state}{track}{uc $query}) {
            return $STATE_TRACK_CODES{$state}{track}{uc $query};
        } else {
            my $i = "Unknown $state track or code '$query'";
            #push @extra, "INFO: $i";
            &debug(1, $i);
            return [];
        }
    }
}

sub viz_md { # get the metadata of an item as a hash
    my $itm_id = shift;
    my $xml = &viz_req("api/asset/item/$itm_id/metadata",{},1);
    my $dom = Mojo::DOM->new($xml);
    # plain fields
    my $md = {
        map {
            my $key = $_->{name};
            my $value = undef;
            if (my $list = $_->find('list')->first) {
                $value = [];
                foreach my $entry ($list->find('payloads')->each) {
                    push @$value, {map {($_->name => $_->find('value')->first->text)} $entry->find('field')};
                }
            } elsif (my $v = $_->find('value')->first) {
                $value = $v->text;
            }
            ($key => $value);
        } $dom->find('field')->each
    };
    return unless keys %$md;
    return $md;
}

sub ai2_req { # call an API against AI2 and parse the resulting json
    my ($path,$params) = @_;

    my $url;
    if ($path =~ /^http/) {
        $url = URI->new($path);
    } else {
        $url = URI->new("$AI2URL/$path");
    }
    return _req($I,$url,$params);
}

sub _get {
    my $ua = shift;
    my $start = time;
    my $res = $ua->get(@_);
    my $time = time - $start;
    my $message = sprintf("%6s %s => %s (%d bytes in %d secs)",$res->request->method, $res->request->uri_canonical, $res->status_line, length($res->content), $time);
    $P->add_message(CRITICAL, "Failed Request: $message") unless $res->is_success;
    &debug(4, $message);
    &debug(8, "< ".$res->content);
    return $res;
}

sub _dom_get {
    my $res = _get(@_);
    if ($res->is_success) {
        my $html = $res->content;
        return Mojo::DOM->new($html);
    } else {
        my $err = $res->status_line;
        do_exit("Failed GET on $_[1] ($err) when looking for DOM, giving up");
    }
}

sub _req {
    my ($ua,$url,$params,$headers,$raw) = @_;

    $headers ||= {};
    $headers->{Accept} ||= 'application/json';

    $url->query_form(%$params) if $params;

    my $res = _get($ua,$url, %$headers);
    return $res->content if $raw;
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

sub jsepochtime { # epoch seconds from javascript time
    my $js = shift;
    my ($year,$month,$day,$hour,$min,$sec) = ($js =~ /^(\d{4})\-(\d\d)\-(\d\d)T(\d\d):(\d\d):(\d\d)$/);
    return timelocal_modern($sec,$min,$hour,$day,$month-1,$year);
}

sub localtimefull {
    my $time = shift || time;
    my ($y,$m,$d,$H,$M,$S) = (localtime($time))[5,4,3,2,1,0];
    $y += 1900;
    $m++;
    return ($y,$m,$d,$H,$M,$S)
}


my @Mon = qw[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec];
my %Mon = map {($Mon[$_] => $_)} 0..$#Mon;

my $no_ai2 = grep $CHECK eq $_,qw(racingnsw racingqld greyhoundsnsw skyracing);

my %today_races = map {($_->{RaceId} => $_)} @{&ai2_req("/api/recordings")} unless $no_ai2;

my %today_meetings = map {($_->{Id} => $_)} @{&ai2_req("/api/meetings")} unless $no_ai2;

# my ($today) = sort {$a cmp $b} map $_->{MeetingDate}, values %today_meetings unless $no_ai2;
# sometimes yesterdays are included
my $today = sprintf("%04d-%02d-%02dT00:00:00", (localtimefull(time - 3600 * 6))[0,1,2]); # new day at 6am

my %today_sourceevent = map {($_->{EventId} => $_)} @{&ai2_req("/api/source_events")} unless $no_ai2;

my %today_events = map {
    my $meeting = $today_meetings{$_->{MeetingId}};
    my $sourceevent = $today_sourceevent{$_->{Id}};
    my $racecode = join "",
        (split /-/,(split /T/, $meeting->{MeetingDate}//'0000-00-00T00:00:00')[0]),
        $meeting->{SkyTrackCode}//'___',
        $meeting->{Sport}//'_',
        sprintf "%02d", $_->{Number};
    my $rec = $today_races{$racecode};
    (
        $_->{Id} => {
            %$_,
            meeting => $meeting,
            racecode => $racecode,
            recording => $rec,
            sourceevent => $sourceevent,
        }
    )
} @{&ai2_req("/api/events")} unless $no_ai2;

my @sorted = sort {
    $a->{StartTime} cmp $b->{StartTime}
        or
    $a->{racecode} cmp $b->{racecode}
} grep {
    $_->{meeting}->{MeetingDate} and $_->{meeting}->{MeetingDate} eq $today
} values %today_events;
my @interesting = ();

my $now = time;
my $jsnow = jsgmtime($now);
# ghetto timezone offset
my $offset_hours = ((localtime($now))[2] - (gmtime($now))[2])%24;

# convert an ai2 race structure into a string for human readability
sub race_string {
    my $e = shift;
    my $start_time;
    if ($e->{StartTime}) {
        my ($h,$m,$s) = map {$_+0} ($e->{StartTime} =~ /T(\d\d):(\d\d):(\d\d)Z/);
        $h += $offset_hours;
        $start_time = sprintf("%02d:%02d", $h%24, $m);
    } elsif ($e->{recording}->{RecordStartTime}) {
        my ($h,$m,$s) = map {$_+0} ($e->{recording}->{RecordStartTime} =~ /T(\d\d):(\d\d):(\d\d)Z/);
        $m += 5; # recording starts 5 mins before race
        $h += $offset_hours;
        if ($m >= 60) {
            $h ++;
            $m -= 60;
        }
        $start_time = sprintf("%02d:%02d", $h%24, $m);
    } else {
        $start_time = "??:??";
    }
    return sprintf "%5s %3s %s (%s)", $start_time, substr($e->{racecode},8), $e->{recording}->{Framestore}||"<No FS>", join(" ",map ucfirst(lc $_), split /\s+/,$e->{meeting}->{VenueName}||"")||substr($e->{racecode},8,3);
}

my %check_desc = (
    akamai_overdue => "Akamai Overdue",
);

#
# proxy
#
if (my $p = $P->opts->proxy) {
    $E->proxy(['http','https'] => "http://$p");
}

#
# greenwash time period
#
my $green = "";
if (my $g = $P->opts->greenwash) {
    #
    # assumes server has localtime
    # ignores/tolerates daylight saving
    #
    my ($h,$m) = (localtime)[2,1];
    my $day_minutes = $m + $h * 60;
    foreach my $period (split /,/,$g) {
        my ($h1,$m1,$h2,$m2) = ($period =~ /(\d\d):(\d\d)\-(\d\d):(\d\d)/);
        my $dm1 = $m1 + $h1 * 60;
        my $dm2 = $m2 + $h2 * 60;
        if ($dm1 <= $dm2) { # not over midnight
            if ($dm1 <= $day_minutes and $dm2 >= $day_minutes) {
                $green = $period;
                last;
            }
        } else { # over midnight
            if ($dm2 >= $day_minutes or $dm1 <= $day_minutes) {
                $green = $period;
                last;
            }
        }
    }
}

if ($CHECK eq 'upcoming') {
    @interesting = grep {
        $_->{StartTime} gt $jsnow
    } @sorted;
} elsif ($CHECK eq 'abandoned') {
    @interesting = map {
        if (not $_->{recording}->{Framestore}) {
            $_->{_check_state} = OK;
            $_->{_comment} = "[Before Setup]";
        } else {
            my ($comment) = map {join " ", map {ucfirst lc} split} grep $_, $_->{sourceevent}->{AbandonReason}, "NO REASON GIVEN";
            if ($_->{recording}->{DoneTime} and $_->{recording}->{DoneTime} gt $_->{recording}->{RecordStartTime} and $_->{recording}->{DoneTime} gt jsgmtime(time - 60 * 10)) {
                $_->{_check_state} = CRITICAL;

            } elsif ($_->{recording}->{DoneTime} and $_->{recording}->{DoneTime} gt jsgmtime(time - 60 * 30)) {
                $_->{_check_state} = WARNING;
            } else {
                $_->{_check_state} = OK;
            }
            $_->{_comment} = "'$comment'";
        }
        $_;
    } grep {
        $_->{sourceevent}->{EventStatus} eq 'Abandoned'
    } @sorted;
} elsif ($CHECK eq 'feature') {
    @interesting = grep {
        $_->{StartTime} gt $jsnow and
        $_->{recording}->{Manual} # future manual is likely done by human
    } @sorted;
} elsif ($CHECK eq 'akamai_overdue') {
    # find out what is on akamai
    my %url = ();
    my %def = (
        SD => {loc => 'SD', dir => 'Race_Replay', suffix => '_V.mp4'},
        HD => {loc => 'HD', dir => 'Race_Replay', suffix => '_V.mp4'},
        MP3 => {loc => 'SD', dir => 'Audio_Replay', suffix => '.mp3'},
        JPG => {loc => 'SD', dir => 'Thumbs', suffix => '_th_0.jpg'},
        TS_720 => {loc => 'OTT', dir => 'Race_Replay', suffix => '_720.ts'},
        M3U8_720 => {loc => 'OTT', dir => 'Race_Replay', suffix => '_720.m3u8'},
        M3U8 => {loc => 'OTT', dir => 'Race_Replay', suffix => '.m3u8'},
        JPEG => {loc => 'OTT', dir => 'Thumbs', suffix => '_th_0.jpg'},
    );
    my %akamai;
    $akamai{$_} = {} foreach keys %def;
    
    my %day = ();
    foreach my $day (qw(today yesterday)) {
        my ($y,$m,$d,$H,$M,$S) = localtimefull($day eq "today" ? time : (time - 86400));
        $day{$day} = {
            dir => sprintf("%4d/%02d", $y, $m),
            glob => sprintf("%04d%02d%02d*", $y, $m, $d)
        };
    }
    
    $url{SD} = $P->opts->sdakamaiurl;
    $url{HD} = $P->opts->hdakamaiurl;
    $url{OTT} = $P->opts->ottakamaiurl;

    #
    # turn all the above into a list of ftp directories and files to extract
    #
    my %listing_url = (); # ftp directory url with glob => hash of %def keys to suffix
    my %handle_list = (); # list from listing handle to the file listing it should be populating
    my %handle_url = (); # list from listing handle to the url it is listing
    foreach my $def (sort keys %def) {
        if (not $url{$def{$def}{loc}}) {
            push @extra, "INFO: $def{$def}{loc} URL not provided, skipping $def checks";
            delete $def{$def};
            next;
        }
        my $base_url = "$url{$def{$def}{loc}}/$def{$def}{dir}";
        foreach my $day (sort keys %day) {
            my $full_url = "$base_url/$day{$day}{dir}/$day{$day}{glob}";
            $listing_url{$full_url} ||= {_list_ => []};
            $listing_url{$full_url}{$def} = $def{$def}{suffix};
        }
    }
    my $select = IO::Select->new();
    #
    # connect to the FTPs and get filehandles for the listings
    #
    foreach my $url (sort keys %listing_url) {
        # get the ftp listing
        my $uri = URI->new($url);
        my $ftp = Net::FTP->new($uri->host, Port => $uri->port||21, Debug => $DEBUG&32, Timeout => 20);
        if (not $ftp) {
            $P->add_message(WARNING, "Could not connect to FTP URL '$url' => '$uri' => '".$uri->host."', skipping");
            next;
        }
        $ftp->login($uri->user,$uri->password);
        if ($ftp->error) {
            do_exit("Could not login to FTP URL '$url': ".$ftp->message);
        }
        $ftp->passive(1);
        # take the glob off the path
        my @segments = $uri->path_segments;
        my $glob = pop @segments;
        $uri->path_segments(@segments);
        $ftp->cwd($uri->path);
        # list the files
        my $retries = 5;
        my $listing;
        &debug(32, "Listing files in $url");
        while ($retries-->0) {
            $listing = $ftp->list($glob);
            last if $listing;
            $P->add_message(WARNING, "Could not get listing for $url, retrying $retries more times in 1 second: ".$ftp->message);
            sleep 1;
        }
        if ($listing) {
            $handle_url{$listing} = $url;
            $handle_list{$listing} = $listing_url{$url}{_list_};
            $select->add($listing);
            &debug(4,"  LIST $url");
            &debug(32, "Listing filehandle for $url is $listing");
        }
    }
    #
    # Get Yesterday's Races while FTP remote is chugging away
    #
    my %yesterday_races = map {
        ($_->{RaceId} => {
            recording => $_,
            racecode => $_->{RaceId}
        });
    } @{&ai2_req("/api/yesterdayrecordings")};
    my @yesterday_sorted = sort {($a->{recording}->{RecordStartTime}//$a->{racecode}) cmp ($b->{recording}->{RecordStartTime}//$b->{racecode}) or $a->{racecode} cmp $b->{racecode}} values %yesterday_races;
    unshift @sorted, @yesterday_sorted;
    #
    # read all the file listings
    #
    while (keys %handle_list) {
        my @ready = $select->can_read(15);
        foreach my $fh (@ready) {
            # figure out which list we are writing to
            my $url = $handle_url{$fh};
            my $list = $handle_list{$fh};
            if (not $list) {
                &debug(32, "Couldn't find list for $fh");
            }
            my $read = 0;
            while (1) {
                my $line = sysreadline($fh, 0.1);
                if ($line eq "") {
                    if (not $read) { # we got can_read but nothing to read => EOF
                        $select->remove($fh);
                        $fh->close;
                        delete $handle_list{$fh};
                        &debug(32,"Finished Reading $url / $fh");
                        my $desc = 'No files';
                        $desc = scalar(@$list)." files $list->[0]->{filename}..$list->[-1]->{filename}" if @$list;
                        &debug(4,"  LIST $url => $desc");
                    }
                    # otherwise we just didn't get a line, stop reading now, if we're really finished then next time through we'll get it
                    last;
                } else {
                    $read++;
                }
                my (undef,undef,undef,undef,$size, $month, $day, $time, @name) = split /\s+/,$line;
                next unless $size;
                my ($hour,$minute) = split /:/, $time;
                $hour += $offset_hours;
                if ($hour > 24) {
                    $day ++; # FIXME wrap month
                }
                $time = sprintf "%02d:%02d", $hour, $minute;
                my $datetime = "$month $day $time";
                my $name = join " ", @name;
                push @$list, my $entry = {bytes => $size, filename => $name, time => $time, month => $month, day => $day, datetime => $datetime};
                &debug(32,"Read ($read) $url: $name = $$entry{bytes} @ $$entry{datetime}");
            }
        }
    }
    #
    # work out what is uploaded
    #
    foreach my $url (sort keys %listing_url) {
        my $list = delete $listing_url{$url}{_list_};
        foreach my $entry (@$list) {
            my $name = $entry->{filename};
            my $match = 0;
            foreach my $def (sort keys %{$listing_url{$url}}) {
                my $suffix = $listing_url{$url}{$def};
                if (my ($rc) = ($name =~ /^(\d{8}\w{3}[RTG]\d\d(|S|T))$suffix$/i)) {
                    $akamai{$def}{$rc} = $entry;
                    &debug(32,"+ Match $def/$url $name = $$entry{bytes} @ $$entry{datetime}");
                    $match = 1;
                }
            }
            if (not $match) {
                &debug(32,"- No Match for $url - $name = $$entry{bytes} @ $$entry{datetime}");
            }
        }
    }
    my @past = grep {not $_->{StartTime} or $_->{StartTime} lt $jsnow} @sorted;
    my ($latest) = grep {exists $akamai{SD}{$_->{racecode}}} reverse @past;
    if ($latest) {
        $P->add_message(OK, sprintf("Latest uploaded: %s @ %s", &race_string($latest), $akamai{SD}{$latest->{racecode}}->{datetime}));
    }
    my $jswarn = defined($P->opts->warning) ? &jsgmtime(time - $P->opts->warning) : undef;
    my $jscrit = defined($P->opts->critical) ? &jsgmtime(time - $P->opts->critical) : undef;
    @interesting = grep {
        @{$_->{_missing}}
    } map {
        my $e = $_;
        # work out the state based on age
        my $state = OK;
        my @missing = ();
        my @present = ();
        foreach my $def (sort keys %def) {
            my $loc = $def{$def}{loc};
            next if substr($def,0,2) eq 'HD' and substr($_->{recording}->{Framestore},0,2) ne 'HD';
            if (exists $akamai{$def}{$_->{racecode}}) {
                push @present, $def;
            } else {
                push @missing, $def;
            }
        }
        if ($e->{recording}->{BettingClosedFlagTime}) {
            $state = WARNING if $jswarn and $jswarn gt $e->{recording}->{BettingClosedFlagTime};
            $state = CRITICAL if $jscrit and $jscrit gt $e->{recording}->{BettingClosedFlagTime};
        }
        my $comment = join(" / ", grep {length} scalar(@missing) ? "Missing ".join(" + ",@missing) : "", scalar(@present) ? "Present ".join(" + ",@present) : "");
        ({%$e, _check_state => $state, _missing => [@missing], _comment => $comment}); #, _comment => "$e->{recording}->{BettingClosedFlagTime} / $jswarn / $jscrit"});
    } grep {
        not $_->{StartTime} or $_->{StartTime} lt $jsnow
    } grep {
        not (exists $_->{sourceevent} ? $_->{sourceevent}->{EventStatus} eq 'Abandoned' : ($_->{recording}->{DoneTime}||8) lt ($_->{recording}->{RecordStartTime}||9))
    } @sorted;
} elsif ($CHECK eq 'weird') {
    @interesting = grep {
        # missing details
        (not $_->{recording}->{Framestore} or $_->{recording}->{Framestore} !~ /(HD |)FSTOR\s+\d+$/)
    } grep {
        not $_->{sourceevent}->{EventStatus} or $_->{sourceevent}->{EventStatus} ne 'Abandoned'
    } @sorted;
} elsif (grep $CHECK eq $_, 'racingnsw', 'racingqld', 'racingqldold', 'greyhoundsnsw') {
    my %meetings = (); # key = today/yesterday , value = hash of meeting to details
    if ($CHECK eq 'racingnsw') {
        my ($yy,$ym,$yd) = localtimefull(time - 86400); # yesterday
        my $url = "https://racing.racingnsw.com.au/FreeFields/Calendar_Meetings.aspx?State=NSW&date=$yd/$ym/$yy";
        my $dom = _dom_get($E,$url);
        my %dom = ();
        $dom{yesterday} = $dom->find('div[class="nsw-cal-date"]')->first(sub {$_->text eq sprintf("%02d %s %2d",$yd,$Mon[$ym-1],$yy%100)})->parent;
        $dom{today} = $dom->find('td[class="today"]')->first;
        foreach my $day (reverse sort keys %dom) {
            $meetings{$day} = {};
            foreach my $div ($dom{$day}->find('div')->each) {
                next if not exists $div->{id} or $div->{id} eq 'outer';
                if (my ($year,$Mon,$dom,$state,$meet,$thing) = ($div->{id} =~ /^(\d{4})([A-Z][a-z]{2})(\d\d),([A-Z]{3}),(.*)_(Meeting|Races)/)) {
                    my ($track,$type) = split /,/,$meet;
                    #push @extra, "$day - $dom $mon $year - $track ($state) $thing".($type?" [$type]":"");
                    my $trackcode = state_track_codes('NSW',$track);
                    $trackcode = state_track_codes('ACT',$track) unless @$trackcode;
                    if ($thing eq "Meeting") {
                        $meetings{$day}{$meet} = {
                            races => [],
                            type => $type||"",
                            url => $div->find('a')->first->{href},
                            year => $year,
                            Mon => $Mon,
                            dom => $dom,
                            track => $track,
                            trackcode => $trackcode,
                            day => $day,
                            code => 'thoroughbred', # Racing NSW only lists these
                        };
                    }
                        
                    if ($thing eq "Races") {
                        foreach my $cell ($div->parent->find('td')->each) {
                            my $race = $cell->find('b')->first->text;
                            $race =~ s/^[A-Z]*//i;
                            push @{$meetings{$day}{$meet}{races}}, {number => $race, type => $type, meet => $meetings{$day}{$meet}, track => $track, trackcode => $trackcode, video => {}};
                        }
                    }
                }
            }
        }
        #
        # get data from the meeting pages
        #
        foreach my $meet (map values %$_, values %meetings) {
            my $meet_dom = _dom_get($E,URI->new_abs($meet->{url},$url));
            my ($zone,$tab) = ('Unknown','Unknown');
            if (my $mtype = $meet_dom->find('span[class="meeting-type"]')->first) {
                ($zone,$tab) = ($mtype->text =~ /Meeting Type: (.*?) \((TAB|Non-Tab) Meeting\)/i);
            }
            foreach my $race ($meet_dom->find('a[class="race-title-anchor"]')->each) {
                my ($r, $h,$m,$ampm) = ($race->text =~ /Race\s(\d+)\s\-\s(\d{1,2}):(\d\d)(AM|PM)/);
                my $time = timelocal_modern(0, $m, $h%12 + {AM => 0, PM => 12}->{$ampm}, $meet->{dom}, $Mon{$meet->{Mon}}, $meet->{year});
                my ($race_data) = grep {$_->{number} eq $r} @{$meet->{races}};
                $race_data->{time} = $time;
                $race_data->{zone} = $zone;
                $race_data->{tab} = ($tab and uc($tab) eq 'TAB') ? uc($tab) : 0;
                if (my $next = $race->parent->parent->parent->next) {
                    if (exists $next->{class} and $next->{class} eq "race-message") {
                        my $text = $next->text;
                        $text =~ s/^\s*//;
                        $text =~ s/\s*$//;
                        $race_data->{message} = $text;
                    } else {
                        foreach my $vid ($race->parent->parent->parent->find('div[class="race-video-result"]')->each) {
                            my $name = $vid->find('span')->first;
                            my $url = $vid->find('a')->first->{onclick};
                            $race_data->{video}->{$name->text} = $url;
                        }
                    }
                }
            }
        }
    } elsif ($CHECK eq 'racingqld') {
        my ($ty,$tm,$td) = map sprintf("%02d",$_),localtimefull(time); # today
        my ($yy,$ym,$yd) = map sprintf("%02d",$_),localtimefull(time - 86400); # yesterday
        my %day = (today => "$ty-$tm-$td", yesterday => "$yy-$ym-$yd");
        my $url = "https://www.racingqueensland.com.au/racing/full-calendar";
        my $dom = _dom_get($E,$url);
        my %dom = (today => $dom->find('div[class~="s-race-calendar__grid__col--today"]')->first);
        if (not $dom{today}) {
            do_exit("Can't find today on the calendar - this is what we got from $url:\n$dom")
        }
        $dom{yesterday} = $dom{today}->preceding('div[class~="s-race-calendar__grid__col"]')->last;
        $dom{yesterday} ||= $dom{today}->parent->previous->find('div[class~="s-race-calendar__grid__col"]')->last; # on mondays, yesterday is in the row above
        foreach my $day (grep defined $dom{$_}, reverse sort keys %dom) {
            my $container = $dom{$day};
            foreach my $code_container ($container->find('div[class="s-race-calendar__grid__events"]')->each) {
                my $code = $code_container->{'data-js-calendar-events-code'};
                foreach my $meet ($code_container->find('a[class="s-race-calendar__grid__event__location"]')->each) {
                    my $track = $meet->text;
                    my $trackcode = state_track_codes('QLD',$track);
                    my $data = $meetings{$day}{"$track-$code"} = {
                        track => $track,
                        trackcode => $trackcode,
                        type => "",
                        races => [],
                        day => $day,
                        url => $meet->{href},
                        info => {},
                        code => $code,
                    };
                    if ($meet->{href} =~ /(\d{4})(\d\d)(\d\d)$/) {
                        $data->{year} = $1;
                        $data->{mon} = $2-1;
                        $data->{Mon} = $Mon[$2-1],
                        $data->{dom} = $3;
                    }
                    #if (my $replay = $meet->parent->find('a[class="s-race-calendar__grid__event__view-replay"]')->first) {
                    #    $data->{url} = $replay->{href};
                    #}
                    if ($meet->parent->{class} =~ /abandoned/) {
                        $data->{info}->{abandoned} = 1;
                    }
                    if (my $info = $meet->parent->find('div[class="s-race-calendar__grid__event__info"]')->first) {
                        foreach my $i ($info->find('span')->each) {
                            $data->{info}->{$i->text} = 1;
                        }
                    }
                    $data->{type} = 'non-tab' if not exists $data->{info}->{TAB};
                    $data->{type} = 'trial' if exists $data->{info}->{Trial};
                    #push @extra, "$day [$code] ".$meet->text." $meet->{href} [$data->{type}]";
                }
            }
        }
        # get the API key
        my ($api_details) = grep {@$_} map {[$_->text =~ /^window.apiBaseUrl="(.*)";window.apiToken="(.*)";$/]} $dom->find('script')->each;
        my ($api_base,$api_key) = @$api_details;
        # get the schedule as JSON
        my $jsurl = "https://www.racingqueensland.com.au/RQWebServices/CalendarService.asmx/GetCurrentSchedule";
        my $result = _req($E, $jsurl);
        foreach my $day (sort keys %day) {
            my ($meet_data) = grep $_->{date} eq "$day{$day}T00:00:00", @{$result->[0]->{data}};
            foreach my $meet (@{$meet_data->{meetings}}) {
                my $track = $meet->{trackName};
                my $code = lc $meet->{racingCode};
                my $data = $meetings{$day}{"$track-$code"};
                if ($data->{url} =~ /(\d{4})(\d\d)(\d\d)$/) {
                    $data->{year} = $1;
                    $data->{mon} = $2-1;
                    $data->{Mon} = $Mon[$2-1],
                    $data->{dom} = $3;
                }
                if ($meet->{isTAB}) {
                    $data->{info}->{TAB} = 1;
                }
                #if ($meet->{class} =~ /abandoned/) {
                #    $data->{info}->{abandoned} = 1;
                #}
                $data->{type} = 'non-tab' if not exists $data->{info}->{TAB};
                $data->{type} = 'trial' if exists $data->{info}->{Trial};
                # check a different API for the stewards vision
                my $referer = URI->new($url);
                my $sub_api = {Thoroughbred => 'thoroughbreds'}->{$meet->{racingCode}} || lc($meet->{racingCode});
                my $api_url = "$api_base/api/$sub_api/meetings?date=$day{$day}&trackCode=".lc($meet->{trackCode});
                my $api_data = _req($E, URI->new($api_url), {}, {Authorization => "bearer $api_key", Referer => join('://',$referer->scheme,$referer->host)});
                $data->{type} = 'trial' if $api_data->{Barriertrial} or $api_data->{BarrierTrial};
                @{$data->{races}} = map {
                    ({
                        %$_,
                        number => $_->{RaceNumber},
                        time => jsepochtime($_->{StartTime})+($offset_hours-10)*3600, # QLD alway +10, we vary
                        distance => $_->{Distance},
                        meet => $data,
                        track => $track,
                        trackcode => $data->{trackcode},
                        video => {Full => !!$_->{VideoReplay}, Stewards => !!$_->{StewardsReplay}},
                        abandoned => !!$_->{IsAbandoned},
                        tab => $data->{info}->{TAB},
                        type => $data->{info}->{Trial} ? 'Trial' : '',
                    });
                } @{$api_data->{Races}};
            }
        }
    } elsif ($CHECK eq 'racingqldold') {
        my $url = "https://www.racingqueensland.com.au/racing/full-calendar";
        my $dom = _dom_get($E,$url);
        my %dom = (today => $dom->find('div[class~="s-race-calendar__grid__col--today"]')->first);
        if (not $dom{today}) {
            do_exit("Can't find today on the calendar - this is what we got from $url:\n$dom")
        }
        $dom{yesterday} = $dom{today}->preceding('div[class~="s-race-calendar__grid__col"]')->last;
        $dom{yesterday} ||= $dom{today}->parent->previous->find('div[class~="s-race-calendar__grid__col"]')->last; # on mondays, yesterday is in the row above
        foreach my $day (grep defined $dom{$_}, reverse sort keys %dom) {
            my $container = $dom{$day};
            foreach my $code_container ($container->find('div[class="s-race-calendar__grid__events"]')->each) {
                my $code = $code_container->{'data-js-calendar-events-code'};
                foreach my $meet ($code_container->find('a[class="s-race-calendar__grid__event__location"]')->each) {
                    my $track = $meet->text;
                    my $trackcode = state_track_codes('QLD',$track);
                    my $data = $meetings{$day}{$track} = {
                        track => $track,
                        trackcode => $trackcode,
                        type => "",
                        races => [],
                        day => $day,
                        url => $meet->{href},
                        info => {},
                        code => $code,
                    };
                    if ($meet->{href} =~ /(\d{4})(\d\d)(\d\d)$/) {
                        $data->{year} = $1;
                        $data->{mon} = $2-1;
                        $data->{Mon} = $Mon[$2-1],
                        $data->{dom} = $3;
                    }
                    #if (my $replay = $meet->parent->find('a[class="s-race-calendar__grid__event__view-replay"]')->first) {
                    #    $data->{url} = $replay->{href};
                    #}
                    if ($meet->parent->{class} =~ /abandoned/) {
                        $data->{info}->{abandoned} = 1;
                    }
                    if (my $info = $meet->parent->find('div[class="s-race-calendar__grid__event__info"]')->first) {
                        foreach my $i ($info->find('span')->each) {
                            $data->{info}->{$i->text} = 1;
                        }
                    }
                    $data->{type} = 'non-tab' if not exists $data->{info}->{TAB};
                    $data->{type} = 'trial' if exists $data->{info}->{Trial};
                    #push @extra, "$day [$code] ".$meet->text." $meet->{href} [$data->{type}]";
                }
            }
        }
        #
        # get data from the meeting pages
        #
        foreach my $day (keys %meetings) {
          foreach my $track (keys %{$meetings{$day}}) {
            my $meet = $meetings{$day}{$track};
            my $meet_dom = _dom_get($E,URI->new_abs($meet->{url},$url));
            my $last_time = 0;
            foreach my $race ($meet_dom->find('div[class~="c-race-listing__item"]')->each) {
                my $number = $race->find('div[class="c-race-listing__item-race-number"]')->first->all_text;
                my $details = $race->find('p[class="c-race-listing__item-race-location"]')->first->all_text;
                $details =~ s/\s+/ /g;
                my ($distance, $h, $m, $ampm) = ($details =~ /(\d*)m\s+\|\s+(\d+):(\d\d)(am|pm)/);
                my $abandoned = ($details =~ /Abandoned/);
                my $tz_save = $ENV{TZ};
                $ENV{TZ} = 'Australia/Brisbane';
                my $time = timelocal_modern(0, $m, $h%12 + {am => 0, pm => 12}->{$ampm}, $meet->{dom}, $meet->{mon}, $meet->{year});
                $ENV{TZ} = $tz_save if $tz_save;
                # handle meetings which go over midnight
                if ($time < $last_time) {
                    $time += 86400;
                }
                $last_time = $time;
                my $watch_link = $race->find('a')->grep(sub {$_[0]->text =~ /Watch/})->first;
                my $steward_link = $race->find('a')->grep(sub {($_[0]->{title}||'') =~ /Steward/})->first;
                push @{$meet->{races}}, {
                    number => $number,
                    time => $time,
                    distance => $distance,
                    details => $details,
                    meet => $meet,
                    track => $track,
                    trackcode => $meet->{trackcode},
                    video => {Full => !!$watch_link, Stewards => !!$steward_link},
                    tab => $meet->{info}->{TAB},
                    type => $meet->{info}->{Trial} ? 'Trial' : '',
                    abandoned => $abandoned,
                };

            }
          }
        }
    } elsif ($CHECK eq 'greyhoundsnsw') {
        my ($ty,$tm,$td) = map sprintf("%02d",$_),localtimefull(time); # today
        my ($yy,$ym,$yd) = map sprintf("%02d",$_),localtimefull(time - 86400); # yesterday
        my $url = "https://www.thedogs.com.au/calendar/week/$yy-$ym-$yd";
        my $dom = _dom_get($E,$url);
        my $meetings = $dom->find('a[class~="meeting"]');
        my %dom = (today => [$meetings->grep(sub {$_->{href} =~ /\/$ty-$tm-$td/})->each]);
        $dom{yesterday} = [$meetings->grep(sub {$_->{href} =~ /\/$yy-$ym-$yd/})->each];
        my %videos = ();
        foreach my $day (reverse sort keys %dom) {
            my @ymd = @{($day eq 'today' ? [$ty,$tm,$td] : [$yy,$ym,$yd])};
            foreach my $meet (@{$dom{$day}}) {
                my $track = $meet->find('div[class="meeting__header-name"]')->first->text;
                my $trackcode = state_track_codes('NSW',$track);
                my $data = $meetings{$day}{$track} = {
                    track => $track,
                    trackcode => $trackcode,
                    type => "",
                    code => 'greyhound',
                    day => $day,
                    url => $meet->{href},
                    info => {},
                    races => [],
                };
                @$data{qw{year mon Mon dom}} = ($ymd[0],$ymd[1]-1,$Mon[$ymd[1]-1],$ymd[2]);
                if (my $info = $meet->find('div[class="meeting__header-info"]')->first) {
                    foreach my $div ($info->find('div[class^="meeting__header-info-"]')->each) {
                        my $key = substr($div->{class},length("meeting__header-info-"));
                        my $val = $div->text;
                        if (uc($val) eq 'NON-TAB') {
                            $data->{info}->{non_tab} = 1;
                        } else {
                            $data->{info}->{$key} = join " + ", grep defined, $data->{info}->{$key}, $val;
                        }
                    }
                }
            }
            #
            # get data from the video pages
            #
            my $video_dom = _dom_get($E, "https://www.thedogs.com.au/videos/replays/$ymd[0]-$ymd[1]-$ymd[2]");
            foreach my $video ($video_dom->find('a[class="video-card"]')->each) {
                my $title = $video->find('div[class="video-card__title"]')->first;
                next unless $title;
                my ($track, $race) = ($title->text =~ /^(.*)\sRace\s(\d+)$/);
                my $time = $video->find('formatted-time')->grep(sub {$_->{'data-format'} eq 'time_24'})->first;
                $videos{$day}{$track}{$race} = {time => $time->{'data-timestamp'}, href => $video->{href}};
            }
        }
        #
        # get data from the meeting pages
        #
        foreach my $day (keys %meetings) {
          foreach my $track (keys %{$meetings{$day}}) {
            my $meet = $meetings{$day}{$track};
            my $meet_dom = _dom_get($E,URI->new_abs($meet->{url},$url));
            foreach my $race ($meet_dom->find('a[class~="race-box"]')->grep(sub {$_->{class} !~ /meeting-header/})->each) {
                my $info = {};
                my $abandoned = 0;
                my $number = substr($race->find('div[class="race-box__number"]')->first->text,1);
                my $caption = $race->find('div[class="race-box__caption"]')->first;
                if (my @captions = map $_->text, $caption->find('span')->each) {
                    if (grep "ABD" eq $_, @captions) {
                        $info->{abandoned} = 1;
                        $abandoned = 1;
                    }
                }
                if (exists $videos{$meet->{day}}{$meet->{track}}{$number}) {
                    my $vid_data = $videos{$meet->{day}}{$meet->{track}}{$number};
                    push @{$meetings{$day}{$track}{races}}, {tab => !$meet->{info}->{non_tab}, meet => $meet, track => $track, trackcode => $meet->{trackcode}, number => $number, info => $info, abandoned => $abandoned, href => $race->{href}, time => $vid_data->{time}, type => "", video => {Full => $vid_data->{href}}};
                    next;
                }
                my $race_dom = _dom_get($E,URI->new_abs($race->{href},$url));
                my $time = $race_dom->find('formatted-time')->grep(sub {exists $_->{'data-timestamp'}})->first;
                if (my $epoch = $time->{'data-timestamp'}) {
                    $time = $epoch;
                } else {
                    my ($h,$m) = split /:/,$time->text; # 24 hour
                    $time = timelocal_modern(0,$m,$h,$meet->{dom}, $meet->{Mon}, $meet->{year});
                }

                my $video = $race_dom->find('a[class~="race-header__media__item--replay"]')->first;
                push @{$meetings{$day}{$track}{races}}, {tab => !$meet->{info}->{non_tab}, meet => $meet, track => $track, trackcode => $meet->{trackcode}, number => $number, info => $info, abandoned => $abandoned, href => $race->{href}, time => $time, type => "", video => {Full => $video && $video->{href}}};

            }
          }
        }
    }

    &debug(16, Dumper({Meetings => \%meetings}));

    my %select = map {($_ => 1)} qw(trial race_vision steward_vision future abandoned non_tab);
    if (my $select = $P->opts->select) {
        $select{$_} = 0 foreach keys %select;
        foreach my $s (split /,/,$select) {
            $select{$s} = 2; # 2>1 for manual selection, may not use this yet
        }
    }
    if (my $unselect = $P->opts->unselect) {
        foreach my $u (split /,/,$unselect) {
            $select{$u} = 0;
        }
    }

    my $akamai_ftp;
    # check we have everything uploaded which should be there
    foreach my $race_data (sort {($a->{time}//0) <=> ($b->{time}//0)} map @{$_->{races}}, map values %$_, values %meetings) {
        my $meet = $race_data->{meet};
        my $desc = "$race_data->{track} # $race_data->{number} ".($race_data->{time} ? localtime($race_data->{time}) : "<no time>");
        my @missing = ();
        my $trial = lc($race_data->{type}||'') eq 'trial';
        if ($race_data->{type}) {
            $desc = "[$race_data->{type}] $desc";
        }
        if ($meet->{code} and $meet->{code} eq 'thoroughbred' and ( # if it's throughbred and 
                $race_data->{tab} # it's TAB
                and not $trial # and not a trial
            )) {
            push @missing, "Steward Vision" if $select{steward_vision} and not $race_data->{video}->{Stewards};
        }
        push @missing, "Race Vision" if $select{($trial ? "trial" : "race_vision")} and not $race_data->{video}->{Full}; # and $race_data->{video}->{"Last 400m"};
        if (@missing) {
            $desc .= " missing ".join " + ",@missing;
        }
        my $state = OK;
        if (not $race_data->{tab} and not ($race_data->{type} and lc($race_data->{type}) eq 'trial')) {
            next unless $select{non_tab};
            $desc .= ' [NON TAB]';
        } elsif ($race_data->{abandoned}) {
            next unless $select{abandoned};
            $desc .= ' [Abandoned]';
        } elsif (not defined $race_data->{time}) {
            next unless $select{future};
            $desc .= ' [No Time]';
        } elsif ($race_data->{time} > time) {
            next unless $select{future};
            $desc .= ' [FUTURE]';
        } elsif ($race_data->{message}) {
            $desc .= " [$race_data->{message}]";
        } elsif (@missing) {
            my $timer_start = $race_data->{time};
            if ((@missing == 1 and $missing[0] eq "Steward Vision") and # only problem is stewards and
                #$CHECK eq 'racingqld' or # queensland or
                ($CHECK eq 'racingnsw' and $race_data->{zone} eq 'Metro') ) { # metro nsw
                if (not grep {$_->{video}->{Stewards}} @{$meet->{races}}) { # and no stewards have been sent for this meeting
                    $timer_start = $meet->{races}->[-1]->{time}; # don't alert until the end of the last race
                    $desc .= " [Not late until last race or first upload]";
                }
            }
            if ($P->opts->critical and $timer_start < time - $P->opts->critical) {
                $state = CRITICAL;
            } elsif ($P->opts->warning and $timer_start < time - $P->opts->warning) {
                $state = WARNING;
            }

            #
            # if we are about to alert, check that there isn't an explanation in gitlab
            #
            if ($state) { # OK == 0, everything else true
                #
                # check gitlab once only
                #
                if (not $GITLAB) {
                    $GITLAB = {yesterday => [], today => []};
                    my ($yy,$ym,$yd) = localtimefull(time - 86400); # yesterday
                    my ($ty,$tm,$td) = localtimefull(time); # today
                    my $issue = &gitlab_req( "api/v4/projects/153/issues", {} );
                    foreach my $i (@$issue) {
                        my $title = $i->{title};
                        # process multi-race title
                        my @title_words = split /\s+/,$title;
                        my @trackwords = ();
                        foreach my $word (@title_words) {
                            if (my ($before, $yyyy,$mm,$dd,$tc,$code,$rr,$st, $after) = ($word =~ /^(.*)(\d{4})(\d\d)(\d\d)(\w{3})([RTG])(\d\d)(S|T|)(.*?)$/)) {
                                my ($y,$m,$d,$r) = map $_+0, $yyyy,$mm,$dd,$rr;
                                my $day;
                                if ($y == $yy and $m == $ym and $d == $yd) {
                                    $day = 'yesterday';
                                } elsif ($y == $ty and $m == $tm and $d == $td) {
                                    $day = 'today';
                                } else {
                                    # next;
                                    $day = "$yyyy$mm$dd";
                                    $GITLAB->{$day} ||= [];
                                }
                                push @{$GITLAB->{$day}}, {
                                    yyyy => $yyyy,
                                    mm => $mm,
                                    dd => $dd,
                                    racingcode => $code,
                                    trackcode => $tc,
                                    rr => $rr,
                                    st => $st,
                                    racecode => "$yyyy$mm$dd$tc$code$rr$st",
                                    r => $r,
                                    y => $y,
                                    m => $m,
                                    d => $d,
                                    body => $i->{description},
                                    title => $i->{title},
                                    weburl => $i->{weburl},
                                    trackwords => \@trackwords,
                                };
                            } else {
                                push @trackwords, $word;
                            }
                        }
                    }
                    &debug(16,Dumper({gitlab => $GITLAB}));
                }
            }
            #
            # check if we have gitlab issue excusing this alert
            #
            # work out what we are looking for - trial/steward/plain
            my @missing_codes = map {
                my $missing = undef;
                if ($_ eq 'Race Vision') {
                    if ($race_data->{type} and $race_data->{type} =~ /trial/i) {
                        $missing = 'T';
                    } else {
                        $missing = '';
                    }
                } elsif ($_ eq 'Steward Vision') {
                    $missing = 'S';
                } else {
                    $P->add_message(CRITICAL, "Don't know how to handle missing '$_' for $race_data->{track} $race_data->{number} $race_data->{meet}->{day}");
                    $missing = 'X';
                }
                $missing;
            } @missing;
            # potential matches
            my @track_matches = grep {
                my $g = $_;
                (not grep {my $tw = $_; not grep {lc($tw) eq lc($_)} @{$g->{trackwords}}} split /\s+/, $race_data->{track}) and # all parts of track name are mentioned
                $g->{r} == $race_data->{number}
            } @{$GITLAB->{$meet->{day}}};
            my (@still_missing, @excused, @still_missing_codes) = ();
            foreach my $m (0..$#missing) {
                my $missing = $missing[$m];
                my $st = $missing_codes[$m];
                if (my @match = grep {lc($st) eq lc($_->{st})} @track_matches) {
                    push @excused, @match;
                } else {
                    push @still_missing, $missing;
                    push @still_missing_codes, $st;
                }
            }
            if (not @still_missing) {
                $state = OK;
            }
            if (@excused) {
                $desc .= " - gitlab says: ".join(" + ", map "'$_->{title}' => '$_->{body}'", @excused);
            }
            #
            # check if file has been uploaded to akamai
            #
            if ($state) {
                my $uri = URI->new($P->opts->sdakamaiurl);
                if (not $akamai_ftp) {
                    $akamai_ftp = Net::FTP->new($uri->host, Port => $uri->port||21, Debug => $DEBUG&32, Timeout => 20);
                    $akamai_ftp->login($uri->user,$uri->password);
                    if ($akamai_ftp->error) {
                        do_exit("Could not login to FTP URL '$uri': ".$akamai_ftp->message);
                    }
                    #$akamai_ftp->passive(1);
                }
                foreach my $m (0..$#still_missing) {
                    my $missing = $still_missing[$m];
                    my $st = $still_missing_codes[$m];
                    my @racecodes = map sprintf("%04d%02d%02d%3s%1s%02d%s", $meet->{year}, $Mon{$meet->{Mon}}+1, $meet->{dom}, $_, {thoroughbred => 'R', greyhound => 'G', harness => 'T'}->{$meet->{code}}, $race_data->{number}, $st), @{$meet->{trackcode}};
                    my @found = ();
                    my $dir = sprintf "%sRace_Replay/%04d/%02d/", $uri->path, $meet->{year}, $Mon{$meet->{Mon}}+1;
                    $akamai_ftp->cwd($dir);
                    foreach my $racecode (@racecodes) {
                        push @found, $akamai_ftp->dir("${racecode}_V.mp4");
                    }
                    if (@found) {
                        my @found_details = map {
                            my ($perm, $something, $user, $group, $bytes, $Mon, $mday, $time, @filename) = split;
                            my ($h,$m) = map $_+0, split /:/,$time;
                            my $epoch = timegm_modern(0, $m, $h, $mday, $Mon{$Mon},$meet->{year});
                            my $megabytes = int($bytes/1024/1024);
                            {
                                perm => $perm,
                                user => $user,
                                group => $group,
                                bytes => $bytes,
                                megabytes => $megabytes,
                                Mon => $Mon,
                                day => $mday,
                                time => $time,
                                epoch => $epoch,
                                mins_ago => int((time - $epoch)/60),
                                dir => $dir,
                                filename => join(" ",@filename),
                            };
                        } @found;
                        my $found = join " + ", map {"$_->{dir}$_->{filename} ($_->{megabytes} MB, $_->{mins_ago} minutes ago)"} @found_details;
                        $state = OK;
                        push @extra, "INFO: Found $found looking for $desc: ".join(" + ",@racecodes);
                        $desc .= " - Found '$found' on SD Akamai";
                    } elsif (@racecodes) {
                        $desc .= " - Not found ".join("/",@racecodes)." on SD Akamai";
                    } else {
                        $desc .= " - Not found on SD Akamai (add '$race_data->{track}' to %EXTRA_TRACK_CODES?)";
                    }
                }
            }
        }
        if (lc($race_data->{type}||'') eq 'trial') {
            next unless $select{trial};
        } elsif (not grep {$select{$_}} qw(race_vision steward_vision)) {
            next;
        }
        # TODO match up with ai2 date and check for abandoned race etc.
        #$P->add_message($state, $desc);
        push @interesting, {_check_state => $state, desc => $desc, do_not_count => !$state};
    }
} elsif ($CHECK eq 'skyracing') {
    $E->timeout(180); # this web server can be really slow
    my ($ty,$tm,$td) = map sprintf("%02d",$_),localtimefull(time - 21600); # today starts at 6am
    my ($yy,$ym,$yd) = map sprintf("%02d",$_),localtimefull(time - 21600 - 86400); # yesterday started at 6am
    my $url = "https://replays:skyracing123\@old.skyracing.com.au/includes/raceengine/replayeval.php";
    my %dom = (today => _dom_get($E,sprintf "%s?date=%02d%%2F%02d%%2F%02d",$url,$td,$tm,$ty), yesterday => _dom_get($E,sprintf "%s?date=%02d%%2F%02d%%2F%02d",$url,$yd,$ym,$yy));
    my %uploads = ();
    foreach my $day (reverse sort keys %dom) {
        $uploads{$day} = {};
        my $dom = $dom{$day};
        foreach my $row ($dom->find('tr[bgcolor="#FFFFFF"]')->each) {
            my @cell = $row->find('td')->each;
            my $racecode = $cell[4] ? $cell[4]->text : '<not found>';
            my $trial = !! ($racecode =~ /T$/);
            next if $trial; # FIXME process trials
            my $data = $uploads{$day}{$racecode} = {};
            if (my $img = $cell[5] && $cell[5]->find('img')->first) {
                ($data->{status}) = $cell[5]->find('img')->first->{src} =~ /(\w+)\.svg\.png$/;
            }
            my @links = ();
            if ($cell[8]) {
                @links = map {($_->{src} =~ /\/race_(\w+)\.png$/)[0]} $cell[8]->find('img')->each;
            }
            $data->{$_} = 1 foreach @links;
            if (not grep {($data->{status}||'') eq $_} 'Tick_green_modern_2', 'active') {
                my ($h,$m) = split /:/,$cell[3]->text;
                my $state = OK;
                my $desc = "$racecode ($h:$m $day) not OK, have ".(scalar(@links)?join(" + ",@links):'no files');

                my $timer_start = timelocal_modern(0,$m,$h,$td,$tm-1,$ty);
                if ($day eq 'yesterday') {
                    $timer_start -= 86400; # yesterday's had 24 more hours
                }
                $timer_start += 3600*24 if $h < 6; # races before 6am are from yesterday

                if ($timer_start > time) {
                    $desc .= " [future]";
                    next;
                }

                if ($P->opts->critical and $timer_start < time - $P->opts->critical) {
                    $state = CRITICAL;
                } elsif ($P->opts->warning and $timer_start < time - $P->opts->warning) {
                    $state = WARNING;
                }

                # check gitlab
                if (not $GITLAB) {
                    $GITLAB = &gitlab_req( "api/v4/projects/153/issues", {} );
                }
                if (my @match = grep {$_->{title} =~ /$racecode/i} @$GITLAB) {
                    $state = OK;
                    $desc .= " - gitlab says: ".join(" + ", map "'$_->{title}' => '$_->{description}'", @match);
                }

                push @interesting, {_check_state => $state, desc => $desc, do_not_count => !$state};
            }
        }
    }
    &debug(16,Dumper({uploads => \%uploads}));

} else {
    do_exit("Unknown Check '$CHECK'");
}

if (grep $CHECK eq $_, qw(abandoned weird upcoming)) {
    if (@interesting) {
        # summarise
        my %meet = ();
        foreach my $racecode (sort map $_->{racecode}, @interesting) {
            my $meet = substr($racecode,8,4);
            my $race = substr($racecode,12) + 0;
            # build a list of ranges
            if (my $before = $meet{$meet}) {
                if ($before->[-1] eq $race-1) {
                    $before->[-1] = join '-',$race-1,$race;
                } elsif ($before->[-1] =~ /^(\d+\-)(\d+)$/ and $2 eq $race-1) {
                    $before->[-1] = $1.$race;
                } else {
                    push @$before, $race;
                }
            } else {
                $meet{$meet} = [$race];
            }
        }
        my @list = ();
        foreach my $meet (sort keys %meet) {
            push @list, $meet.join(',',@{$meet{$meet}});
        }
        my $desc = {abandoned => "Abandonments"}->{$CHECK} || ucfirst($CHECK);
        $desc .= " (Greenwash $green)"
            if $green;
        $P->add_message(OK, "$desc: ". join "; ", @list);
    }
}

#
# Green Note processing - downgrade any matches with given keywords in notes
#
if (my $greennotes = $P->opts->greennotes) {
    my @green = split /,/,$greennotes;
    foreach my $e (@interesting) {
        next unless $e->{_check_state};
        &debug(16, Dumper({greennote => $e}));
        my $match = "";
        foreach my $itm_id (grep {$_} map {$e->{recording}->{"Viz${_}AssetId"}} qw(Raw Web Archive)) {
            my $md = &viz_md($itm_id);
            next unless $md;
            foreach my $g (@green) {
                foreach my $field ('sr.AddNotes', 'sr.Notes') {
                    next unless exists $md->{$field} and length $md->{$field};
                    if ($md->{$field} =~ /($g)/i) {
                        $match ||= $1;
                    }
                }
            }
        }
        if ($match) {
            $e->{_check_state} = OK;
            $e->{_do_not_count} = $match;
            $e->{_comment} = ($e->{_comment} ? "$e->{_comment} " : "")."('$match' found in Notes)";
        }
    }
}

my $count = scalar grep {!$_->{do_not_count}} @interesting;
$perfdata{uc($CHECK)} = 0;
if (@interesting) {
    $perfdata{uc($CHECK)} = $count unless $green;
    my $s = $count == 1 ? '' : 's';
    my $state = OK;
    if (not $green) {
        $state = WARNING if defined $P->opts->warning and $count >= $P->opts->warning;
        $state = CRITICAL if defined $P->opts->critical and $count >= $P->opts->critical;
    }
    $P->add_message($state, "$count $CHECK race$s in AI2".($green ? " (in Greenwash period $green)" : ""));
    foreach my $n (1..scalar(@interesting)) {
        my $e = $interesting[$n-1];
        my $feature = $e->{recording}->{Manual} ? ' FEAT ' : ' ';
        $P->add_message($green ? OK : $e->{_check_state}||OK, $e->{desc} || sprintf "%s %4s:%s%s %s", map {$_ // '?'} $check_desc{$CHECK}||ucfirst($CHECK).($green ? " (Greenwash $green)" : ""), "#$n", $feature, &race_string($e), $e->{_comment}||"");
        &debug(16, Dumper({race => $e, index => $n}));
    }
} else {
    $P->add_message(OK, "No $CHECK Races");
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
