## What

`enoch` is an IRC bot that:

* Allows random quotations to be called up
* Allows searching the quote database via id or regular expression
* Tries to display a quotation containing the nickname of the person who just joined the channel
* Accepts submissions of quotations
* Allows rating of quotes from 1 to 10
* Displays a random quotation every so often

## Commands

Commands are prefixed with "!" when issued publicly in a channel. The "!" is optional when issued in private message.

*   `quote`

    Display a random quote from the current channel.

*   `quote #foo`

    Display a random quote from channel #foo.

*   `quote 12345`

    Display the quote with the ID 12345.

*   `quote foo.*bar`

    Display a random quote that matches the POSIX regular expression `foo.*bar`.

*   `aq`

    Display a random quote from all channels.

*   `addquote lorem ipsum`

    Add a quote with the text `lorem ipsum` to the database of the current channel's quotes.

*   `delquote 12345`

    Delete the quote with ID 12345.

*   `ratequote 12345 8`

    Rate the quote with ID 12345 at 8.

*   `stat`

    Report:

    * The number of quotes present.
    * The number of unrated quotes.
    * The number of quotes added by your nickname.
    * The average rating of quotes added by you.
    * Your personal quote score.

*  `stat foo`

    As above, but report stats for nickname `foo`.

*   `textban`

    Report the current list of banned quote text regular expressions. New quotes matching any of these regular expressions will not be allowed.

    The `textban` command is only available to bot admins and only works in private message.

*   `textban add /regexp/ Reason`

    Add a new text ban which will prevent quotes matching `/regexp/` from being added. Note that `/regexp/` is treated as a Perl-compatible regular expression, *not* a POSIX one. The `Reason` is required; it will be shown to users who try to add quotes which match the ban.

*   `textban del regexp`

    Delete the text ban for `regexp`.

## Software Dependencies

Unfortunately this is probably quite useless on networks that don't use some sort of IRC services and an ircd which shows in WHOIS which account a given user is authenticated against (e.g. Charybdis).

Other than that:

* Recent Perl
* MySQL (no PostgreSQL or SQLite versions yet, sorry)

## Perl Module Dependencies

* Config::Std
* POE
* POE::Component::IRC
* DBD::mysql
* DBIx::Class
* DateTime::Format::MySQL
* Encode
* Encode::Detect

### Debian

On recent Debian that means:

    # apt-get install libconfig-std-perl libpoe-component-irc-perl libdbix-class-perl libdbd-mysql-perl libdatetime-format-mysql-perl libencode-perl libencode-detect-perl

### cpan.minus

If you haven't got (or can't get) all the dependencies installed on the system then you might like to download [the `cpanm` script](https://raw.github.com/miyagawa/cpanminus/master/cpanm) and issue:

    $ cpanm --local-lib=cpanm Config::Std POE::Component::IRC DBIx::Class DBD::mysql DateTime::Format::MySQL Encode Encode::Detect

You would then execute `enoch` like:

    $ PERL5LIB=cpanm/lib/perl5 ./enoch.pl

## Installation

Assuming you've got your MySQL server installed and running with a user account created already for `enoch`, you should now be able to create the schema:

    $ mysql -u enoch -p enoch < enoch_schema.sql

## Configuration

Once you've created the schema, copy `enoch.conf.sample` to `enoch.conf` and edit to suit. It should be fairly self explanatory.

## Limitations

### Registered nicknames

`enoch`'s integration with services is limited to asking whether a nickname is
registered to an account or not, and which account that is. That means, amongst
other issues, that should an account expire and later be registered by someone
else, `enoch` has no way of knowing and will continue to assume that they are
one and the same person.

## Trivia

### Etymology

In Jewish mysticism Enoch was the great grandfather of Noah. According to the Third Book of Enoch (3 Enoch), Enoch was taken into Heaven and transformed into the angel Metatron to "serve as the celestial scribe."

* [3 Enoch](http://en.wikipedia.org/wiki/3_Enoch)
* [Metatron](http://en.wikipedia.org/wiki/Metatron)

### History

This bot is based on the Crowley bot which was in use on Blitzed for years. In September 2012 Blitzed changed its IRC services and forced a rewrite of Crowley; `enoch` is that rewrite.

Crowley was heavily tied in with the database design of the old Blitzed services and as a result its code was never made public. This rewrite will have fewer features and less integration with services, but that should allow it to be published at least.

* [Blitzed](http://blitzed.org/)
* [Charybdis ircd](https://github.com/atheme/charybdis)

## Contact

* Email: andy-github-enoch@bitfolk.com
* IRC: **grifferz** on `irc.bitfolk.com` channel `#BitFolk`

## TODO

See https://github.com/bitfolk/enoch/wiki/TODO for more ideas and feature requests.

## Copyright and licence

Copyright © 2012 Andy Smith &lt;andy-github-enoch@bitfolk.com&gt;

This program is free software; you can redistribute it and/or modify it under the terms of the Artistic License, the same as Perl.

See http://dev.perl.org/licenses/ for more information.
