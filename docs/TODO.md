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

## Banned text

It was found useful to ban certain text from being added to quotes in Crowley.

For example, an individual who had a habit of complaining of bullying any time a quote featuring them was added prompted the banning of the (Perl) regular expression `"<( \+\@)?THEIRNICK>"` in quote text. This was unpopular with users, who simply found alternate ways of expressing the string THEIRNICK, such as using UTF-8 replacement characters. However, it did save the sanity of the operator of the Crowley bot from accusations of "bullying".

In Crowley this "feature" was hardcoded into the source. No such feature yet exists in `enoch`.

If it were to be added, it should be configurable. Should it be added? If so, should it be configurable per-channel?