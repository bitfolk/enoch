#!/usr/bin/perl

use strict;
use warnings;

use Enoch::Conf;
use POE qw(Component::IRC);

use Data::Dumper;

my $econf = new Enoch::Conf('./enoch.conf');

enoch_log("Parsed configuration; " . $econf->count_channels()
    . " IRC channels found");

my $irc = irc_connect($econf);

POE::Session->create(
    package_states => [
        main => [
            qw(_default _start irc_001 irc_public irc_msg irc_notice)
        ],
    ],

    inline_states => {
        irc_disconnected => \&bot_reconnect,
        irc_error        => \&bot_reconnect,
        irc_socketerr    => \&bot_reconnect,
        connect          => \&bot_connect,
        irc_ping         => \&bot_ignore,
        irc_snotice      => \&bot_ignore,
        irc_registered   => \&bot_ignore,
        irc_connected    => \&bot_ignore,
        irc_cap          => \&bot_ignore,
        irc_003          => \&bot_ignore, # This server was created...
        irc_004          => \&bot_ignore, # penguin.uk.eu.blitzed.org charybdis-3.3.0...
        irc_005          => \&bot_ignore, # CHANTYPES=&# EXCEPTS...
        irc_isupport     => \&bot_ignore,
        irc_250          => \&bot_ignore, # Highest connection count:...
        irc_252          => \&bot_ignore, # 5 :IRC Operators online...
        irc_254          => \&bot_ignore, # 343 :channels formed...
        irc_265          => \&bot_ignore, # 147 915 :Current local users...
        irc_266          => \&bot_ignore, # 709 1508 :Current global users...
    },

    heap => {
        irc  => $irc,
        conf => $econf,
    },
);

$poe_kernel->run();
exit 0;

sub _start
{
    my $heap = $_[HEAP];
    my $irc  = $heap->{irc};

    $irc->yield(register => 'all');
    $irc->yield(connect => {});

    return;
}

sub bot_connect
{
    my ($kernel, $heap) = @_[KERNEL, HEAP];
    my $irc = $heap->{irc};

    $irc->yield(connect => {});
}

sub bot_reconnect
{
    my $kernel = $_[KERNEL];

    enoch_log("Reconnecting in 60 seconds...");

    $kernel->delay(connect  => 60);
}

sub irc_connect
{
    my $econf = shift;

    my $nick    = $econf->check_key('irc', 'nick', 'Enoch');
    my $ircname = $econf->check_key('irc', 'realname',
                                    'Metatron - https://github.com/bitfolk/enoch');
    my $server  = $econf->check_key('irc', 'server', 'localhost');
    my $port    = $econf->check_key('irc', 'port', 6667);
    my $pass    = $econf->check_key('irc', 'pass');

    enoch_log("I'm $nick and I'm going to try connecting to $server:$port");

    my $irc = POE::Component::IRC->spawn(
        Nick     => $nick,
        Username => $nick,
        Ircname  => $ircname,
        Server   => $server,
        Port     => $port,
        Password => $pass,
    );

    return $irc;
}

# This numeric means we're successfully connected to an IRC server. We'll set
# our umode (if specified) and join the channels we are interested in.
sub irc_001
{
    my ($heap) = $_[HEAP];
    my $irc    = $heap->{irc};
    my $econf  = $heap->{conf};

    enoch_log("Connected to " . $irc->server_name());

    my $umode = $econf->get_key('irc', 'umode');

    if (defined $umode) {
        enoch_log("Setting umode $umode as requested");
        $irc->yield('mode' => $irc->nick_name() . " $umode");
    }
}

# Channel message of some sort
sub irc_public
{
    my ($kernel, $sender, $who, $where, $msg) = @_[KERNEL, SENDER, ARG0, ARG1, ARG2];

    my $nick    = (split /!/, $who)[0];
    my $channel = $where->[0];
    my $irc     = $sender->get_heap();

    enoch_log("<$nick:$channel> $msg");
}

# Private message to us
sub irc_msg
{
    my ($kernel, $sender, $who, $recips, $msg) = @_[KERNEL, SENDER, ARG0, ARG1, ARG2];

    my $nick = (split /!/, $who)[0];
    my $irc  = $sender->get_heap();

    enoch_log("<$nick> $msg");

}

# Notice to us. Should be ignored unless it's from NickServ
sub irc_notice
{
    my ($kernel, $sender, $who, $recips, $msg) = @_[KERNEL, SENDER, ARG0, ARG1, ARG2];

    my $nick = (split /!/, $who)[0];
    my $irc  = $sender->get_heap();

    enoch_log("-$nick- $msg");
}

# Just to ignore these
sub bot_ignore
{
    return undef;
}

# Default handler to produce some debug output
sub _default
{
    my ($event, $args) = @_[ARG0 .. $#_];
    my @output         = ( "$event: " );

    for my $arg (@$args) {
        if ( ref $arg eq 'ARRAY' ) {
            push( @output, '[' . join(', ', @$arg ) . ']' );
        } else {
            push ( @output, "'$arg'" );
        }
    }

    enoch_log('DEBUG: ' . join(' ', @output));
}

sub enoch_log
{
    my ($msg) = @_;

    my $now = scalar localtime;

    print STDERR "[$now] $msg\n";

    return undef;
}
