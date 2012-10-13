## What

`enoch` is an IRC bot that:

TODO:

* Accepts submissions of quotations
* Allows random quotations to be called up
* Allows searching the quote database via id or regular expression
* Allows rating of quotes from 1 to 10
* Displays a random quotation every so often
* Tries to display a quotation containing the nickname of the person who just joined the channel

## Software Dependencies

Unfortunately this is probably quite useless on networks that don't use the Atheme IRC services and an IRC that can show which services account a given user is authenticated against (e.g. Charybdis).

Other than that:

* Recent Perl
* MySQL (no PostgreSQL version, sorry)

## Perl Module Dependencies

* Config::Std
* POE
* POE::Component::IRC

### Debian

On recent Debian that means:

    # apt-get install libconfig-std-perl libpoe-component-irc-perl

### cpan.minus

If you haven't got (or can't get) all the dependencies installed on the system then you might like to download [the `cpanm` script](https://raw.github.com/miyagawa/cpanminus/master/cpanm) and issue:

    $ cpanm --local-lib=cpanm Config::Std

You would then execute `enoch` like:

    $ PERL5LIB=cpanm/lib/perl5 ./enoch.pl

## Installation

Assuming you've got your MySQL server installed and running with a user account created already for `enoch`, you should now be able to create the schema:

    $ mysql -u enoch -p enoch < enoch.sql

## Configuration

Once you've created the schema, copy `enoch.conf.sample` to `enoch.conf` and edit to suit. It should be fairly self explanatory.

## Trivia

### Etymology

In Jewish mysticism `enoch` was the great grandfather of Noah. Acording to the Third Book of Enoch (3 Enoch), Enoch was taken into Heaven and transformed into the angel Metatron to "serve as the celestial scribe."

* [3 Enoch](http://en.wikipedia.org/wiki/3_Enoch)
* [Metatron](http://en.wikipedia.org/wiki/Metatron)

### History

This bot is based on the Crowley bot which was in use on Blitzed for years. In September 2012 Blitzed changed its IRC services and forced a rewrite of Crowley; `enoch` is that rewrite.

Crowley was heavily tied in with the database design of the old Blitzed services and as a result its code was never made public. This rewrite will have fewer features and less integration with services, but that should allow it to be published at least.

* [Blitzed](http://blitzed.org/)

## Contact

* Email: andy-github-enoch@bitfolk.com
* IRC: *grifferz* on irc.bitfolk.com channel #BitFolk
