package Enoch::Textbans;

use warnings;
use strict;

use Carp;
use Storable qw(store retrieve);
use Data::Dumper;

sub new
{
    my ($class, $file) = @_;
    my $bans = {};

    if (! -e $file) {
        # Textbans file doesn't exist yet, so just create an empty one.
        store $bans, $file;
    }

    $bans = retrieve($file);

    bless {
        _bans => $bans,
        _file => $file,
    }, $class;
}

# Return the list of bans (regular expressions).
sub get_bans
{
    my ($self) = @_;

    my @regexps;

    foreach my $key (keys %{ $self->{_bans} }) {
        push(@regexps, $key);
    }

    return @regexps;
}

# Return the reason associated with a given ban regexp, or undef if the ban
# regexp doesn't exist.
sub get_reason
{
    my ($self, $regexp) = @_;

    if (defined $self->{_bans} and exists $self->{_bans}->{$regexp}) {
        if (exists $self->{_bans}->{$regexp}->{reason}) {
            return $self->{_bans}->{$regexp}->{reason};
        } else {
            croak("Textban for '$regexp' has no reason set");
        }
    } else {
        return undef;
    }
}

# Add a new ban.
sub add
{
    my ($self, $ban, $reason) = @_;

    $self->{_bans}->{$ban}->{reason} = $reason;

    store $self->{_bans}, $self->{_file};
}

# Count the number of banned texts.
sub count
{
    my ($self) = @_;

    my $count = 0;

    if (defined $self->{_bans}) {
        $count = scalar keys %{ $self->{_bans} };
    }

    return $count;
}

# Delete a ban. Returns 1 if the ban was found and deleted, 0 otherwise.
sub delete
{
    my ($self, $regexp) = @_;

    if (exists $self->{_bans}->{$regexp}) {
        delete $self->{_bans}->{$regexp};
        store $self->{_bans}, $self->{_file};
        return 1;
    }

    return 0;
}

1;
