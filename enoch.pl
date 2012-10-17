#!/usr/bin/perl

use strict;
use warnings;

use Enoch::Conf;
use POE qw(Component::IRC);
use Enoch::Schema;

use Data::Dumper;
$Data::Dumper::Maxdepth = 3;

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

my $schema = db_connect($econf);

enoch_log("Connected to DB");

# This is for runtime stats about the channels, as opposed to configured
# settings.
my $channels = $econf->channels;

my $irc = irc_connect($econf);

POE::Session->create(
    package_states => [
        main => [
            qw( _default _start irc_001 irc_public irc_msg irc_notice
                irc_join handle_signal irc_whois )
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
        irc_311           => \&bot_ignore, # WHOIS nick user host
        irc_312           => \&bot_ignore, # WHOIS server
        irc_317           => \&bot_ignore, # WHOIS idle
        irc_318           => \&bot_ignore, # End of WHOIS
        irc_319           => \&bot_ignore, # WHOIS channels
        irc_330           => \&bot_ignore, # WHOIS logged in as (parsed by irc_whois)
        irc_353           => \&bot_ignore, # Channel names list
        irc_366           => \&bot_ignore, # End of /NAMES
        irc_396           => \&bot_ignore, # 'ntrzclvv.bitfolk.com :is now your hidden host
        irc_671           => \&bot_ignore, # WHOIS is using a secure connection
    },

    heap => {
        irc         => $irc,
        conf        => $econf,
        channels    => $channels,
        schema      => $schema,
        whois_queue => {},
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
            warn "We appear to have joined $chan but have no record of it in our configuration! Parting.";
            $irc->yield(part => $chan => "I don't belong here.");
            return;
        }

        my $schema = $heap->{schema};
        my $quotes = count_chan_quotes($schema, $chan);
        my $nicks  = count_chan_nicks($schema,  $chan);

        enoch_log("$chan has $quotes quotes from $nicks different nicks");
        my $greet = sprintf("Greetings $chan! Serving $quotes quote%s from $nicks distinct nick%s.",
            1 == $quotes ? '' : 's', 1 == $nicks ? '' : 's');

        $irc->yield(notice => $chan => $greet);
    } else {
        enoch_log("-!- $who has joined $chan");
    }
}

# Received WHOIS response. This will have a field 'identified' if the user is
# identified to a nickserv account.
sub irc_whois
{
    my ($heap, $sender, $whois, $arg1, $arg2, $arg3) = @_[HEAP, SENDER, ARG0];

    my $who         = lc($whois->{nick});
    my $account     = $whois->{identified};
    my $whois_queue = $heap->{whois_queue};

    return unless (defined $whois_queue);

    my $queue = $whois_queue->{$who};

    return unless (defined $queue);

    my $item;

    if (defined $account) {
        enoch_log("$who is logged in as $account");

        # We now need to go through the callback queue and find every callback
        # waiting for the nickname $nick, checking if they have the required
        # access. Required access might be simply 'identified' or if it's
        # 'admins' then they will need to be identified to a nickname that is a
        # bot admin.
        while ($item = pop(@{ $queue })) {
            my $callback = $item->{info}->{callback};
            my $args     = $item->{info}->{cb_args};

            # If they're a bot admin then they can always perform the action.
            if (is_bot_admin($heap, $account)) {
                enoch_log("$who is an admin");
                $callback->{sub}->($args, $account);
                next;
            } else {
                my $req_access = $item->{info}->{req_access};

                if ($req_access eq 'identified') {
                    # Command requires them to be identified and they are, so let's
                    # go.
                    $callback->{sub}->($args, $account);
                    next;
                } else {
                     my $target = $item->{info}->{cb_args}->{target};
                     my $errmsg = "Sorry $who, you don't have permission for that command.";
                     my $method = 'notice';

                     if ($target !~ /^[#\+\&]/) {
                         $method = 'privmsg';
                     }

                     $irc->yield($method => $target => $errmsg);
                 }
            }
        }
    } else {
        enoch_log("$who isn't identified to any nick");

        # We can now go through the callback queue for $nick and explicitly
        # tell them that they don't have permission.

        while ($item = pop(@{ $queue })) {
            my $target = $item->{info}->{cb_args}->{target};
            my $errmsg = "Sorry $who, you don't have permission for that command.";
            my $method = 'notice';

            if ($target !~ /^[#\+\&]/) {
                $method = 'privmsg';
            }

            $irc->yield($method => $target => $errmsg);
        }
    }
}

# Is the specified account a bot admin? Note that this is comparing services
# accounts, *NOT* IRC nicknames.
sub is_bot_admin
{
    my ($heap, $account) = @_;

    my $econf = $heap->{conf};

    return $econf->is_admin($account);
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

    my $heap     = $args->{heap};
    my $irc      = $heap->{irc};
    my $channels = $heap->{channels};

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
            $irc->yield(privmsg => $args->{target}
                => "Fail. '$first' isn't a valid command.");
        }

        return undef;
    }

    enoch_log("Got potential command '$first' from " . $args->{nick} . ", target "
        . $args->{target} . ": $first" . (defined $rest ? " $rest" : ''));

    # Now need to work out which channel this command relates to so that we can
    # know what access level is required. If $args->{channel} is set then this
    # was a public command so we'll assume at first that this is the channel
    # desired.
    my $chan = $args->{channel};

    # But if any argument starts with '#', '+' or '&' then treat that as the
    # channel.
    if (defined $rest) {
        my @bits = split(/\s+/, $rest);

        my $i = 0;

        foreach my $word (@bits) {
            if ($word =~ /^[#\+\&]/) {
                # This is the channel they wanted.
                $chan = $word;

                # Nuke the $i'th element out of @bits.
                splice(@bits, $i, 1);

                # And re-assemble the message without it.
                $rest = join(' ', @bits);
                last;
            }

            $i++;
        }
    }

    # By this point we must know the channel, so it's an error if not.
    if (not defined $chan) {
        my $errmsg = "Fail. You need to specify a channel.";
        my $method = 'notice';

        $method = 'privmsg' if ($args->{target} !~ /^[#\+\&]/);
        $irc->yield($method => $args->{target} => $errmsg);

        return undef;
    }

    $chan = lc($chan);

    # For access purposes there are now two different levels: the access level
    # required for the action in the current channel, and the access level
    # required by the requeted channel. For example, someone issuing a "!quote
    # #foo" command whilst in channel #bar needs to meet the access
    # requirements for both #foo and #bar.
    #
    # Easiest thing to do is to work out which one has the most stringent
    # requirement.
    my @unique_chans = keys %{{ map { $_ => 1 } ($args->{channel}, $chan) }};
    my $access = get_strictest_access({
            cmd      => $first,
            chanconf => $channels,
            channels => \@unique_chans,
    });

    my $cb_args = {
        msg     => $rest,
        nick    => $args->{nick},
        target  => $args->{target},
        channel => $chan,
        heap    => $args->{heap},
    };

    if ($access eq 'all') {
        # Anyone can do this, so just dispatch it.
        $cmd->{sub}->($cb_args);
    } elsif ($access eq 'nobody') {
        # No one's allowed to do that.
        my $errmsg = "Fail. You're not allowed to use the '$first' command.";
        my $method = 'notice';

        $method = 'privmsg' if ($args->{target} !~ /^[#\+\&]/);
        $irc->yield($method => $args->{target} => $errmsg);
    } elsif ($access eq 'identified' or $access eq 'admins') {
        queue_whois_callback($heap, {
                target     => $args->{nick},
                req_access => $access,
                callback   => $cmd,
                cb_args    => $cb_args,
        });
    } else {
        die "Command $first has unexpected access requirement '"
            . $access->{$first} . "'. What gives?";
    }
}

# Issue a 'whois' command with a callback function that will be executed
# provided that the results of the whois are as expected. This is going to
# check for the services account info being present.
sub queue_whois_callback
{
    my ($heap, $cb_info) = @_;

    my $irc         = $heap->{irc};
    my $whois_queue = $heap->{whois_queue};
    my $time        = time();
    my $target      = $cb_info->{target};

    my $queue_entry = {
        info      => $cb_info,
        timestamp => $time,
    };

    $whois_queue->{$target} = [] if (not exists $whois_queue->{$target});

    my $queue = $whois_queue->{$target};

    enoch_log("Queueing a WHOIS callback against "
        . $target . " for access level '" . $cb_info->{req_access} . "'");

    push(@{ $queue }, $queue_entry);
    $irc->yield(whois => $target);
}

# Return the most stringent access requirement out of a list of channel names.
# Each item in the list may be undef, or may not correspond to a configured
# channel.
sub get_strictest_access
{
    my ($args) = @_;

    my $cmd      = $args->{cmd};
    my $chanconf = $args->{chanconf};
    my $channels = $args->{channels};

    my %accessmap = (
        'all'        => 0,
        'identified' => 1,
        'admins'     => 2,
        'nobody'     => 3,
    );

    my $highest = 0;
    my $this;

    foreach my $item (@{ $channels }) {
        if (not defined $item) {
            # undef channel means 'all'
            $this = 'all';
        } elsif (not exists $chanconf->{$item}) {
            # Channel that we don't have configured means 'nobody', because we
            # don't want IRC people to be able to mess in the database for
            # unconfigured channels.
            $this = 'nobody';
        } elsif (not exists $chanconf->{$item}->{access}
                or not exists $chanconf->{$item}->{access}->{$cmd}) {
            # Channel exists but has no access set up. That's OK; that's 'all'.
            $this = 'all';
        } else {
            $this = $chanconf->{$item}->{access}->{$cmd};
        }

        enoch_log("Access level for '$cmd' on $item is '$this'");

        if ($accessmap{$this} > $highest) {
            $highest = $accessmap{$this};
        }
    }

    foreach my $k (keys %accessmap) {
        if ($accessmap{$k} == $highest) {
            enoch_log("Strictest required access is '$k'");
            return $k;
        }
    }

    # Should never reach here.
    die "Failed to find strictest access for '$cmd' on: "
        . join(' ', @{ $channels });
}

# Call up a random quote for the current (or a specified) channel.  If no
# channel is specified and the command came in over PRIVMSG then an error is
# produced.
sub cmd_quote
{
    my ($args, $account) = @_;

    my $chan = $args->{channel};
    my $msg  = $args->{msg};

    # By default we talk to channels using NOTICE.
    my $method = 'notice';

    # If the response will go to a nick then use PRIVMSG instead.
    if ($args->{target} !~ /^[#\+\&]/) {
        $method = 'privmsg';
    }

    my $irc = $args->{heap}->{irc};

    # So by now we know they want a quote from $chan and $msg contains any
    # further matching spec (may be a quote id or a regular expression to
    # match, or may be empty).

    # Make things slightly simpler by turning an empty $msg into undef.
    $msg = undef if (defined $msg and $msg =~ /^\s*$/);

    enoch_log($args->{nick}
        . " is requesting a quote from $chan, reply to be sent to "
        . $args->{target} . ", match spec: "
        . (defined $msg ? $msg : '(empty)'));

    my $schema = $args->{heap}->{schema};
    my ($quote, $err);

    # Simplest case is a numeric quote id.
    if (defined $msg and $msg =~ /^\d+$/) {
        ($quote, $err) = get_quote_by_id($schema, $msg, $irc,
            $args->{target});

        if (not defined $quote or not defined $quote->id) {
            # Quote didn't exist.
            $irc->yield($method => $args->{target}
                => "Fail. No such quote ($msg).");
            return;
        }
    } elsif (defined $msg) {
        # A match by regular expression.
        ($quote, $err) = get_quote_by_regex($schema, $chan, $msg);

        if (defined $err) {
            if ($err =~ /repetition-operator operand invalid/) {
                # Broken regexp.
                $irc->yield($method => $args->{target}
                    => "Fail. $msg isn't a valid regular expression.");
                return;
            }
        }

        if (not defined $quote or not defined $quote->id) {
            # No matching quote.
            $irc->yield($method => $args->{target}
                => "Fail. No quote for $chan matches $msg.");
        }
    } else {
        # Single random quote.
        ($quote, $err) = get_quote_by_regex($schema, $chan, '.*');

        if (not defined $quote or not defined $quote->id) {
            # No quotes at all.
            $irc->yield($method => $args->{target}
                => "Sorry. $chan doesn't have any quotes yet.");
        }
    }

    if (defined $quote and defined $quote->id) {
        my $text;

        if ($msg and defined $quote->nick and $quote->nick ne '') {
            $text = sprintf("Quote[%u / %.1f / %s @ %s]: %s", $quote->id,
                $quote->rating, $quote->nick,
                $quote->added->strftime('%d-%b-%y'), $quote->quote);
        } else {
            $text = sprintf("Quote[%u / %.1f]: %s", $quote->id,
                $quote->rating, $quote->quote);
        }
        $irc->yield($method => $args->{target} => $text);
    }
}

sub cmd_allquote
{
    my ($args, $account) = @_;

    my $msg  = $args->{msg};

    # By default we talk to channels using NOTICE.
    my $method = 'notice';

    # If the response will go to a nick then use PRIVMSG instead.
    if ($args->{target} !~ /^[#\+\&]/) {
        $method = 'privmsg';
    }

    my $irc = $args->{heap}->{irc};

    # Make things slightly simpler by turning an empty $msg into undef.
    $msg = undef if (defined $msg and $msg =~ /^\s*$/);

    enoch_log($args->{nick}
        . " is requesting a quote from any channel, reply to be sent to "
        . $args->{target} . ", match spec: "
        . (defined $msg ? $msg : '(empty)'));

    my $schema = $args->{heap}->{schema};
    my ($quote, $err);

    if (defined $msg) {
        # A match by regular expression.
        ($quote, $err) = get_allquote_by_regex($schema, $msg);

        if (defined $err) {
            if ($err =~ /repetition-operator operand invalid/) {
                # Broken regexp.
                $irc->yield($method => $args->{target}
                    => "Fail. $msg isn't a valid regular expression.");
                return;
            }
        }

        if (not defined $quote or not defined $quote->id) {
            # No matching quote.
            $irc->yield($method => $args->{target}
                => "Fail. No quote in the database matches $msg.");
        }
    } else {
        # A random quote, no matching.
        ($quote, $err) = get_allquote_by_regex($schema, '.*');

        if (not defined $quote or not defined $quote->id) {
            # No quotes.
            $irc->yield($method => $args->{target}
                => "Sorry, there's no quotes in the database yet.");
        }
    }

    if (defined $quote and defined $quote->id) {
        my $text;

        if ($msg and defined $quote->nick and $quote->nick ne '') {
            $text = sprintf("Quote[^B%u^O / %.1f / %s @ %s]: %s", $quote->id,
                $quote->rating, $quote->nick,
                $quote->added->strftime('%d-%b-%y'), $quote->quote);
        } else {
            $text = sprintf("Quote[%u / %.1f]: %s", $quote->id,
                $quote->rating, $quote->quote);
        }
        $irc->yield($method => $args->{target} => $text);
    }
}

sub cmd_addquote
{
    my ($args, $account) = @_;

    my $method = 'notice';

    # If the response will go to a nick then use PRIVMSG instead.
    if ($args->{target} !~ /^[#\+\&]/) {
        $method = 'privmsg';
    }

    my $irc = $args->{heap}->{irc};
    $irc->yield($method => $args->{target} => "Sorry! Not implemented yet.");
}

sub cmd_delquote
{
    my ($args, $account) = @_;

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
    my ($args, $account) = @_;

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
    my ($args, $account) = @_;

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

sub db_connect
{
    my ($conf, $schema) = @_;

    if (defined $schema) {
        # Already have schema object; is it alive?
        return $schema if ($schema->connected);
    }

    my $user = $conf->get_key('db', 'user');
    my $host = $conf->get_key('db', 'host');
    my $db   = $conf->get_key('db', 'db');
    my $pass = $conf->get_key('db', 'pass');

    enoch_log("Connecting to DB using $user\@$host");

    my $dsn = "dbi:mysql:database=$db;host=$host";

    $schema = Enoch::Schema->connect($dsn, $user, $pass, {
            mysql_enable_utf8 => 1,
            on_connect_call   => 'set_strict_mode',
            on_connect_do     => "SET NAMES 'utf8'",
        }
    );

    return $schema;
}

# Return a count of the number of quotes for a given channel.
sub count_chan_quotes
{
    my ($schema, $chan) = @_;

    my $rs = $schema->resultset('Quote')->search(
        { channel => $chan },
        {
            columns  => [ qw(id) ],
            distinct => 1,
        }
    );

    return $rs->count;
}

# Return a count of the number of distinct nicks that have added quotes for a
# given channel.
sub count_chan_nicks
{
    my ($schema, $chan) = @_;

    my $rs = $schema->resultset('Quote')->search(
        { channel => $chan },
        {
            columns => [ qw(nick_id) ],
            distinct => 1,
        }
    );

    return $rs->count;
}

# Find a single specified quote by ID number.
sub get_quote_by_id
{
    my ($schema, $id) = @_;

    my $quote = $schema->resultset('Quote')->find(
        { 'id' => $id },
    );

    return $quote;
}

# Find a single quote from a given channel by regular expression.
sub get_quote_by_regex
{
    my ($schema, $chan, $regex) = @_;

    my $quote;

    eval {
        $quote = $schema->resultset('Quote')->search(
            {
                'channel' => $chan,
                'quote'   => { 'REGEXP',  $regex },
            },
            {
                order_by => \"RAND()",
                rows     => 1,
            }
        )->single();
    };

    if ($@ ne '') {
        if ($@ =~ /repetition-operator operand invalid/) {
            return (undef, $@);
        } else {
            die $@;
        }
    }

    return ($quote, undef);
}

# Find a single quote from all channels, by regex.
sub get_allquote_by_regex
{
    my ($schema, $regex) = @_;

    my $quote;

    eval {
        $quote = $schema->resultset('Quote')->search(
            { 'quote'   => { 'REGEXP',  $regex } },
            {
                order_by => \"RAND()",
                rows     => 1,
            },
        )->single();
    };

    if ($@ ne '') {
        if ($@ =~ /repetition-operator operand invalid/) {
            return (undef, $@);
        } else {
            die $@;
        }
    }

    return ($quote, undef);
}

sub enoch_log
{
    my ($msg) = @_;

    my $now = scalar localtime;

    print STDERR "[$now] $msg\n";

    return undef;
}
