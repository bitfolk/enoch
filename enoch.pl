#!/usr/bin/perl

use strict;
use warnings;

use Enoch::Conf;
use POE qw(Component::IRC);

use Data::Dumper;

# Dispatch table for commands that can be received either in public in the
# channels or else in private by message.
my %dispatch =
(
    'quote' =>
    {
        sub => \&cmd_quote,
    },
    'aq' =>
    {
        sub => \&cmd_allquote,
    },
    'addquote' =>
    {
        sub => \&cmd_addquote,
    },
    'delquote' =>
    {
        sub => \&cmd_delquote,
    },
    'ratequote' =>
    {
        sub => \&cmd_ratequote,
    },
    'rq' =>
    {
        sub => \&cmd_ratequote,
    },
    'stat' =>
    {
        sub => \&cmd_status,
    },
);

my $econf = new Enoch::Conf('./enoch.conf');

enoch_log("Parsed configuration; " . $econf->count_channels()
    . " IRC channels found");

# This is for runtime stats about the channels, as opposed to configured
# settings.
my $channels = $econf->channels;

my $irc = irc_connect($econf);

POE::Session->create(
    package_states => [
        main => [
            qw( _default _start irc_001 irc_public irc_msg irc_notice
                irc_join handle_signal )
        ],
    ],

    inline_states => {
        irc_disconnected  => \&bot_reconnect,
        irc_error         => \&bot_reconnect,
        irc_socketerr     => \&bot_reconnect,
        connect           => \&bot_connect,

# Timers

        timer_bookkeeping => \&timer_bookkeeping,

# Ignore all of these events

        irc_cap           => \&bot_ignore,
        irc_connected     => \&bot_ignore,
        irc_isupport      => \&bot_ignore,
        irc_mode          => \&bot_ignore, # Mode change
        irc_ping          => \&bot_ignore,
        irc_registered    => \&bot_ignore,
        irc_snotice       => \&bot_ignore,
        irc_003           => \&bot_ignore, # This server was created...
        irc_004           => \&bot_ignore, # penguin.uk.eu.blitzed.org charybdis-3.3.0...
        irc_005           => \&bot_ignore, # CHANTYPES=&# EXCEPTS...
        irc_250           => \&bot_ignore, # Highest connection count:...
        irc_252           => \&bot_ignore, # 5 :IRC Operators online...
        irc_254           => \&bot_ignore, # 343 :channels formed...
        irc_265           => \&bot_ignore, # 147 915 :Current local users...
        irc_266           => \&bot_ignore, # 709 1508 :Current global users...
        irc_301           => \&bot_ignore, # /away message
        irc_353           => \&bot_ignore, # Channel names list
        irc_366           => \&bot_ignore, # End of /NAMES
        irc_396           => \&bot_ignore, # 'ntrzclvv.bitfolk.com :is now your hidden host
    },

    heap => {
        irc      => $irc,
        conf     => $econf,
        channels => $channels,
    },
);

$poe_kernel->run();
exit 0;

sub _start
{
    my $heap = $_[HEAP];
    my $irc  = $heap->{irc};

    $poe_kernel->sig(HUP => 'handle_signal');
    $poe_kernel->sig(INT => 'handle_signal');

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
    my ($kernel, $heap) = @_[KERNEL, HEAP];

    if (1 == $heap->{shutting_down}) {
        $heap->{irc}->yield(shutdown => "Shutting down");
        exit 0;
    } else {
        enoch_log("Reconnecting in 60 seconds...");
        $kernel->delay(connect  => 60);
    }
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

# This numeric means we're successfully connected to an IRC server. We'll:
# 
# - set our umode (if specified)
# - start the timer for book keeping tasks
sub irc_001
{
    my ($heap, $kernel) = @_[HEAP, KERNEL];
    my $irc             = $heap->{irc};
    my $econf           = $heap->{conf};
    my $channels        = $heap->{channels};

    enoch_log("Connected to " . $irc->server_name());

    my $umode = $econf->get_key('irc', 'umode');

    if (defined $umode) {
        enoch_log("Setting umode $umode as requested");
        $irc->yield(mode => $irc->nick_name() . " $umode");
    }

    # Starting 5 minute book keeping timer, to kick off immediately and then
    # every 5 minutes thereafter.
    enoch_log("Starting book keeping");
    $kernel->delay(timer_bookkeeping => 0);
}

# Channel message of some sort
sub irc_public
{
    my ($heap, $sender, $who, $where, $msg) = @_[HEAP, SENDER, ARG0, ARG1, ARG2];

    my $nick     = (split /!/, $who)[0];
    my $channel  = $where->[0];
    my $irc      = $sender->get_heap();
    my $channels = $heap->{channels};

    enoch_log("<$nick:$channel> $msg");

    # Update last activity time
    if (exists $channels->{$channel}) {
        $channels->{$channel}{last_active} = time();
    } else {
        warn "Received a message in a channel ($channel) we seem to have no record of!";
    }

    # If the message begins with '!' then it might be a command for us.
    if ($msg =~ /^!/) {
        $msg =~ s/^!//;
        process_command({
                msg     => $msg,
                nick    => $nick,
                target  => $channel,
                channel => $channel,
                heap    => $heap,
        });
    }
}

# Private message to us
sub irc_msg
{
    my ($heap, $sender, $who, $recips, $msg) = @_[HEAP, SENDER, ARG0, ARG1, ARG2];

    my $nick = (split /!/, $who)[0];
    my $irc  = $sender->get_heap();

    enoch_log("<$nick> $msg");

    # Ignore any leading '!'.
    $msg =~ s/^!//;
    process_command({
            msg     => $msg,
            nick    => $nick,
            target  => $nick,
            channel => undef,
            heap    => $heap,
    });
}

# Notice to us. Should be ignored unless it's from NickServ
sub irc_notice
{
    my ($heap, $sender, $who, $recips, $msg) = @_[HEAP, SENDER, ARG0, ARG1, ARG2];

    my $nick  = (split /!/, $who)[0];
    my $irc   = $sender->get_heap();
    my $econf = $heap->{conf};

    my $ns_nick = $econf->check_key('irc', 'ns_nick', 'NickServ');

    # Is it from NickServ?
    if ($nick =~ /^$ns_nick$/i) {
        # Does it ask us to identify?
        my $challenge_re = $econf->check_key('irc', 'ns_challenge_re',
            '^(This nickname is registered|Please identify via)');

        if ($msg =~ /$challenge_re/i) {
            bot_identify($heap, $ns_nick);
        } else {
            enoch_log("$nick sent me a NickServ notice which I'm ignoring: $msg");
        }
    } else {
        enoch_log("-$nick- $msg");
    }
}

# Identify ourselves to NickServ
sub bot_identify
{
    my ($heap, $nickserv) = @_;
    my $irc   = $heap->{irc};
    my $econf = $heap->{conf};

    enoch_log("Identifying ourselves to $nickserv on request");

    my $pass = $econf->get_key('irc', 'pass');
    $irc->yield(privmsg => $nickserv => "identify $pass");
}

# We saw someone join a channel
sub irc_join
{
    my ($heap, $sender, $who, $chan) = @_[HEAP, SENDER, ARG0, ARG1];
    $chan = lc($chan);

    my $irc      = $sender->get_heap();
    my $channels = $heap->{channels};

    my $joined_nick = (split /!/, $who)[0];

    # Was it us?
    my $me = $irc->nick_name();

    if (lc($me) eq lc($joined_nick)) {
        enoch_log("I've joined $chan");

        # Since we're just coming into the channel we'll say our last auto
        # quote time was now.
        if (exists $channels->{$chan}) {
            $channels->{$chan}{last_autoquote} = time();
        } else {
            warn "We appear to have joined $chan but have no record of it in our configuration!";
        }
    } else {
        enoch_log("-!- $who has joined $chan");
    }
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

# Runs regular book keeping tasks:
#
# - Check we're in all the channels we're supposed to be
sub timer_bookkeeping
{
    my ($kernel, $heap) = @_[KERNEL, HEAP];
    my $irc             = $heap->{irc};
    my $channels        = $heap->{channels};

    enoch_log("Timer: book keeping");

    # Schedule the timer again 5 mintes from now.
    $kernel->delay(timer_bookkeeping => 300);

    # Join the channels we should be in.
    foreach my $chan (keys %{ $channels }) {
        $irc->yield(join => $chan);
    }

}

# Process a potential command received by either public message in a channel
# that began with '!' or else a private message.
# Arguments are provided as a single hash reference with the following keys:
#
# 'msg'     - The actual message text without any leading '!'
# 'nick'    - Nickname that sent the command
# 'target'  - Where any response should go to. Either a nickname or a channel.
#             Channels will being with '#', '&' or '+'.
# 'channel' - Channel that the command relates to. Will be undef for commands
#             received by private message, so needs to be parsed out of the
#             command itself.
# 'heap'    - POE::Component::IRC HEAP
#
# If the target of any response is a channel then errors etc will be sent to
# the nickname instead to avoid spamming the channel.
sub process_command
{
    my ($args) = @_;

    my ($first, $rest) = split(/\s+/, $args->{msg}, 2);

    $first = lc($first);

    my $cmd;

    if (exists $dispatch{$first}) {
        # Exact match on dispatch table for this command.
        $cmd = $dispatch{$first};
    } else {
        # No direct match. If this is a private chat then give an
        # error, otherwise just keep quiet.
        if ($args->{target} !~ /^[#\+\&]/) {
            my $irc = $args->{heap}->{irc};
            $irc->yield(privmsg => $args->{target}
                => "Fail. '$first' isn't a valid command.");
        }

        return undef;
    }

    enoch_log("Got potential command '$first' from " . $args->{nick} . ", target "
        . $args->{target} . ": " . $args->{msg});

    # Dispatch it.
    $cmd->{sub}->({
        msg     => $rest,
        nick    => $args->{nick},
        target  => $args->{target},
        channel => $args->{channel},
        heap    => $args->{heap},
    });
}

sub cmd_quote
{
    my ($args) = @_;

    my $method = 'notice';

    # If the response will go to a nick then use privmsg instead.
    if ($args->{target} !~ /^[#\+\&]/) {
        $method = 'privmsg';
    }

    my $irc = $args->{heap}->{irc};
    $irc->yield($method => $args->{target} => "Sorry! Not implemented yet.");
}

sub cmd_allquote
{
    my ($args) = @_;

    my $method = 'notice';

    # If the response will go to a nick then use privmsg instead.
    if ($args->{target} !~ /^[#\+\&]/) {
        $method = 'privmsg';
    }

    my $irc = $args->{heap}->{irc};
    $irc->yield($method => $args->{target} => "Sorry! Not implemented yet.");
}

sub cmd_addquote
{
    my ($args) = @_;

    my $method = 'notice';

    # If the response will go to a nick then use privmsg instead.
    if ($args->{target} !~ /^[#\+\&]/) {
        $method = 'privmsg';
    }

    my $irc = $args->{heap}->{irc};
    $irc->yield($method => $args->{target} => "Sorry! Not implemented yet.");
}

sub cmd_delquote
{
    my ($args) = @_;

    my $method = 'notice';

    # If the response will go to a nick then use privmsg instead.
    if ($args->{target} !~ /^[#\+\&]/) {
        $method = 'privmsg';
    }

    my $irc = $args->{heap}->{irc};
    $irc->yield($method => $args->{target} => "Sorry! Not implemented yet.");
}

sub cmd_ratequote
{
    my ($args) = @_;

    my $method = 'notice';

    # If the response will go to a nick then use privmsg instead.
    if ($args->{target} !~ /^[#\+\&]/) {
        $method = 'privmsg';
    }

    my $irc = $args->{heap}->{irc};
    $irc->yield($method => $args->{target} => "Sorry! Not implemented yet.");
}

sub cmd_status
{
    my ($args) = @_;

    my $method = 'notice';

    # If the response will go to a nick then use privmsg instead.
    if ($args->{target} !~ /^[#\+\&]/) {
        $method = 'privmsg';
    }

    my $irc = $args->{heap}->{irc};
    $irc->yield($method => $args->{target} => "Sorry! Not implemented yet.");
}

sub handle_signal
{
    my ($heap, $kernel, $sig) = @_[HEAP, KERNEL, ARG0];

    enoch_log("Received SIG$sig");

    if ($sig =~ /INT/i) {
        $heap->{shutting_down} = 1;
        $heap->{irc}->yield(quit => "Caught SIG$sig, bye.");
        $kernel->sig_handled();
    } elsif ($sig =~ /HUP/i) {
        # Doesn't do anything right now. Probably will want it to re-read the
        # config file.
        $kernel->sig_handled();
    }
}

sub enoch_log
{
    my ($msg) = @_;

    my $now = scalar localtime;

    print STDERR "[$now] $msg\n";

    return undef;
}
