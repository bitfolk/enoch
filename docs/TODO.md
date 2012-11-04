# Missing/Requested/Debated Features

## Web interface

The old Crowley bot had a web interface at http://quotes.blitzed.eu.org/. Aside from making it easier to search the quotes, it allowed one to log in (authenticated against Blitzed services) and then quickly rate quotes.

There's some notes about how we might do authentication in `enoch` on the wiki at https://github.com/bitfolk/enoch/wiki/External-authentication

## Rating nag feature

Every time `enoch` says a quote in a channel, it could go through the channel list looking for people who are able to rate the quote.

> (You're able to rate a quote if:
> * Your nickname is registered and you're identified to it;
> * You didn't add the quote, and;
> * You haven't already rated it)

For each such person it finds, it could send them a private message asking them if they want to rate the quote 1-10. A response simply containing a number between 1 and 10 would be enough to set the rating. In this way people would be encouraged to rate, and it's less cumbersome than having to type out a full "!ratequote …" command. It also avoids you having to guess if you are able to rate or have not already rated a given quote.

There could be other responses ("shut up", "die", "bugger off", "no", …?) which would disable this feature for this person.

Certainly there would have to be a way to disable the feature on a per-person basis. Perhaps it would be best starting off disabled for everyone?
