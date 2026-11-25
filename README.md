# Matiné

A small, calm client for [Jellyfin](https://jellyfin.org), for Apple TV, iPhone and iPad.
Website: <https://matine.anthonywertz.com>.

Matiné is two apps over one Swift package: a tvOS app for the Siri Remote and a universal
iPhone + iPad app (same bundle id, so one purchase covers both). It talks only to your Jellyfin
server and your own iCloud account: no analytics, no accounts of its own, no third-party code.

Features:

- **Profiles** with avatars (generated robots and animals) and an optional PIN; adult and kid
  profiles, with controls a kid profile does not get; profiles shared between a person's Apple
  devices through their own iCloud.
- **Spanish and English**, chosen per profile.
- **Home** with Continue Watching, pinned shows and what is new in each library; a Top Shelf on
  Apple TV.
- **Search** that runs on the device: accent-insensitive, typo-tolerant, and bilingual (on-device
  language model and keywords) without sending what you type anywhere.
- **Sign in** with a password, with Jellyfin Quick Connect, or by approving a nearby phone from
  the TV.
- **Remote play**: start something from a phone and the TV streams it.
- **Downloads** (iPhone and iPad): an offline mirror of your library, with watch progress synced
  back when you reconnect.

Copyright (C) 2026 Anthony Wertz.
License: GPL-3.0-or-later with an App Store exception (`LICENSE`, `LICENSE-EXCEPTION`).
SPDX: `GPL-3.0-or-later WITH AdditionRef-Matine-App-Store-Exception`.

| Path | What |
| --- | --- |
| `Sources/MatineKit` | Everything but the views: API calls, models, profiles, PIN, home rows |
| `Sources/MatineCLI` | `matine`, the same features from the command line, against a Jellyfin server |
| `Tests/MatineKitTests` | Unit tests on synthetic server responses (no real library data) |
| `Apps/Matine` | The tvOS app: SwiftUI views over MatineKit (local package `../..`) |
| `Apps/MatineMobile` | The iPhone + iPad app (same bundle id, universal purchase): views over MatineKit's `LibrarySource` |
| `CloudKit/schema.ckdb` | The CloudKit schema for the household and search-keyword records |

## Build and test

```sh
swift build && swift test           # the package, on the Mac, in seconds
export MATINE_SERVER=https://jellyfin.example.com   # or pass --server URL; there is no built-in default
.build/debug/matine info            # server name and version
.build/debug/matine dev-login       # sign in with the test account in ~/.config/matine/dev-account (server=, user=, password= lines)
.build/debug/matine home            # the home rows the app would show
.build/debug/matine api-check       # after a Jellyfin upgrade: every call and field we use still exists?
.build/debug/matine playback ID --probe   # how the server will stream an item, and a header-auth fetch
.build/debug/matine media-report    # read-only: which files are fine, need faststart, a remux, or a re-encode
.build/debug/matine convert-plan > plan.sh   # read-only here: a sh script for the machine that holds your media, that fixes what media-report finds (dry run until DRY_RUN=0)
.build/debug/matine carry-over --snapshot FILE.json   # per profile, before a remux renames files; --restore FILE.json [--apply] after the rescan
scripts/app.sh build                # the tvOS app, for the simulator
scripts/app.sh run                  # build, install and launch in the simulator
scripts/app.sh run-dev home en-US   # the same, signed in as the dev account, on a screen and language
scripts/app.sh run-dev play:ID      # ...or straight into the player (also item:ID, library:ID, search)
scripts/app.sh run-dev settings es-ES -MatineDevRole kid   # ...as a kid profile
scripts/app.sh uitest               # UI tests: accessibility audit + remote-driven tours
scripts/app.sh uitest testTour DIR  # one of them, its screenshots in DIR
scripts/app.sh shot out.png         # screenshot it
.build/debug/matine robot > r.svg   # a sheet of generated robot avatars
scripts/mobile.sh run-dev home      # the iPhone/iPad app in the simulator (MATINE_SIM="iPad Pro 11-inch (M5)"), signed in as the dev account
scripts/mobile.sh shot out.png      # screenshot it
.build/debug/matine quickconnect start             # sign in with a code, approved elsewhere
.build/debug/matine quickconnect approve CODE      # approve another device's code
.build/debug/matine download ITEM --to DIR   # offline mirror: download one item (or --series ID --season ID) with the phone app's kit code
.build/debug/matine downloads --store DIR [--mirror]   # list what is downloaded; --mirror prints the offline library
scripts/check-strings.py            # every interface string has an English translation (both apps)
```

Requires Xcode 27 (tvOS 27 SDK). Deployment target tvOS 27 and iOS 27. The UI tests that open a
specific title read item ids from your own server: `TEST_RUNNER_MATINE_TEST_FILM`,
`TEST_RUNNER_MATINE_TEST_SERIES` and `TEST_RUNNER_MATINE_TEST_BARE` (they skip without them).

## Where things are stored

| What | Where | Why |
| --- | --- | --- |
| Profile list, language, per-profile device id, name, avatar, adult/kid | `UserDefaults` | tvOS gives apps no guaranteed file storage |
| Recent searches (8 per profile) | Keychain, `ThisDeviceOnly` | what someone searched is close to what they watch: kept out of the backed-up settings; forgotten with the profile (and on sign-out) |
| Access tokens, PINs, PIN attempt counts (with the lockout's monotonic start, so setting the date does not skip one) | Keychain, `ThisDeviceOnly` | never synced, never restored elsewhere; cleared at launch if no profile is saved (an uninstall leaves Keychain items behind) |
| Passwords | nowhere | sent once at sign-in; encrypted over `https://`, in the clear over `http://` (allowed for home servers without a certificate; the sign-in screens warn) |
| API responses | nowhere | ephemeral session: watch history and pins never reach the disk cache |
| Search's on-device reading of titles and synopses (vectors, no text) | Caches, one file per profile (named by a hash of the profile id) | rebuilt if the system clears it; deleted when the profile is removed (not on a sign-out that keeps it) |
| Household (profiles shared between this Apple ID's devices: `HouseholdSync`) | CloudKit, container `iCloud.io.github.anthonytw.matine`, the signed-in iCloud account's PRIVATE database, zone `Household`: one `HouseholdMember` record per profile (named by a hash of server and user id; server, user id and name, display name, role, avatar, language, PIN, modified, removed; all CloudKit encrypted values) and short-lived `ApprovalRequest` records (server, user id, Quick Connect code, device model, created); never a token, device id, attempt record or anything watched; this device's copy of the household (`household-book`) lives in the Keychain; `matine household [--cloud FILE]` | newest copy wins whole; a profile arrives without a token ("needs sign-in"); signing out stays on the device, "Quitar de todos los dispositivos" writes a tombstone; a change that would leave kids without a grown-up PIN is held back; a new device's code is approved automatically by another device holding that adult profile's token (fresh, once, private database only) |
| Search keywords (extra Spanish and English words per title: `KeywordStore`, JSON, ~100 bytes a title) | made on the phone (Application Support/Keywords, `local.json`) and sent to CloudKit, container `iCloud.io.github.anthonytw.matine`, the signed-in iCloud account's PRIVATE database, zone `Keywords`, one record per title named by a hash of server id and item id (fields: text hash, generator, words, made, retry mark: nothing about viewing); the Apple TV reads them into Caches (all fields are CloudKit encrypted values; schema in `CloudKit/schema.ckdb`: `xcrun cktool import-schema` into development, then Deploy Schema Changes to production in the CloudKit console before a release build syncs); `matine keywords --save FILE` makes a file on a Mac; **sharing with another Apple ID**: the sharer's phone shares ONLY the Keywords zone (a zone-wide `CKShare`, system sharing sheet from the profile's "Búsqueda" section, readWrite; the Household zone is never shared); the invited person's phone accepts the link, reads the shared zone through a second `CKSyncEngine` on their SHARED database (own state file, `shared-engine-state.json`; cache `shared.json`) and, while the share lasts, sends what it makes there instead of to their own zone; their Apple TV reads the shared database too (read-only); if the share ends, the words already received become their own and go to their private zone; `matine keywords --import A --save B` tries the merge rule on two files | no on-device model exists on tvOS; per server, not per profile; signed out of iCloud, search works without them; files owner-only (0600) |
| Posters | `URLCache` | tokenless, tag-versioned URLs; tvOS may purge it |
| Downloads (phone/iPad only: manifest, parents' metadata, artwork, MP4 files, progress waiting for the server) | Application Support/Downloads/<profile id>, excluded from backup, `completeUntilFirstUserAuthentication` | the offline mirror; one folder per profile, deleted with the profile |

## Playback

The app asks the server (`PlaybackInfo`, with an Apple TV device profile in
`Sources/MatineKit/Playback`) how to play each item:

| File | How it plays |
| --- | --- |
| MP4/M4V/MOV with H.264 or HEVC and AAC/AC-3/E-AC-3 | the file itself, straight to AVPlayer |
| anything else (MKV, WebM, other codecs) | the server's HLS: a cheap remux when only the container is wrong, a transcode otherwise (hardware-accelerated if the server has it) |

The token goes as an `Authorization` header on every player request, not in the
URL; the server's own `api_key` is stripped from the HLS URL it hands back. One
exception we can't remove: Jellyfin writes the token into the trickplay line of
the HLS playlist it serves. That text lives only in the player's memory.

Progress is reported at start, every 10 s, on pause/resume and at stop
(`PlaybackSession`), so resume points and watched state match the web app.

Each profile has its own random device id: Jellyfin keeps one session per device
id, so shared ids would sign profiles out of each other. A PIN profile closes back
to the picker when the app goes to the background.

The CLI keeps its own profiles and tokens in `~/.config/matine/cli` (0700/0600).

## Making files play (the converter)

`media-report` says what each file needs; `convert-plan` turns that into one
reviewed script, to run on the machine that holds your media (`ConversionPlan` and `ConversionScript` in MatineKit). Rule:
never re-encode what already plays.

| Verdict | What the script does |
| --- | --- |
| faststart | `-map 0 -c copy -movflags +faststart`: the same bytes, the index first |
| remux | each stream mapped and copied into MP4; HEVC retagged `hvc1` (`dvh1` for Dolby Vision 5/8); text subtitles to `mov_text`; PGS subtitles extracted to a `.sup` beside the file |
| reencode | only the stream that can't play: HEVC (10-bit if the source is), H.264, FLAC, E-AC-3 or AAC; the rest copied |

Left alone, with the reason printed in the script header: Dolby Vision
profile 7, HDR video that would need re-encoding, picture subtitles that can't
be extracted (DVD, DVB), paths outside `/media` or with a tab or newline.

```sh
matine convert-plan --only remux --limit 1 > plan.sh   # review it, copy it to the media machine
sh plan.sh                    # dry run (the default): read-only tests, echoes what it would run
DRY_RUN=0 sh plan.sh          # convert; stop and rerun any time
sh plan.sh undo               # (DRY_RUN=0 to do it) originals back from matine-convert.tsv
```

ffmpeg and ffprobe run per file in a one-off container of the Jellyfin image
(`docker run --rm --network none --user 1000:1000 -v /srv/media:/media
--entrypoint /usr/lib/jellyfin-ffmpeg/ffmpeg jellyfin/jellyfin:12.4`; the
Jellyfin container itself has the media read-only). Settings by environment:
`MEDIA_HOST`, `IMAGE`, `RUN_AS`, `LOG`. jellyfin-ffmpeg 7.x writes FLAC into
MP4 without flags; the plan adds `-strict experimental` for older builds anyway.

Per file: write `.matine-part.NAME` beside the original, verify with ffprobe
(video, audio and subtitle counts as planned, duration within 0.5 s, `moov`
before `mdat`), then swap: the original moves to a sibling
`.matine-originals/` (never deleted; you remove them once happy), the
new file takes its place, and a TSV line (old path, new path, verdict) is
logged. A file whose original is already set aside is skipped; a swap cut off
between its two moves is finished on the next run. Jellyfin's scanner ignores
every dot-named file and folder (`**/.*` in its ignore patterns), so temp files
and originals never show up in the library. Sidecar `.sup` files stay on undo.

A remux from `.mkv` changes the name, so Jellyfin creates a new item after the
rescan, without watched mark, progress or favorite. Per profile, with that
profile's own token (state is per user):

```sh
matine carry-over --snapshot state.json --profile NAME   # BEFORE the swap
# ...run the conversion, rescan the library in Jellyfin...
matine carry-over --restore state.json --profile NAME            # prints what it would write
matine carry-over --restore state.json --profile NAME --apply
```

Restore finds each new item by its new path and uses only per-user endpoints
(`POST /UserPlayedItems`, `/UserFavoriteItems`, `/UserItems/{id}/UserData`).
It adds, never overwrites: an item already watched, favorited or with its own
progress keeps it. The snapshot is watch history: written 0600, not committed.

## Profiles, avatars and kids

Every profile has an avatar: a robot drawn from a seed (`Robot`, its own on
each profile from the start; "Otro robot" draws another) or an animal, on one
of eight colors. Anyone can change their own avatar.

A profile is **Adulto** or **Infantil** (`HouseRules`). A kid profile has no
sign-out, language, PIN or Fijados controls; its profile page is its avatar
and "Cambiar de perfil". The grown-up side:

- **Perfiles de la casa** (an adult's profile page, behind that adult's PIN):
  rename profiles for the picker, switch them between adult and kid. There is
  always one adult left, and once a kid profile exists, at least one adult
  with a PIN, so a kid can't undo it: removing the last adult PIN or signing
  out the last adult with one is refused.
- An adult profile **without** a PIN, in a house with kids, needs a grown-up's
  PIN to get its first PIN or to sign out: a kid who wanders into it can't
  make their own PIN the household's key. Its viewing stays off the Top Shelf.
- **Añadir perfil** asks for any adult's PIN once a kid profile exists
  (`PinGate.checkAny`, with its own attempt limit: guessing there never locks
  an adult out of their own tile).
- An adult profile without a PIN, with kids in the house, says so on its
  home screen and profile page: a kid could just pick it on the picker.

## Approving a phone from the TV (nearby)

A phone in "Entrar con un código" announces its 6-digit code and its kind
(iPhone, iPad, other: no free text) over Bonjour (`_matine-join._tcp`). An
open profile on the TV offers a sheet; the person compares the code with the
phone and approves as a profile that may (`HouseRules.nearbyChoices`: its
PIN, a grown-up's, or a confirm step), so nothing approves with one press.
`matine nearby` lists announcements; `matine quickconnect start --announce`
makes one. Threat: the code is public on the LAN, so a stranger could announce
a code they started and hope someone approves it (which signs THEM in). The
defences are the loud warning on the sheet, focus on "Ahora no", a delay
before input counts, the confirm step, offers only over browsing screens,
rate limits and a 30-minute pause after 3 declines (`NearbyRoster`), a
Settings switch ("Avisar cuando un dispositivo quiera entrar"), and the
phone's "Has entrado como X / No soy yo" screen after a code sign-in.

## Remote play

A phone (the Jellyfin apps or web UI) can tell the Apple TV what to play; the TV
streams it itself, so closing the phone doesn't stop it. While a profile is open
and the app is in front, `RemoteListener` holds Jellyfin's WebSocket
(`wss://server/socket`, or `ws://` for an http server; the token in the `Authorization` header, not the URL),
reports its capabilities (Play, PlayState) and answers KeepAlive; it reconnects
with backoff. Play opens the player on that item for the open profile only (the
profile's own account must be able to fetch it); pause, unpause, seek and stop
steer the open player; progress goes through the usual `PlaybackSession`. Only
the first item of a Play is used and nothing ever plays a next episode. tvOS
suspends the app in the background, so the phone can only reach a Matiné that is
on screen. `matine listen` / `sessions` / `send-play` / `send` do the same from
a terminal (`--store NAME` gives the sender its own device id).

## Navigation

A sidebar, as the TV app has: Inicio, Buscar (not for kids), the profile, and
one entry per library. Home puts the focused tile's logo (or title), facts and
synopsis above the rows, with its art sharp on the right and fading into
black; rows are Seguir viendo (half-watched, then each series' next
episode), Fijados, and Novedades per library. Tiles use the system's focus
effect (lift, tilt, shine) and show their BlurHash (a blurred preview that
comes with the item) until the image loads. Detail pages share the look, and
Down from Play lands on the episode Play would start. The player's info panel
(swipe down) shows the title, episode and synopsis.

## Search

Search runs on the Apple TV, not on the server: the profile's whole catalog
(titles, original titles, synopses, genres, tags) is read when Search opens
(again after 15 minutes) and searched at every keystroke. Matching ignores case
and accents, matches word starts and plurals ("leon" finds "Los leones"), and
forgives one typo in longer words ("denitsta"). Every meaningful word must
match; titles outrank synopses. Results come in rows: Películas, Series,
Episodios, Vídeos; an episode is found by its own name and synopsis, not its
show's.

English and Spanish: a film's original title is searched as well as its
Spanish one, and any tag set in Jellyfin's metadata editor counts, so a parent
can add words in either language ("snake", "serpiente").

Meaning: where the Apple TV has Apple's on-device multilingual language model
(NaturalLanguage's contextual embedding, a system download), a last row,
Relacionado, lists titles whose name or synopsis is about what was typed, in
either language ("snake" → a story about vipers). Each title's text is read
once in the background and cached; a title counts as related when it scores
far above the rest of the catalog for that query. Nothing leaves the device.
tvOS has no Apple Intelligence or Translation framework (both unavailable in
the tvOS 27 SDK), so this is the only on-device route; without the model,
Search matches words only. `matine search TEXT` prints the same groups
(`--meaning` adds the related row where the model loads).

`scripts/app.sh uitest` drives the app with the Siri Remote: Apple's
accessibility audit on the picker, Home, a detail page, the profile page (adult
and kid), the avatar editor and Search, plus screenshot tours for review.

## Top Shelf

With Matiné in the top row of the Apple TV home screen, the shelf above it
shows Seguir viendo and Fijados of the last profile opened **without a
PIN**. A PIN profile never writes it, and setting a PIN or signing out clears
it. The app writes a snapshot (titles, tokenless image URLs, `matine://`
links; no token) to a keychain group it shares with the extension
(`Apps/Matine/TopShelf`), whose entitlements name only that group. A tile
opens its page; Play on the remote starts it. Links go through the picker's
own path, so a PIN profile asks for its PIN first. `matine topshelf` prints
the snapshot the app would write.

## Release scripts

`scripts/testflight.sh` and `scripts/asc.py` are the maintainer's App Store Connect and TestFlight
chores. They read the team id and API key from an env file outside the repository
(`MATINE_ASC_ENV`, default `~/.config/matine/release.env`) with `ASC_TEAM_ID`, `ASC_KEY_PATH`,
`ASC_KEY_ID`, `ASC_ISSUER_ID`, optionally `ASC_KEYCHAIN`, `ASC_KEYCHAIN_PASSWORD_FILE` (read on
stdin, never passed on a command line) and `ASC_BETA_GROUP` (default "Internal"); nothing of it is
in the tree, and you do not need them to build or run the apps. The TestFlight build number is
`MATINE_BUILD_BASE` (default 100) plus the commit count, so it stays above builds uploaded before
the public history began.

## Downloads (offline mirror, iPhone and iPad)

Downloads are a mirror of the library, not a folder of files: the same
menus, rows, artwork and search, showing only what is on the device. A library
appears if anything in it is downloaded; a series shows only its downloaded
episodes and seasons. Metadata and artwork of an item and its parents are kept
(`DownloadStore`, per profile). The file is the original
(`/Items/{id}/Download`, most libraries play directly as MP4); an
item the server wouldn't direct-play falls back to a Jellyfin remux. The token
travels in the Authorization header only; the transfer is a background
`URLSession` (`URLSessionDownloadEngine`), cellular off by default.

`HybridLibrarySource` is what the app reads: the server while it answers, the
`LocalLibrarySource` when a call fails for lack of a connection (and the Descargas
place always). A downloaded item plays from its file even online. Progress made
offline is recorded in the mirror and queued (`ProgressQueue`: one record per
item, latest wins, only "played" or a resume point is ever sent, never
"unplayed"); `DownloadSync` sends it on reconnect and refreshes the mirror's
progress and pins.
