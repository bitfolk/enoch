#!/usr/bin/perl

use strict;
use warnings;

use Enoch::Conf;
use POE qw(Component::IRC);
use Enoch::Schema;

use Data::Dumper;
$Data::Dumper::Maxdepth = 3;

use Encode qw(encode_utf8);

# Dispatch table for commands that can be received either in public in the
# channels or else in private by message.
my %dispatch =
(
    'quote' =>
    {
        sub       => \&cmd_quote,
        need_chan => 1,
    },
    'aq' =>
    {
        sub       => \&cmd_allquote,
        need_chan => undef,
    },
    'addquote' =>
    {
        sub       => \&cmd_addquote,
        need_chan => 1,
    },
    'delquote' =>
    {
        sub       => \&cmd_delquote,
        need_chan => 1,
    },
    'ratequote' =>
    {
        sub       => \&cmd_ratequote,
        need_chan => 1,
    },
    'rq' =>
    {
        sub       => \&cmd_ratequote,
        need_chan => 1,
    },
    'stat' =>
    {
        sub       => \&cmd_status,
        need_chan => undef,
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
                irc_join handle_signal irc_whois irc_ctcp )
        ],
    ],

    inline_states => {
        irc_disconnected  => \&bot_reconnect,
        irc_error         => \&bot_reconnect,
        irc_socketerr     => \&bot_reconnect,
        connect           => \&bot_connect,

# Timers.

        timer_bookkeeping => \&timer_bookkeeping,

# Ignore all of these events.

        irc_cap           => \&bot_ignore,
        irc_connected     => \&bot_ignore,
        irc_ctcp_action   => \&bot_ignore,
        irc_isupport      => \&bot_ignore,
        irc_mode          => \&bot_ignore, # Mode change
        irc_ping          => \&bot_ignore,
        irc_quit          => \&bot_ignore,
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
        irc_328           => \&bot_ignore, # Channel URL info
        irc_330           => \&bot_ignore, # WHOIS logged in as (parsed by irc_whois)
        irc_332           => \&bot_ignore, # TOPIC text
        irc_333           => \&bot_ignore, # TOPIC set by
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
    my $heap = $_[HEAP];
    my $irc  = $heap->{irc};

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
    my ($econf) = @_;

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

# Channel message of some sort.
sub irc_public
{
    my ($heap, $who, $where, $msg) = @_[HEAP, ARG0, ARG1, ARG2];

    my $nick     = (split /!/, $who)[0];
    my $channel  = $where->[0];
    my $irc      = $heap->{irc};
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
        }) if ($msg !~ /^\s*$/);
    }
}

# Private message to us.
sub irc_msg
{
    my ($heap, $who, $msg) = @_[HEAP, ARG0, ARG2];

    my $nick = (split /!/, $who)[0];
    my $irc  = $heap->{irc};

    enoch_log("<$nick> $msg");

    # Ignore any leading '!'.
    $msg =~ s/^!//;
    process_command({
            msg     => $msg,
            nick    => $nick,
            target  => $nick,
            channel => undef,
            heap    => $heap,
    }) if ($msg !~ /^\s*$/);
}

# CTCP, e.g. ACTION.
sub irc_ctcp
{
    my ($heap, $what, $who, $ctcp, $text) = @_[HEAP, ARG0, ARG1, ARG2, ARG3];

    my $nick   = (split /!/, $who)[0];
    my $target = $ctcp->[0];

    # Is $target a channel?
    next unless ($target =~ /^[#\+\&]/);

    if (defined $text) {
        if ($what =~ /^action$/i) {
            enoch_log(" * $nick:$target $text");
        } else {
            # Some other sort of CTCP (we don't care what).
            enoch_log(" CTCP$what $nick:$target $text");
        }
    }

    $target = lc($target);

    # Is $target one of our channels?
    my $channels = $heap->{channels};

    if (exists $channels->{$target}) {
        # Set the last_active time.
        $channels->{$target}->{last_active} = time();
    } else {
        enoch_log("Received a CTCP for a channel we aren't supposed to be in! Parting.");
        my $irc = $heap->{irc};
        $irc->yield(part => $target => "I don't belong here.");
    }
}

# Notice to us. Should be ignored unless it's from NickServ.
sub irc_notice
{
    my ($heap, $who, $recips, $msg) = @_[HEAP, ARG0, ARG1, ARG2];

    my $nick  = (split /!/, $who)[0];
    my $irc   = $heap->{irc};
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

# Identify ourselves to NickServ.
sub bot_identify
{
    my ($heap, $nickserv) = @_;
    my $irc               = $heap->{irc};
    my $econf             = $heap->{conf};

    enoch_log("Identifying ourselves to $nickserv on request");

    my $pass = $econf->get_key('irc', 'pass');
    $irc->yield(privmsg => $nickserv => "identify $pass");
}

# We saw someone join a channel.
sub irc_join
{
    my ($heap, $who, $chan) = @_[HEAP, ARG0, ARG1];

    my $irc      = $heap->{irc};
    my $channels = $heap->{channels};

    my $joined_nick = (split /!/, $who)[0];

    # Nicks might contain "[", "]", "|" which will interfere with POSIX RE
    # matching.
    my $esc_nick = escape_posix_re($joined_nick);

    # Was it us?
    my $me = $irc->nick_name();

    $chan = lc($chan);

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

        my $now = time();

        if (exists $channels->{$chan}{last_onjoin}
                and ($now - $channels->{$chan}{last_onjoin} <= 2)) {
            enoch_log("Too soon for another on-join quote in $chan");
            return;
        }

        $channels->{$chan}{last_onjoin} = $now;

        # How many quotes are there that match $joined_nick?
        my $count = count_nick_chan_quotes($schema, $joined_nick, $chan);

        enoch_log("There's $count quotes in $chan that feature $joined_nick");

        my $i = $count;
        my $quote;
        my $found = 0;

        # Limit number of tries to 10.
        $i = 10 if ($i > 10);

        # We will now try up to 10 times to find a quote that has a rating
        # higher than a random number between 1 and 10. This makes the
        # higher-rated quotes come up proportionally more often.
        while (not $found and $i > 0) {
            # Random number between 1 and 10.
            my $r = rand(9) + 1;

            enoch_log("I want a quote scoring >= $r");

            $quote = $schema->resultset('Quote')->search(
                {
                    'channel' => $chan,
                    'quote'   => { 'REGEXP', '<[ @+]*' . $esc_nick . '>' },
                    'rating'  => { '>=', $r },
                },
                {
                    order_by => \"RAND()",
                    rows     => 1,
                }
            )->single();

            if (defined $quote and defined $quote->id) {
                $found = 1;
            }

            $i--;
        }

        if ($found) {
            my $text;

            if (defined $quote->nick and $quote->nick ne '') {
                $text = sprintf("[%u / %.1f / %s]: %s", $quote->id,
                    $quote->rating, $quote->nick, $quote->quote);
            } else {
                $text = sprintf("[%u / %.1f] %s", $quote->id,
                    $quote->rating, $quote->quote);
            }

            if (length($text) + length($irc->nick_name()) > $irc->{msg_length}) {
                # That's too long; make it as short as reasonably possible.
                $text = sprintf("[%u]: %s", $quote->id, $quote->quote);
            }

            $irc->yield(notice => $chan => $text);
        }
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
    my $econf       = $heap->{conf};

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
            if ($econf->is_admin($account)) {
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
            my $errmsg = "Sorry $who, you need to be identified to a "
                . "registered nickname to use that command.";
            my $method = 'notice';

            if ($target !~ /^[#\+\&]/) {
                $method = 'privmsg';
            }

            $irc->yield($method => $target => $errmsg);
        }
    }
}

# Just to ignore these so they don't show up as debug.
sub bot_ignore
{
    return undef;
}

# Default handler to produce some debug output.
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
# - Does an autoquote if it's time for one
sub timer_bookkeeping
{
    my ($kernel, $heap) = @_[KERNEL, HEAP];
    my $irc             = $heap->{irc};
    my $channels        = $heap->{channels};
    my $econf           = $heap->{conf};

    enoch_log("Timer: book keeping");

    # Schedule the timer again 5 mintes from now.
    $kernel->delay(timer_bookkeeping => 300);

    my $now = time();

    foreach my $chan (keys %{ $channels }) {
        # Join the channels we should be in.
        $irc->yield(join => $chan);

        # Does this channel want autoquotes?
        my $quote_every = $econf->get_key($chan, 'quote_every');

        if (0 == $quote_every) {
            #enoch_log("Autoquotes disabled in $chan");
            next;
        }

        # last_active might be undef if we've never seen anyone say anything
        # there yet. Set it to 0 if so.
        if (not defined $channels->{$chan}->{last_active}) {
            $channels->{$chan}->{last_active} = 0;
        }

        # When was the last time this channel did an autoquote?
        my $last_autoquote   = $channels->{$chan}->{last_autoquote};
        my $last_active      = $channels->{$chan}->{last_active};
        my $need_activity_in = $econf->get_key($chan, 'need_activity_in');

        # last_autoquote might be undef if we only recently joined.
        if (not defined $last_autoquote) {
            #enoch_log("Not doing autoquote for $chan because last_autoquote is undef");
            next;
        }

        my $secs_since_last_autoquote = $now - $last_autoquote;

        if ($secs_since_last_autoquote < ($quote_every * 60)) {
            # Too soon since last autoquote.
            #enoch_log("Not doing autoquote for $chan because it's too soon ($secs_since_last_quotequote secs) since the last one");
            next;
        }

        my $secs_since_last_active = $now - $last_active;

        if (($need_activity_in * 60) < $secs_since_last_active) {
            # Channel not active enough for an autoquote.
            enoch_log("Wanted to do an autoquote for $chan but need activity within "
                . ($need_activity_in * 60)
                . " seconds, and it was only active $secs_since_last_active "
                . "seconds ago");
            next;
        }

        # Time for an autoquote!
        bot_autoquote({
                heap    => $heap,
                channel => $chan,
        });
    }

}

# Issue a timed random quote for a given channel.
sub bot_autoquote
{
    my ($args)  = @_;
    my $heap    = $args->{heap};
    my $chan    = $args->{channel};
    my $irc     = $heap->{irc};
    my $schema  = $heap->{schema};
    my $econf   = $heap->{conf};
    my $chanrec = $heap->{channels}->{$chan};

    my $quote_every = $econf->get_key($chan, 'quote_every');

    my $now = time();

    enoch_log("Doing autoquote for $chan");

    # Try up to 10 times to find an acceptable quote.
    my $tries_left = 10;
    my $found      = 0;
    my $quote;

    while (not $found and $tries_left > 0) {
        my $r = rand(9) + 1;

        enoch_log("I want a quote scoring >= $r (Try " . (11 - $tries_left)
            . " of 10)");

        $quote = $schema->resultset('Quote')->search(
            {
                channel => $chan,
                rating  => { '>=', $r },
            },
            {
                order_by => \"RAND()",
                rows     => 1,
            }
        )->single();

        if (defined $quote and defined $quote->id) {
            $found = 1;
        }

        $tries_left--;
    }

    if ($found) {
        my $text;

        if (defined $quote->nick and $quote->nick ne '') {
            $text = sprintf("%u Minute Quote[%u / %.1f / %s]: %s",
                $quote_every, $quote->id, $quote->rating, $quote->nick,
                $quote->quote);
        } else {
            $text = sprintf("%u Minute Quote[%u / %.1f]: %s",
                $quote->id, $quote->rating, $quote->quote);
        }

        if (length($text) + length($irc->nick_name()) > $irc->{msg_length}) {
            # That's too long; make it as short as reasonably possible.
            $text = sprintf("%u Minute Quote[%u]: %s", $quote_every,
                $quote->id, $quote->quote);
        }

        $irc->yield(notice => $chan => $text);

        $chanrec->{last_autoquote} = $now;
        $chanrec->{last_active}    = $now;
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

    my $method = 'notice';
    $method = 'privmsg' if ($args->{target} !~ /^[#\+\&]/);

    my $access;

    # By this point we will know the channel, if the command was issued in a
    # channel or specified a channel. If the command requires a channel and we
    # don't have one by now then it is an error.
    if (defined $cmd->{need_chan}) {
        if (not defined $chan) {
            $irc->yield($method => $args->{target}
                => "Fail. You need to specify a channel.");

            return undef;
        } else {
            $chan = lc($chan);
        }

        $access = get_strictest_access({
                cmd      => $first,
                chanconf => $channels,
                channels => [ $chan ],
        });

    } else {
        # If the command doesn't need a channel then it can't have any access
        # requirements.
        $access = 'all';
    }

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

    $target = lc($target);

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
            if (is_regexp_error($err)) {
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

        if (defined $quote->nick and $quote->nick ne '') {
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

    my $msg    = $args->{msg};
    my $target = $args->{target};
    my $heap   = $args->{heap};
    my $irc    = $heap->{irc};
    my $schema = $heap->{schema};

    # By default we talk to channels using NOTICE.
    my $method = 'notice';

    # If the response will go to a nick then use PRIVMSG instead.
    $method = 'privmsg' if ($target !~ /^[#\+\&]/);

    # Make things slightly simpler by turning an empty $msg into undef.
    $msg = undef if (defined $msg and $msg =~ /^\s*$/);

    enoch_log($args->{nick}
        . " is requesting a quote from any channel, reply to be sent to $target, match spec: "
        . (defined $msg ? $msg : '(empty)'));

    my ($quote, $err);

    if (defined $msg) {
        # A match by regular expression.
        ($quote, $err) = get_allquote_by_regex($schema, $msg);

        if (defined $err) {
            if (is_regexp_error($err)) {
                # Broken regexp.
                $irc->yield($method => $target
                    => "Fail. $msg isn't a valid regular expression.");
                return;
            }
        }

        if (not defined $quote or not defined $quote->id) {
            # No matching quote.
            $irc->yield($method => $target
                => "Fail. No quote in the database matches $msg.");
        }
    } else {
        # A random quote, no matching.
        ($quote, $err) = get_allquote_by_regex($schema, '.*');

        if (not defined $quote or not defined $quote->id) {
            # No quotes.
            $irc->yield($method => $target
                => "Sorry, there's no quotes in the database yet.");
        }
    }

    return unless (defined $quote and defined $quote->id);

    my $text;

    if ($msg and defined $quote->nick and $quote->nick ne '') {
        $text = sprintf("Quote[%u / %.1f / %s @ %s]: %s", $quote->id,
            $quote->rating, $quote->nick,
            $quote->added->strftime('%d-%b-%y'), $quote->quote);
    } else {
        $text = sprintf("Quote[%u / %.1f]: %s", $quote->id,
            $quote->rating, $quote->quote);
    }
    $irc->yield($method => $target => $text);
}

sub cmd_addquote
{
    my ($args, $account) = @_;

    # Must have a services account name in order to add a quote. This should
    # have been determined before we got here.
    if (not defined $account or $account eq '') {
        die "Need services account to add quotes.";
    }

    my $nick    = $args->{nick};
    my $channel = $args->{channel};
    my $text    = $args->{msg};

    my $method = 'notice';

    # If the response will go to a nick then use PRIVMSG instead.
    if ($args->{target} !~ /^[#\+\&]/) {
        $method = 'privmsg';
    }

    enoch_log("$nick [Account: $account] wants to add a quote for $channel");

    my $heap   = $args->{heap};
    my $irc    = $heap->{irc};
    my $schema = $heap->{schema};
    my $econf  = $heap->{conf};

    # Do they already exist in our database?
    my $db_nick;

    $db_nick = db_find_or_new_nick($schema, $account);

    # If not, create.
    if (not $db_nick->in_storage()) {
        enoch_log("$account didn't exist in the database; creating");
        $db_nick->insert();
        enoch_log("Row for $account added with id " . $db_nick->id);
    }

    # XXX - At this point, Crowley checked that the person adding a quote had
    # rated at least half as many quotes as they have added, to encourage
    # people to rate more quotes. We won't do this until there is a working web
    # interface for quick rating.

    my $def_rating = $econf->get_key($channel, 'def_rating');

    my $quote = db_create_quote({
            schema  => $schema,
            nick    => $account,
            nick_id => $db_nick->id,
            channel => $channel,
            quote   => encode_utf8($text),
            rating  => $def_rating,
    });

    enoch_log("Added quote with id " . $quote->id);

    $irc->yield($method => $args->{target} => "Added quote " . $quote->id
        . " with an initial rating of $def_rating.");

    # XXX - At this point, Crowley would suggest to people who haven't rated
    # that many quotes that they really should rate some more. We won't do this
    # until there is a working web interface for quick rating.
}

# Create a new row in the quote table.
sub db_create_quote
{
    my ($args) = @_;

    my $schema = $args->{schema};

    my $rs = $schema->resultset('Quote');

    my $quote = $rs->create(
        {
            channel => $args->{channel},
            quote   => $args->{quote},
            nick    => $args->{nick},
            nick_id => $args->{nick_id},
            added   => \"NOW()",
            rating  => $args->{rating},
        }
    );

    return $quote;
}

# Return an existing nick object from the database if present, otherwise create
# a new one.
sub db_find_or_new_nick
{
    my ($schema, $nick) = @_;

    return $schema->resultset('Nick')->find_or_new( { nick => $nick } );
}

sub cmd_delquote
{
    my ($args, $account) = @_;

    my $method = 'notice';

    # If the response will go to a nick then use privmsg instead.
    if ($args->{target} !~ /^[#\+\&]/) {
        $method = 'privmsg';
    }

    my $nick    = $args->{nick};
    my $channel = $args->{channel};
    my $heap    = $args->{heap};
    my $id      = $args->{msg};
    my $irc     = $heap->{irc};
    my $schema  = $heap->{schema};
    my $econf   = $heap->{conf};

    if (not defined $id or $id !~ /^\d+$/ or $id <= 0) {
        $irc->yield($method => $args->{target}
            => "Fail. Please specify a numeric quote id > 0.");
        return undef;
    }

    enoch_log("$nick [Account: $account] wants to delete quote $id for $channel");

    # Let's actually find it first.
    my $quote = get_quote_by_id($schema, $id);

    if (not defined $quote or not defined $quote->id) {
        # That quote didn't exist.
        $irc->yield($method => $args->{target}
            => "Fail. Quote $id doesn't exist.");
        return undef;
    }

    my $text;

    if (defined $quote->nick and $quote->nick ne '') {
        $text = sprintf("Quote[%u / %.1f / %s @ %s]: %s",
            $quote->id, $quote->rating, $quote->nick,
            $quote->added->strftime('%d-%b-%y'), $quote->quote);
    } else {
        $text = sprintf("Quote[%u / %.1f]: %s", $quote->id,
            $quote->rating, $quote->quote);
    }

    $irc->yield($method => $args->{target} => $text);
    $irc->yield($method => $args->{target}
        => "All those moments will be lost in time. Quote $id deleted.");
    $quote->delete();
}

sub cmd_ratequote
{
    my ($args, $account) = @_;

    my $method = 'notice';

    # If the response will go to a nick then use privmsg instead.
    if ($args->{target} !~ /^[#\+\&]/) {
        $method = 'privmsg';
    }

    my $nick    = $args->{nick};
    my $channel = $args->{channel};
    my $heap    = $args->{heap};
    my $irc     = $heap->{irc};
    my $schema  = $heap->{schema};
    my $econf   = $heap->{conf};

    my ($id, $their_rating) = split(/\s+/, $args->{msg});

    if (not defined $id or $id !~ /^\d+$/ or $id <= 0) {
        $irc->yield($method => $args->{target}
            => "Fail. Please specify a numeric quote id > 0.");
        return undef;
    }

    if (not defined $their_rating or $their_rating !~ /^\d+$/
            or $their_rating < 1 or $their_rating > 10) {
        $irc->yield($method => $args->{target}
            => "Fail. Please specify a numeric rating between 1 and 10 inclusive.");
        return undef;
    }

    enoch_log("$nick [Account: $account] wants to rate quote $id at $their_rating");

    # Let's actually find it first.
    my $quote = get_quote_by_id($schema, $id);

    if (not defined $quote or not defined $quote->id) {
        # That quote didn't exist.
        $irc->yield($method => $args->{target}
            => "Fail. Quote $id doesn't exist.");
        return undef;
    }

    # Now find the row for the current nick. Do they already exist?
    my $db_nick = db_find_or_new_nick($schema, $account);

    # If not, create.
    if (not $db_nick->in_storage()) {
        enoch_log("$account didn't exist in the database; creating");
        $db_nick->insert();
        enoch_log("Row for $account added with id " . $db_nick->id);
    }

    my $rating_was_new = 0;

    if ($db_nick->id == $quote->nick_id) {
        # They're trying to rate a quote that they added.
        $irc->yield($method => $args->{target}
            => "Sorry, no rating your own quotes. This is meant to be "
            . "peer review you know! No rating set.");
        return;
    }

    my $rating = db_update_or_new_rating($schema, $db_nick->id, $quote->id,
        $their_rating);

    if (not $rating->in_storage()) {
        $rating->insert();
        enoch_log("New rating added to DB");
        $rating_was_new = 1;
    }

    my $ratings_count = db_count_ratings($schema, $quote->id);
    my $new_rating    = db_calc_rating($schema, $quote->id);

    if (defined $new_rating and $new_rating != $quote->rating) {
        $quote->rating($new_rating);
        enoch_log("New rating for quote id " . $quote->id
            . " is $new_rating");
    }

    if (0 == $rating_was_new) {
        $irc->yield($method => $args->{target}
            => "You already rated this quote; setting your new rating to "
            . "$their_rating.");
    }

    if (1 == $ratings_count) {
        $irc->yield($method => $args->{target} => "New score for quote "
            . $quote->id
            . " is $new_rating, based on 1 rating.");
    } else {
        $irc->yield($method => $args->{target} => "New score for quote "
            . $quote->id
            . " is $new_rating, based on $ratings_count ratings");
    }

    my $added_by_id    = $quote->nick_id;
    my $added_by_score = db_calc_nick_score($schema, $added_by_id);

    my $added_by_nick;

    if (0 == $quote->nick_id or $quote->nick eq '') {
        # We don't know who added this quote.
        $added_by_nick = "(Anonymous)";
    } else {
        $added_by_nick = $quote->rel_nick->nick;
    }

    $added_by_score = sprintf("%.2f", $added_by_score);
    $irc->yield($method => $args->{target}
        => "$added_by_nick (the person who added this quote) now has "
        . "a personal score of $added_by_score.");
}

# Either update an existing rating or create a new one.
sub db_update_or_new_rating
{
    my ($schema, $nick_id, $quote_id, $rating) = @_;

    return $schema->resultset('Rating')->update_or_new(
        {
            nick_id  => $nick_id,
            quote_id => $quote_id,
            rating   => $rating,
        }
    );
}

# Count the number of ratings for a given quote_id.
sub db_count_ratings
{
    my ($schema, $quote_id) = @_;

    return $schema->resultset("Rating")->search(
        { quote_id => $quote_id }
    )->count();
}

# Calculate what the new rating for a quote should be. It's going to be the sum
# of existing ratings divided by the count of them.
sub db_calc_rating
{
    my ($schema, $quote_id) = @_;

    my $rating_sum = $schema->resultset('Rating')->search(
        {
            quote_id => $quote_id,
        },
        {
            select => [ { sum => 'rating' } ],
            as     => [ qw(rating_sum) ],
        }
    )->first()->get_column('rating_sum');

    my $rating_count = $schema->resultset('Rating')->search({ quote_id => $quote_id })->count();

    return $rating_sum / $rating_count;
}

# Calculate the score for a given nick. That's defined as the sum of the
# ratings of their quotes minus 5 for each.
sub db_calc_nick_score
{
    my ($schema, $nick_id) = @_;

    return $schema->resultset('Quote')->search(
        {
            nick_id => $nick_id,
        },
        {
            select => [ { sum => \"rating - 5" } ],
            as     => [ qw(nick_score) ],
        }
    )->first()->get_column('nick_score');
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
    $irc->yield($method => $args->{target}
        => "Sorry! Not implemented yet.");
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

# Return a count of the number of quotes for a given channel which match a
# given nick.
sub count_nick_chan_quotes
{
    my ($schema, $nick, $chan) = @_;

    # Nicks might contain "[", "]", "|" which will interfere with POSIX RE
    # matching.
    my $esc_nick = escape_posix_re($nick);

    $esc_nick = '<[ @+]*' . $esc_nick . '>';

    my $rs = $schema->resultset('Quote')->search(
        {
            channel => $chan,
            quote   => { 'REGEXP', $esc_nick },
        },
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
        return (undef, $@) if (is_regexp_error($@));
        die $@;
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
        return (undef, $@) if (is_regexp_error($@));
        die $@;
    }

    return ($quote, undef);
}

# Does $@ contain a regular expression syntax error? If so then the user can be
# told; if not then the bot should die.
sub is_regexp_error
{
    my ($err) = @_;

    if ($err =~ /(trailing backslash|repetition-operator operand invalid)/i) {
        return 1;
    }

    return undef;
}

# Some strings, particularly nicknames, may contain things like '[', ']', '{',
# '}', '^' or '|' which need to be escaped before being fed into a POSIX RE
# match.
#
# XXX - This isn't handling the full possibilities of a POSIX regexp, like
# character classes etc. I've tried to limit it to only having to deal with
# what can be given to us by an ircd.
#
# See http://stackoverflow.com/a/400316/1394607 for some more gory details..
sub escape_posix_re
{
    my ($str) = @_;

    $str =~ s#([\{\}\[\]\|\^\\])#\\$1#g;

    return $str;
}

sub enoch_log
{
    my ($msg) = @_;

    my $now = scalar localtime;

    print STDERR "[$now] $msg\n";

    return undef;
}
