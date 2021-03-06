package Enoch::Conf;

use warnings;
use strict;

use Carp;
use Config::Std;
use Data::Dumper;

sub new
{
    my ($class, $file) = @_;

    read_config $file => my %conf;

    _check_syntax(\%conf, $file);

    bless {
        _conf => \%conf,
    }, $class;
}

# Internal subroutines
# ####################

# Check the basic syntax of the config file and bail out on severe errors.
sub _check_syntax
{
    my ($c, $file) = @_;

    # Check all required sections are there.
    foreach my $req (qw(irc db)) {
        croak "Required config section '$req' seems to be missing from $file"
            unless (exists $c->{$req});
    }

    my $got_a_channel = 0;

    # Now the channels. Only requirement is that there's at least one channel
    # defined. Set defaults here if not already there.
    foreach my $k (keys %{ $c }) {
        # Not interested in non-channel config sections.
        next unless $k =~ /^[#\+\!\&]/;

        croak "'$k' doesn't look like an RFC2812-valid IRC channel name!"
            unless (_is_valid_channel_name($k));

        $got_a_channel = 1;

        # Lower case it if necessary.
        my $lower_key = lc($k);

        if ($lower_key ne $k) {
            $c->{$lower_key} = delete $c->{$k};
            $k = $lower_key;
        }

        _check_channel_syntax($k, $c->{$k}, $file);
    }

    # Bot not much use if it hasn't got any channels defined.
    croak "No channels defined in $file!" if (0 == $got_a_channel);

    # Finally the database
    my $db_type = $c->{db}{type};

    croak "DB 'type' must be one of: mysql"
        if (not defined $db_type or $db_type !~ /^mysql$/i);

    foreach my $k (qw(host user pass db)) {
        croak "DB '$k' must be set" if (not defined $c->{db}{$k});
    }
}

# Check syntax of a config section for a specific channel. Also defines the
# default values.
sub _check_channel_syntax
{
    my ($chan, $conf, $file) = @_;

    if (defined $conf->{enabled}) {
        croak "'enabled' for $chan must be either 'yes' or 'no'"
            unless ($conf->{enabled} =~ /^(y|yes|n|no)$/i);

        $conf->{enabled} = lc($conf->{enabled});

        $conf->{enabled} = 'yes' if ($conf->{enabled} eq 'y');
        $conf->{enabled} = 'no'  if ($conf->{enabled} eq 'n');
    } else {
        # Defaults to 'yes'.
        $conf->{enabled} = 'yes';
    }

    if (defined $conf->{quote_every}) {
        croak "'quote_every' for $chan must be an integer >= 0"
            unless ($conf->{quote_every} =~ /^\d+$/);
    } else {
        $conf->{quote_every} = 60;
    }

    if (defined $conf->{need_activity_in}) {
        croak "'need_activity_in' for $chan must be an integer >= 0"
            unless ($conf->{need_activity_in} =~ /^\d+$/);
    } else {
        $conf->{need_activity_in} = 30;
    }

    if (defined $conf->{addquote_access}) {
        croak "Valid settings for $chan's 'addquote_access' are (identified|admins|nobody)"
            unless ($conf->{addquote_access} =~ /^(nobody|identified|admins)$/i);
    } else {
        $conf->{addquote_access} = 'identified';
    }

    if (defined $conf->{delquote_access}) {
        croak "Valid settings for $chan's 'delquote_access' are (admins|nobody)"
            unless ($conf->{delquote_access} =~ /^(nobody|admins)$/i);
    } else {
        $conf->{delquote_access} = 'admins';
    }

    $conf->{ratequote_access} = 'identified';
    $conf->{rq_access}        = $conf->{ratequote_access};

    if (defined $conf->{def_rating}) {
        croak "'def_rating' for $chan must be an integer between 1 and 10 inclusive"
            unless ($conf->{def_rating} =~ /^\d+$/
                    and $conf->{def_rating} >= 1
                    and $conf->{def_rating} <= 10);
    } else {
        $conf->{def_rating} = 5;
    }

}

# Is a given string a valid channel name as per RFC2821?
# Returns 1 if so, 0 if not.
sub _is_valid_channel_name
{
    my ($chan) = @_;

    if ($chan =~ /^[#\+\&][\x01-\x09\x0b-\x0c\x0e-\x1f\x21-\x2b\x2d-\x39\x3b-\xff]*$/) {
        return 1;
    }

    return 0;
}

# Class methods
###############

# Check a given key and allow a specified default value. If the key doesn't
# exist and no default is given, throw a fatal error.
sub check_key
{
    my ($self, $section, $key, $default) = @_;

    my $c = $self->{_conf};

    return $c->{$section}{$key} if (exists $c->{$section}{$key});

    return $default if (defined $default);

    croak("Required config key '$key' not found, and no default set");

    # Never reached
    return undef;
}

# Check for a given key and return its value, or undef if the key is not
# present.
sub get_key
{
    my ($self, $section, $key) = @_;

    my $c = $self->{_conf};

    return $c->{$section}{$key} if (exists $c->{$section}{$key});

    return undef;
}

# Return a hashref of all configured and enabled channels.
# Add an 'access' key which is the level of access required for the various
# commands.
# In the configuration file a channel is any section key that starts with '#',
# '+' or '&'.
sub channels
{
    my ($self) = @_;

    my $c = $self->{_conf};

    my %chans;

    foreach my $k (keys %{ $c }) {
        next unless $k =~ /^[#\+\&]/;

        my $enabled = $self->get_key($k, 'enabled');

        next unless ($enabled eq 'yes');

        # Normalise channel name to lower case.
        $k = lc($k);
        $chans{$k} = $c->{$k};
        $chans{$k}{access}{addquote}  = $self->get_key($k, 'addquote_access');
        $chans{$k}{access}{delquote}  = $self->get_key($k, 'delquote_access');
        $chans{$k}{access}{rq}        = $self->get_key($k, 'rq_access');
        $chans{$k}{access}{ratequote} = $chans{$k}{access}{rq};
    }

    return \%chans;
}

# Count the number of configured channels
sub count_channels
{
    my ($self) = @_;

    my $c = $self->{_conf};

    my $count = 0;

    foreach my $k (keys %{ $c }) {
        next unless $k =~ /^[#\+\&]/;
        $count++;
    }

    return $count;
}

# Is the specific account an admin of this bot?
sub is_admin
{
    my ($self, $account) = @_;
    $account = lc($account);

    my $admins = $self->get_key('irc','admin');

    # If multiple admins are defined then an ARRAY will have been returned.
    if (ref($admins) ne 'ARRAY') {
        return lc($admins) eq $account;
    }

    foreach my $admin (@{ $admins }) {
        if ($account eq lc($admin)) {
            return 1;
        }
    }

    return 0;
}

1;
