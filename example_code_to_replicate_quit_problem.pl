#!/usr/bin/env perl

# This code is from:
#
# http://stackoverflow.com/questions/2471373/how-do-i-correctly-shutdown-a-botbasicbot-bot-based-on-poecomponentirc
#
# and is meant to demonstrate how to quit with a message. It doesn't work,
# however, so if anyone ever gets back to me about that then it might provide a
# useful minimal script to check things are working.

use strict;
use warnings;
use POE;
use POE::Component::IRC::State;
use POE::Component::IRC::Common qw(parse_user);
use POE::Component::IRC::Plugin::Connector;
use POE::Component::IRC::Plugin::AutoJoin;

# create our session
POE::Session->create(
    package_states => [
        # event handlers
        (__PACKAGE__) => [qw(_start int irc_join irc_disconnected)]
    ]
);

# start the event loop
POE::Kernel->run();

# session start handler
sub _start {
    my ($kernel, $heap) = @_[KERNEL, HEAP];

    # handle CTRL+C
    $kernel->sig(INT => 'int');

    # create bot object
    my $irc = POE::Component::IRC::State->spawn(
        server => 'irc.blitzed.org',
        nick   => 'basic123bot',
        debug  => 1,
    );

    # save $irc in our session's storage heap
    $heap->{irc} = $irc;

    # handle reconnects
    $irc->plugin_add('Connector', POE::Component::IRC::Plugin::Connector->new());

    # handle channel joining
    $irc->plugin_add('AutoJoin', POE::Component::IRC::Plugin::AutoJoin->new(
        Channels => ['#debug'],
    ));

    # connect to IRC
    $irc->yield('connect');
}

# interrupt signal handler
sub int {
    my ($kernel, $heap) = @_[KERNEL, HEAP];

    $heap->{irc}->yield('quit', 'Quitting, bye!');
    $heap->{shutting_down} = 1;
    $kernel->sig_handled();
}

# join handler
sub irc_join {
    my ($who, $chan) = @_[ARG0, ARG1];
    my $irc = $_[HEAP]->{irc};

    my ($nick, $user, $host) = parse_user($who);
    if ($nick eq $irc->nick_name()) {
        # say hello to channel members
        $irc->yield('privmsg', $chan, 'Hello everybody');
    }
}

# disconnect handler
sub irc_disconnected {
    my ($heap) = $_[HEAP];

    # shut down if we disconnected voluntarily
    $heap->{irc}->yield('shutdown') if $heap->{shutting_down};
}

