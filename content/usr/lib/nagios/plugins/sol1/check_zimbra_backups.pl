#!/usr/bin/perl -w

# Zimbra per-account backup check.
use constant VERSION => '1.5';
# 1.5 based on shell script and backup script
# Woody 2022-12-01
# - change to perl
# Vesion 1.4 update by Matt
# - Add file checks
# - Add check boilerplate
# Vesion 1.3 rewritten by Oli
# Setup cron job to list accounts existing at 3AM for each server.
# Compares the backed up accounts against that list, rather than a new list each time which potentially contains new accounts
#       Does a remote check by default (relies on the host running this script having ssh keys to zimbra@remote_host)
#       Does a local check if the server is set as "localhost"
#59 02 * * * zimbra zmprov -l gaa -s subsoil.colo.sol1.net > /tmp/originalmailboxes.txt

use strict;
use Monitoring::Plugin;
use Time::Local qw(timelocal);

my $P = Monitoring::Plugin->new(
        usage   => "Usage: %s [-H|--host <zimbra hostname, default localhost>] [-f|--filter <regex to ignore usernames] [-d|--debug <level>] [-w|--warning-age <days>] [-c|--critical-age <days>] [-v]",
        version => VERSION,
        blurb   => "Checks which zimbra accounts have a current backup",
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

sub SU { return qq{su zimbra -l -c "$_[0]"}; }

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
        spec    => "host|H=s",
        help    => "Zimbra host, (default localhost)",
        default => "localhost",
);

$P->add_arg(
        spec    => "filter|f=s",
        help    => "Account filter regex for accounts to exclude, e.g. .archive\$",
);

$P->add_arg(
        spec    => "warningage|w=s",
        help    => "Warning age for account backups to be under (days)",
);

$P->add_arg(
        spec    => "criticalage|c=s",
        help    => "Critical age for account backups to be under (days)",
);

$P->getopts;

$DEBUG = $P->opts->debug if $P->opts->debug;

my $FILTER = $P->opts->filter;

my $WARNING_DAYS = $P->opts->warningage;
my $CRITICAL_DAYS = $P->opts->criticalage;
my $VERBOSE = $P->opts->verbose;

#
# this bit copied from selectivebackup.pl; could be in a module
#
my %state = ();

sub command_lines { # run a command and get the output as a list of strings
        my $cmd = &SU(shift);
        my @lines = ();
        open CMD, "$cmd|" or return;
        while (<CMD>) {
                chomp;chomp;
                push @lines,$_;
        }
        close CMD;
        return @lines;
}


sub update_state {
        # first get a list of users, but not the archive users
        $state{all_users} = [&command_lines('/opt/zimbra/bin/zmprov -l gaa')];
        $state{filtered_users} = [grep {not $FILTER or not /$FILTER/} @{$state{all_users}}];

        # work out when the last backup was
        my @zmbackupquery = &command_lines('/opt/zimbra/bin/zmbackupquery -v');
        my %info = ();
        foreach (@zmbackupquery) {
                if (/^Label:\s+(.*)$/) {
                        %info = (Label => $1);
                } elsif (/^(Type|Status|Started|Ended|Redo log sequence range|Number of accounts):\s+(.*)$/) {
                        $info{$1} = $2;
                } elsif (/Accounts:/) {
                        # fix the times into epoch
                        foreach my $time_info (qw(Started Ended)) {
                                my $time_string = $info{$time_info};
                                if ($time_string and $time_string =~ /^(\w\w\w), (\d{4})\/(\d\d)\/(\d\d)\s(\d\d):(\d\d):(\d\d).(\d+) (\w+)$/) {
                                        my $epoch_time = timelocal($7,$6,$5,$4,$3-1,$2);
                                        $info{$time_info} = $epoch_time + "0.$8";
                                }
                        }
                        # if there is no end time (e.g. ongoing backup) use the start time
                        $info{Ended} ||= $info{Started};
                } elsif (/^\s\s(.*)@(.*): (.*)$/) { # account
                        if ($3 eq 'completed') {
                                $state{completed}{"$1\@$2"} ||= {%info}; # assume newest backups are returned first
                        }
                } elsif (not $_) { # blank line
                        # ignore
                } else {
                        #warn "Ignoring line $_";
                }
        }
        $state{not_backed_up_filtered_users} = [
                grep {
                        not exists $state{completed}{$_}
                } @{$state{filtered_users}}
        ];
        $state{oldest_backups_filtered_users} = [
                sort {  
                        $state{completed}{$a}{Ended} <=> $state{completed}{$b}{Ended}
                } grep {
                        if (exists $state{completed}{$_} and not defined $state{completed}{$_}{Ended}) {
                                print "$_ is complete but has no End: ".join(" ",%{$state{completed}{$_}});
                        }
                        exists $state{completed}{$_}
                } @{$state{filtered_users}}
        ];
        foreach my $user (keys %{$state{completed}}) {
                $state{complete_age}{$user} = $state{completed}{$user}{Ended}
        }
}

#
# end of copied bit from selectivebackup.pl
#

&update_state();

my @all_accounts = @{$state{filtered_users}};
$perfdata{accounts} = scalar(@all_accounts);

# record minimum, average, and maximum age of backups
$perfdata{total_days} = 0;
foreach my $acct (@{$state{filtered_users}}) {
	my $complete_time = $state{complete_age}{$acct};
	if (not $complete_time) {
		push @extra, "   INFO: Account $acct has never been backed up completely, ignoring for stats";
		next;
	}
	my $age = (time - $state{complete_age}{$acct})/24/60/60;
	$perfdata{oldest_days} = $age if not exists $perfdata{oldest_days} or $age > $perfdata{oldest_days};
	$perfdata{newest_days} = $age if not exists $perfdata{newest_days} or $age < $perfdata{newest_days};
	$perfdata{total_days} += $age;
}
$perfdata{average_days} = $perfdata{total_days} / $perfdata{accounts};
$perfdata{$_} = sprintf "%.2f", $perfdata{$_} foreach qw{oldest_days newest_days total_days average_days};

my $filter_string = $FILTER ? " (not matching filter /$FILTER/)" : "";

my @not_backed_up = @{$state{not_backed_up_filtered_users}};
$perfdata{not_backed_up} = scalar(@not_backed_up);
if (@not_backed_up) {
	# check that the accounts which aren't backed up are not new
	my ($s,$m,$h,$D,$M,$Y) = gmtime(time - 24 * 3600);
	my $timestamp = sprintf "%04d%02d%02d%02d%02d%02d", $Y+1900, $M+1, $D,$h,$m,$s;
	my (@old,@new) = ();
	foreach my $acct (@not_backed_up) {
		my ($create) = map {/^zimbraCreateTimestamp:\s(\d*)Z$/; $1} grep {/^zimbraCreateTimestamp:/} &command_lines("/opt/zimbra/bin/zmprov ga $acct zimbraCreateTimestamp");
		if (not $create) {
			push @extra, "   INFO: Account $acct has not been backed up yet but has not been created either?";
		} elsif ($create > $timestamp) {
			push @new, $acct;
		} else {
			push @old, $acct;
		}
	}

	if (@old) {
		$P->add_message(CRITICAL, scalar(@old).'/'.scalar(@all_accounts)." accounts$filter_string have no current backup");
	}

	if (@new) {
		push @extra, "  INFO: ".scalar(@new).'/'.scalar(@all_accounts)." new accounts$filter_string have no current backup";
	}

        if ($VERBOSE) {
                foreach my $acct (@old) {
                        $P->add_message(CRITICAL, "$acct has no current backup");
                }
                foreach my $acct (@new) {
			push @extra, "  INFO: $acct is new, but has no current backup";
		}
    }
} else {
        $P->add_message(OK, 'All '.scalar(@all_accounts)." accounts$filter_string have a current backup");
}

my @crit_backups = ();
if ($CRITICAL_DAYS) {
        @crit_backups = grep {$state{complete_age}{$_} < time - $CRITICAL_DAYS * 24 * 3600} @{$state{oldest_backups_filtered_users}};
        $perfdata{"crit_old_${CRITICAL_DAYS}_days"} = scalar(@crit_backups);
        if (@crit_backups) {
                $P->add_message(CRITICAL, scalar(@crit_backups).'/'.scalar(@all_accounts)." accounts$filter_string have backups older than $CRITICAL_DAYS days");
                if ($VERBOSE) {
                        foreach my $acct (@crit_backups) {
                                my $days = (time - $state{complete_age}{$acct}) / 24 / 3600;
                                $P->add_message(CRITICAL, sprintf "$acct has a backup older than $CRITICAL_DAYS days (%.1f) @ %s", $days, scalar localtime $state{complete_age}{$acct});
                        }
                }
        } else {
                my $count_string = "All ".scalar(@all_accounts);
                if (@not_backed_up) {
                        $count_string = "Remaining ".(scalar(@all_accounts) - scalar(@not_backed_up));
                }
                $P->add_message(OK, "$count_string accounts$filter_string have backups newer than $CRITICAL_DAYS days");
        }
}

if ($WARNING_DAYS) {
        my @warn_backups = grep {not $CRITICAL_DAYS or $state{complete_age}{$_} >= time - $CRITICAL_DAYS * 24 * 3600} grep {$state{complete_age}{$_} < time - $WARNING_DAYS * 24 * 3600} @{$state{oldest_backups_filtered_users}};
        $perfdata{"warn_old_${WARNING_DAYS}_days"} = scalar(@warn_backups);
        if (@warn_backups) {
                $P->add_message(WARNING, scalar(@warn_backups).'/'.scalar(@all_accounts)." accounts$filter_string have backups older than $WARNING_DAYS days");
                if ($VERBOSE) {
                        foreach my $acct (@warn_backups) {
                                my $days = (time - $state{complete_age}{$acct}) / 24 / 3600;
                                $P->add_message(WARNING, sprintf "$acct has a backup older than $WARNING_DAYS days (%.1f) @ %s", $days, scalar localtime $state{complete_age}{$acct});
                        }
                }
        } else {
                my $count_string = "All ".scalar(@all_accounts);
                if (@not_backed_up or @crit_backups) {
                        $count_string = "Remaining ".(scalar(@all_accounts) - scalar(@not_backed_up) - scalar(@crit_backups));
                }
                $P->add_message(OK, "$count_string accounts$filter_string have backups newer than $WARNING_DAYS days");
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

do_exit();
