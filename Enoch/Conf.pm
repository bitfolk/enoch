package Enoch::Conf;

use warnings;
use strict;

use Carp;
use Config::Std;

sub new
{
    my ($class, $file) = @_;

    read_config $file => my %conf;

    bless {
        _conf => \%conf,
    }, $class;
}

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

1;
