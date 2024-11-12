#!/usr/bin/perl -w

#
# Check for Viz One items from the database which are problematic
#
use constant VERSION => '1.0';
# 1.0 Woody 2023-06-06

use strict;
use Monitoring::Plugin;
use Text::CSV;
use Data::Dumper;

my $P = Monitoring::Plugin->new(
        usage => "Usage: %s -C {TXnoAudio,TXmono} [-w|--warn|--warning <count>] [-c|--crit|--critical <count>] [-s|--txstatus {ready,not-ready,undecided}] [-H|--age <hours>] [-o|--older <hours>] [-d|--debug <level>]",
        version => VERSION,
        blurb   => "Viz One database checks for problematic items of various types",
        shortname => ' ',
);

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
        spec    => "check|C=s",
        help    => "Which check to run",
        required=> 1,
);

$P->add_arg(
        spec    => "age|H=i",
        help    => "Limit the search to items updated in the last X hours",
);

$P->add_arg(
        spec    => "mediaage|m=i",
        help    => "Limit the search to mobs updated in the last X hours",
);

$P->add_arg(
        spec    => "older|o=f",
        help    => "Limit the search to items updated previous to the last X hours",
);

$P->add_arg(
        spec    => "mediaolder|b=f",
        help    => "Limit the search to mobs created previous to the last X hours",
);

$P->add_arg(
        spec    => "txstatus|s=s",
        help    => "Limit the search to items with this tx-status (e.g. ready, not-ready, undecided)",
);

$P->add_arg(
        spec    => "warning|warn|w=i",
        help    => "Number of matching items to trigger a warning",
);

$P->add_arg(
        spec    => "critical|crit|c=i",
        help    => "Number of matching items to trigger a critical",
);


$P->getopts;

my $CHECK = $P->opts->check;

$DEBUG = $P->opts->debug if $P->opts->debug;

my $VERBOSE = $P->opts->verbose;

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

sub adt_csv { # run an adt query and get the output as a list (rows) of lists (columns)
    my $sql = shift;

    my @rows = ();
    my $CSV = Text::CSV->new({quote_char => '"', allow_whitespace => 1, eol => $/});

    my $cmd = qq|PERL5LIB=/opt/ardome/lib/perl:/opt/demctl/lib/perl:/opt/ardendo-install/lib/perl:/opt/scamp/lib/perl:/opt/oms/lib/perl:\$PERL5LIB /opt/ardome/bin/adt --data-only -F csv --csv=2 "$sql"|;
    my $response = join $/, command_lines($cmd);

    if ($VERBOSE) {
        push @extra, "INFO: SQL '$sql'", map "INFO:  - response: $_", split /\w*\n\w*/, $response;
    }

    return if $response =~ /No rows/;

    my $pointer = \$response;
    open my $adt, "<", $pointer;
    while (my $row = $CSV->getline($adt)) {
        push @rows, $row;
    }
    close $adt;
    return @rows;
}

my %CHECKS = (
    TXnoAudio => {
        doc => "Check for txco items with no audio",
        where => "itm.itm_material_type= 'txco' and itm.itm_id in (select mob_itm_id from ardome.mob where mob_fft_id=2 and mob_audio_tracks is null)",
        desc => "TXCO with no audio",
    },
    TXmono => {
        doc => "Check for txco items with mono audio",
        where => "itm.itm_material_type= 'txco' and itm.itm_id in (select mob_itm_id from ardome.mob where mob_fft_id=2 and mob_audio_tracks = 1)",
        desc => "TXCO with mono audio",
    },
    PRGSnotTXready => {
        doc => "Check for non-filler program segment items with media created last 24 hours which are not TX Ready",
        where => "itm.itm_material_type='txco' and itm.itm_category='prgs' and itm.itm_tx_status != 'ready' and itm.itm_title not like 'Fillers - %' and itm.itm_title not like ' -  - %'",
        desc => "New Program Segments not TX Ready",
    },
    AI2dartRaw => {
        doc => "Check for dart raw recordings which should have been deleted",
        where => "itm.itm_material_type='ring'",
        desc => "Old Race Ingest",
    },
    FeatureRaceIngests => {
        doc => "Check for dart race ingests which have been cut by autoingest",
        where => "itm.itm_material_type='ring' and 'SYSTEM+autoingest2' in (select dest_itm.itm_create_by from ardome.item dest_itm where dest_itm.itm_delete_ts is NULL and dest_itm.itm_id in (select dest_mob.mob_itm_id from ardome.mob dest_mob where dest_mob.mob_id in (select met_dest_mob_id from ardome.media_tracking where met_source_mob_id in (select src_mob.mob_id from ardome.mob src_mob where src_mob.mob_itm_id = itm.itm_id))))",
        desc => "Old Feature Race Ingest",
    },
    RaceArchiveClips => {
        doc => "Check for dart raw recordings which have not been cut by autoingest",
        where => "itm.itm_material_type='ring' and 'SYSTEM+autoingest2' not in (select dest_itm.itm_create_by from ardome.item dest_itm where dest_itm.itm_delete_ts is NULL and dest_itm.itm_id in (select dest_mob.mob_itm_id from ardome.mob dest_mob where dest_mob.mob_id in (select met_dest_mob_id from ardome.media_tracking where met_source_mob_id in (select src_mob.mob_id from ardome.mob src_mob where src_mob.mob_itm_id = itm.itm_id))))",
        desc => "Uncut Race Ingest",
    },
    OldRaceIngest => {
        doc => "Check for dart raw recordings which have not been cut by autoingest",
        where => "itm.itm_material_type='ring'",
        desc => "Uncut Race Ingest",
    },
);

sub items_where {
    my $check = shift;
    my $where = $CHECKS{$check}{where};
    $CHECKS{$check}{sql} = qq{select itm.itm_id as id, itm.itm_title as title from ardome.item itm where $where};
    &items_sql($check);
}

sub items_sql {
    my $check = shift;
    my $sql = $CHECKS{$check}{sql};

    my ($select, $where) = ($sql =~ /^(.*?)\swhere\s(.*)$/i);
    $select = $sql if not $where;
    my @where = ($where);

    my ($distinct, $cols) = ($select =~ /select(\s+distinct|)\s+(.*)\s+from/i);

    my @cols = map {/^(.*)\s+as\s+(.*)$/i ? $2 : $_} split /\s*,\s*/, $cols;
    push @where, "itm.itm_delete_ts IS NULL";

    if (my $hours = $P->opts->age) {
        my $minutes = $hours * 60;
        push @where, "itm.itm_update_ts > NOW() - CURRENT TIMEZONE - $minutes minutes";
    }

    if (my $hours = $P->opts->mediaage) {
        my $minutes = $hours * 60;
        push @where, "itm.itm_id in (select mob_itm_id from ardome.mob where mob_fft_id=2 and mob_create_ts > NOW() - CURRENT TIMEZONE - $minutes minutes)";
    }

    if (my $hours = $P->opts->older) {
        my $minutes = $hours * 60;
        push @where, "itm.itm_update_ts < NOW() - CURRENT TIMEZONE - $minutes minutes";
    }

    if (my $hours = $P->opts->mediaolder) {
        my $minutes = $hours * 60;
        push @where, "itm.itm_id in (select mob_itm_id from ardome.mob where mob_fft_id=2 and mob_create_ts < NOW() - CURRENT TIMEZONE - $minutes minutes)";
    }


    my $tx_status = $P->opts->txstatus;
    if (defined $tx_status) {
        if ($tx_status) {
            push @where, "itm.itm_tx_status = '$tx_status'";
        } else {
            push @where, "itm.itm_tx_status IS NULL";
        }
    }

    $where = join " and ", map "($_)", @where;

    my @csv = adt_csv("$select where $where");

    $perfdata{$check} = $perfdata{count} = scalar @csv;

    my $desc = exists $CHECKS{$check}{desc} ? $CHECKS{$check}{desc} : "matches $check";
    if (@csv) {
        my $state = OK();
        $state = WARNING() if defined $P->opts->warning and $P->opts->warning <= @csv;
        $state = CRITICAL() if defined $P->opts->critical and $P->opts->critical <= @csv;

        $P->add_message($state, scalar(@csv)." Item".($#csv?'s':'')." match '$desc'");
        foreach my $csv (@csv) {
            my %data = ();
            @data{@cols} = @$csv;
            $P->add_message($state, "Item $data{id} '$data{title}' $desc");
        }
    } else {
        $P->add_message(OK, "No Items match '$desc'");
    }
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

# run the check code
if (exists $CHECKS{$CHECK}{code}) {
    $CHECKS{$CHECK}{code}->($CHECK);
} elsif (exists $CHECKS{$CHECK}{where}) {
    &items_where($CHECK);
} elsif (exists $CHECKS{$CHECK}{sql}) {
    &items_sql($CHECK);
} else {
    delete $CHECKS{$CHECK};
    do_exit("Don't know how to run check '$CHECK', did you mean: ".join(" / ",sort keys %CHECKS));
}

do_exit();
