# Security policy

Matiné handles sign-in credentials for your Jellyfin server and a record of who uses it,
so please report vulnerabilities privately.

## Reporting

Use GitHub's private vulnerability reporting: open
<https://github.com/anthonytw/matine/security/advisories/new> (Security tab →
"Report a vulnerability"). Only you and the repository's maintainers see the report. Do not
open a public issue for a security problem. Include the affected component (`Sources/MatineKit`,
the Apple TV app, the iPhone/iPad app, the CLI), the version or commit, and steps that reproduce
it against a test server. Never include real tokens, passwords, server addresses or library
contents.

## What happens next

This is a volunteer-run project, so these are aims, not promises:

1. **Acknowledge.** You get a reply within a week, saying whether the report reproduces and how
   serious it looks.
2. **Fix.** The fix is developed in the advisory's private fork, with a regression test, and you
   are asked to check it if you wish.
3. **Publish.** Once a fixed release is out, the advisory is published as a GitHub Security
   Advisory; for a serious issue (a token or PIN exposed, a PIN or kid-profile guard bypassed,
   credentials sent over an unencrypted connection) a CVE is requested through GitHub. The
   timing is agreed with you; the default is publication with the fixed release.
4. **Tell users.** The release notes say who is affected, what could happen and what to do.

You are credited in the advisory and the release notes unless you prefer not to be.

## Scope

In scope: how the apps store and send tokens, passwords, PINs and profile data (see "Where things
are stored" in the README), the PIN and kid-profile guards, the Quick Connect and nearby-approval
flows, the CloudKit records the apps write, and the CLI.

Out of scope: vulnerabilities in Jellyfin itself (report them to the Jellyfin project), in Apple's
platforms, or in a server that is misconfigured. A server on plain `http://` sends the password and
token in the clear by design; the apps allow it with a "Not encrypted" warning, so that is out of scope too.

## Supported versions

Only the latest release.
