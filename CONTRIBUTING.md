# Contributing to Matiné

**Issues are welcome. Pull requests from outside the repository are not accepted.** The maintainer
writes and merges all the code, which keeps the licensing simple: the project is GPL-3.0-or-later
with an App Store exception (`LICENSE`, `LICENSE-EXCEPTION`), and code from other authors would
complicate that exception. A pull request from someone else is closed without review; that is
about the policy, not the idea.

Everyone is expected to follow the [code of conduct](CODE_OF_CONDUCT.md).
Security problems go through [SECURITY.md](SECURITY.md), not public issues.

## Bug reports

Open an issue with:

- what you did, what you expected and what happened (a screenshot or the exact message helps);
- the app (Apple TV, iPhone or iPad), its version, and the tvOS or iOS version;
- your Jellyfin server's version, and whether it is reached directly or through a reverse proxy.

Never paste tokens, passwords, PINs, server addresses or the contents of your library. If
a problem needs a title to reproduce, describe it ("a series with 3 seasons") rather than naming it.
If the problem might let someone get into a profile or read what someone watched, do not file an
issue: use [SECURITY.md](SECURITY.md).

## Feature requests

Open an issue that says the problem first (what you are trying to do and what gets in the way), then
the change you imagine. Requests that fit the design (no analytics, no accounts beyond your own
server, nothing sent anywhere but your server and your own iCloud) are easier to take on. Not every
request is accepted, and the roadmap is the maintainer's.

## Translations

The interface is Spanish with an English translation, in two string catalogs
(`Apps/Matine/Matine/Localizable.xcstrings` for Apple TV and
`Apps/MatineMobile/MatineMobile/Localizable.xcstrings` for iPhone and iPad).
To suggest a correction or a language, open an issue with the string as the app shows it and your
wording.

## Building from source

The source is public so you can read it, audit it and build it yourself. See the README:
`swift build && swift test` for the package; Xcode 27 or newer for the apps. `CLAUDE.md` lists the
repository's rules.
