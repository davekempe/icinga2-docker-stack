package Netbox;

# OO module to connect to and interrogate / update Netbox API
# Woody @ sol1 2023-02-16

use strict;
use warnings;
use Carp qw(carp croak confess);
use JSON;
use LWP::UserAgent;
use URI;
use Data::Dumper;

# debug is bitwise
our %DBG_STR = (
        1       => 'WARN',
        2       => 'INFO',
        4       => 'URL',
        8       => 'JSON',
        16      => 'PERL',
        32      => 'CACHE',
        64      => 'TABLE',
);

sub debug {
    my ($self, $level, @stuff) = @_;
    unless (($level) = (grep {$level == $_ or $level eq $DBG_STR{$_}} keys %DBG_STR)) {
        unshift @stuff,$_[0]; # no level was passed in
        $level = 1;
    }

    return unless ($level & $self->{debug});

    my @lines = map { sprintf ("%5s: %s\n",$DBG_STR{$level},$_) } @stuff;

    if ($self->{debug}) {
        if (ref($self->{debug}) eq 'ARRAY') {
            push @{$self->{debug}}, @lines;
        } elsif (ref($self->{debug}) eq 'CODE') {
            $self->{debug}->($_) foreach @lines;
        } else {
            printf STDERR "%s",$_ foreach @lines;
        }
    } else {
        printf STDERR "%s",$_ foreach @lines;
    }
}

# 
# new, authorised connection
#
sub new {
    my $class = shift;

    my %opt = @_;
    my $self = {};
    bless $self, $class;
    foreach my $key (qw(url key)) {
        $self->{$key} = delete $opt{$key} or croak("$key required");
    }

    # set up debug
    $self->{debug} = $opt{debug} // 0;

    $self->{mandatory_custom} = $opt{mandatory_custom} || {}; # mandatory custom variables

    # set up User Agent
    $self->{ua} = LWP::UserAgent->new(
        max_redirect => 0,
        ssl_opts => {
            verify_hostname => 0,
            SSL_verify_mode => 0x00,
        },
        keep_alive => 1,
    );
    $self->{ua}->timeout(120);

    my $J = $self->{json} = $opt{json} || JSON->new->ascii(1)->pretty(1)->canonical(1);

    my $status = $self->q('/status/');
    $self->debug(2, "Netbox Server versions - ".join(', ', map {ucfirst($_).": ".$status->{"$_-version"}} qw(netbox python django)));

    return $self;
}

#
# query the API
#

sub q {
    my ($self, $path, $data) = @_;
    my %headers = (
        Accept => 'application/json; indent=4',
        Authorization => "Token $self->{key}",
    );
    my $url = $path;
    if ($url !~ /^http/) {
        $url = $self->{url}.$path;
    } elsif ($url =~ /^http:/) {
        $url =~ s/^http/https/;
    }
    my $res;
    my $B = $self->{ua};
    my $J = $self->{json};
    if (ref($data) eq 'HASH') { # POST or PUT or PATCH
        my $content = ref($data)?$J->encode($data):$data;
        $headers{'Content-Type'} = 'application/json';
        if (delete $data->{id}) { # PUT
            $self->debug(8, "> $content");
            $res = $self->_process_response($B->put($url,%headers,Content => $content));
        } elsif ($url =~ /\d+\/$/) { # PATCH
            $self->debug(8, "> $content");
            # PATCH isn't in LWP::UserAgent
            my $req = HTTP::Request::Common::PATCH($url,%headers,Content => $content);
            $res = $self->_process_response($B->request($req));
        } else { # POST
            $self->debug(8, "> $content");
            $res = $self->_process_response($B->post($url,%headers,Content => $content));
        }
    } elsif ($data) {
        if ($data eq "__DELETE__") {
            my $raw_response = $B->delete($url,%headers);
            if ($raw_response->code == 404) {
                # already gone
                $self->_debug_response($raw_response);
                $res = $raw_response;
            } else {
                $res = $self->_process_response($raw_response,1);
            }
        } else {
            confess "Don't know what to do with data $data";
        }
    } else { # plain get
        $res = $self->_process_response($B->get($url,%headers));
    }
    $self->debug(8, "< ".$res->content);
    return unless defined wantarray or length $res->content;
    my $return = eval {$J->decode($res->content)};
    if (my $next_url = exists $return->{next} && delete $return->{next}) {
        while ($next_url) {
            $self->debug(16, "returned page of results, last one being: ".Dumper($return->{results}->[-1]));
            my $next = $self->_process_response($B->get($next_url,%headers));
            my $data = eval {$J->decode($next->content)};
            push @{$return->{results}}, @{$data->{results}};
            $next_url = $data->{next};
        }
    }
    $self->debug(16, Dumper($return));
    return $return;
}

sub _debug_response {
    my ($self,$res) = @_;
    $self->debug(4, sprintf("%6s %s => %s (%d bytes)",$res->request->method, $res->request->uri_canonical, $res->status_line, length($res->content)));
}


sub _process_response {
    #return HTTP::Response->new(500,"Netbox Disabled",[],"{}");
    my ($self,$res,$no_return) = @_;
    $self->_debug_response($res);
    if (!$res->is_success) {
	    confess $res->status_line . "\n\n" . $res->content;
    }
    return $res if $no_return;
    my $return = length($res->content) ? eval {$self->{json}->decode($res->content)} : '';
    if ($@) {
	    $self->debug(1, "Could not decode content as JSON:\n".$res->content);
    }
    foreach my $bad_thing (qw(detail non_field_errors)) {
	    if (!$@ and ref($return) and exists $return->{$bad_thing}) {
            confess "Netbox API Problem ($bad_thing): $return->{$bad_thing}";
	    }
    }
    return $res;
}

# work out if & why an updated is needed

sub update_needed {
    my ($self, $before, $data) = @_;
    my @update_needed = ();
    foreach my $key (keys %$data) {
        if (not exists $before->{$key} or (not defined $before->{$key} and defined $data->{$key})) {
            push @update_needed, "$key '' => $data->{$key}";
            last;
        } elsif (ref($data->{$key}) and ref($data->{$key}) eq 'HASH') {
            foreach my $subkey (keys %{$data->{$key}}) {
                next if $key eq 'custom_fields' and $subkey eq 'import_source';
                if (ref($data->{$key}->{$subkey}) eq 'HASH') {
                    foreach my $subsubkey (keys %{$data->{$key}->{$subkey}}) {
                        if ($before->{$key}->{$subkey}->{$subsubkey} ne $data->{$key}->{$subkey}->{$subsubkey}) {
                            push @update_needed, "$key/$subkey/$subsubkey $before->{$key}->{$subkey}->{$subsubkey} => $data->{$key}->{$subkey}->{$subsubkey}";
                        }
                    }
                } elsif (($before->{$key}->{$subkey}//'') ne ($data->{$key}->{$subkey}//'')) {
                    push @update_needed, "$key/$subkey ".($before->{$key}->{$subkey}//'')." => ".($data->{$key}->{$subkey}//'');
                }
            }
        } elsif (ref($before->{$key}) and ref($before->{$key}) eq 'HASH') {
            if (
                (exists $before->{$key}->{value} and $before->{$key}->{value} ne $data->{$key})
                    or
                (exists $before->{$key}->{id} and $before->{$key}->{id} != $data->{$key})
            ) {
                push @update_needed, "$key ".($before->{$key}->{value}||$before->{$key}->{id})." => $data->{$key}";
            }
        } elsif (ref($before->{$key}) or ref($data->{$key})) {
            confess "Not implemented";
        } elsif ($before->{$key} ne $data->{$key}) {
            push @update_needed, "$key $before->{$key} => $data->{$key}";
        }
    }
    return @update_needed;
}

# search for and update or create
sub update {
    my ($self,$path,$search,$data,$default) = @_;
    my $uri = URI->new("http://dummy/$path");
    $uri->query_form(%$search);
    my $query = $uri->query;
    my $find = $self->q("$path?$query");
    my $return;
    if ($find->{results} and @{$find->{results}} == 1) {
        # update
        my ($before) = @{$find->{results}};
        my @update_needed = $self->update_needed($before, $data);
        if (@update_needed) {
            my $update_needed = join " ; ", @update_needed;
            $update_needed =~ s/\n/\\n/g;
            $self->debug(2,"Updating $before->{url} because $update_needed");
            # make sure the defaults have a value
            foreach my $key (keys %$default) {
                if ($key eq 'custom_fields') {
                    foreach my $cf (keys %{$default->{$key}}) {
                        if (not defined $before->{$key}->{$cf}) {
                            $data->{$key}->{$cf} = $default->{$key}->{$cf};
                        }
                    }
                } else {
                    if (not defined $before->{$key}) {
                        $data->{$key} = $default->{$key};
                    }
                }
            }
            $return = $self->q($before->{url},$data);
        } else {
            $return = $before;
        }
    } elsif ($find->{results} and @{$find->{results}} == 0) {
        # create
        my %data = (%{$default||{}},%$search,%{$data||{}});
        $return = $self->q($path,\%data);
    } else {
        # problem
        confess "Too many results ($find->{count}) for lookup of $path?$query";;
    }
    return $return;
}

# add or remove tags to things
sub tag_add {
	my ($self,$thing,@tags) = @_;

	$thing = $self->q($thing->{url}) unless $thing->{tags};

	my %tags = map {($_ => 1)} @tags;
	$tags{$_->{slug}} = 0 foreach @{$thing->{tags}||[]};

	# do we need to add any tags?
	if (grep $tags{$_}, keys %tags) {
        $self->q($thing->{url},{%{$self->{mandatory_custom}},tags => [map {{slug => $_}} sort keys %tags]});
	}
}

sub tag_remove {
	my ($self,$thing,@tags) = @_;

	$thing = $self->q($thing->{url}) unless $thing->{tags};

	my %tags = map {($_->{slug} => 0)} @{$thing->{tags}||[]};
	$tags{$_} = 1 foreach grep exists $tags{$_}, @tags;

	# do we need to remove any tags?
	if (grep $tags{$_}, keys %tags) {
        $self->q($thing->{url},{%{$self->{mandatory_custom}},tags => [map {{slug => $_}} grep {not $tags{$_}} sort keys %tags]});
	}
}
