package Enoch::Conf;

use warnings;
use strict;

use Carp;
use Config::Std;

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

        _check_channel_syntax($k, $c->{$k}, $file);
    }

    # Bot not much use if it hasn't got any channels defined.
    croak "No channels defined in $file!" if (0 == $got_a_channel);

    # Finally the database
    my $db_type = $c->{db}{type};

    croak "DB 'type' must be one of: mysql"
        if (not defined $db_type or $db_type !~ /^mysql$/i);

    foreach my $k (qw(host user db)) {
        croak "DB '$k' must be set" if (not defined $c->{db}{$k});
    }
}

# Check syntax of a config section for a specific channel. Also defines the
# default values.
sub _check_channel_syntax
{
    my ($chan, $conf, $file) = @_;

    if (defined $conf->{quote_every}) {
        croak "'quote_every' for $chan must be an integer >= 0"
            unless ($conf->{quote_every} =~ /^\d+$/);
    } else {
        $conf->{quote_every} = 60;
    }

    if (defined $conf->{quote_access}) {
        croak "Valid settings for $chan's 'quote_access' are: (all|identified)"
            unless ($conf->{quote_access} =~ /^(all|identified)$/i);
    } else {
        $conf->{quote_access} = 'all';
    }

    if (defined $conf->{addquote_access}) {
        croak "Valid settings for $chan's 'addquote_access' are (nobody|identified|admins)"
            unless ($conf->{addquote_access} =~ /^(nobody|identified|admins)$/i);
    } else {
        $conf->{addquote_access} = 'identified';
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

# Return a hashref of all configured channels.
# In the configuration file a channel is any section key that starts with '#',
# '+' or '&'.
sub channels
{
    my ($self) = @_;

    my $c = $self->{_conf};

    my %chans;

    foreach my $k (keys %{ $c }) {
        next unless $k =~ /^[#\+\&]/;

        # Normalise channel name to lower case.
        $k = lc($k);
        $chans{$k} = $c->{$k};
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

1;
