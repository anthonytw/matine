# App Store material

| File | What |
| --- | --- |
| [listing.json](listing.json) | The listing for both platforms, in English (primary) and Spanish (Spain): name, subtitle, promotional text, description, keywords, the site's URLs, categories, the version and the notes and demo account for App Review |
| [screenshots.md](screenshots.md) | Generated screenshots (`scripts/screenshots.sh`) |

`uv run scripts/asc.py listing` prints what differs between App Store Connect and `listing.json`;
`--apply` writes it. It only touches versions that are not submitted yet. Limits Apple enforces:
name and subtitle 30 characters, promotional text 170, keywords 100 (comma-separated, no spaces
needed), description 4000.

## App Review

Review uses Jellyfin's public demo server (`https://demo.jellyfin.org/stable`, user `demo`, empty
password), never our own server: the notes in `listing.json` say so. If the demo server changes or
goes away, update the notes before submitting.

## Done in the web UI (no API, or the owner's own details)

1. **Pricing and Availability:** Free, all countries and regions.
2. **App Privacy:** "Data Not Collected". Nothing reaches the developer or a third party: the app
   talks only to the user's own Jellyfin server and the user's own iCloud private database.
3. **Age Rating:** answer the questionnaire for the app itself (it ships no content): no violence,
   no mature themes, no unrestricted web access, no user-to-user messaging; parental controls: yes
   (kid profiles, grown-up PINs).
4. **Content Rights:** the app contains no third-party content of its own; it plays what the user's
   own server holds.
5. **App Review contact:** name, phone and email.
6. **Copyright** on each platform's version, e.g. `2026 <owner's name>`.
7. **Build:** pick the build on each platform (tvOS and iOS share the build number).
8. **Screenshots:** made by `scripts/screenshots.sh`, uploaded by `uv run scripts/asc.py screenshots [DIR] --apply` (replaces the sets of each editable version that DIR has PNGs for; done for 1.0.0 on 2026-11-25).
