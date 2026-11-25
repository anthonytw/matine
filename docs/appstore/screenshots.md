# App Store screenshots

Generated, not taken by hand, from the **local demo server** (`scripts/demo-server/`: Jellyfin 12.4 in the Lima VM
`matine-demo`, `https://localhost:8920` behind Caddy's local CA, user `demo`, empty password). Its library is only CC BY
open movies, US public-domain films and NASA's Apollo films, with art made from the films' own frames and synopses we wrote
(`scripts/demo-server/CREDITS.md`; the website credits them at /credits). Nothing is uploaded. Build and start it first: `scripts/demo-server/demo-server.sh all` (`check` only tests that it answers).

```bash
scripts/screenshots.sh tv        # Apple TV 4K simulator          -> build/screenshots/<lang>/tv/*.png
scripts/screenshots.sh iphone    # newest "iPhone NN Pro Max"     -> build/screenshots/<lang>/iphone/*.png
scripts/screenshots.sh ipad      # iPad Pro 13-inch (M5)          -> build/screenshots/<lang>/ipad/*.png
scripts/screenshots.sh           # all three, then the website set
MATINE_SHOTS_LANG=en-US scripts/screenshots.sh iphone   # one language (default: en-US and es-ES)
```

The folder is gitignored. A run builds the debug app (`.build/app`, `.build/mobile`), so do not run it beside
another `xcodebuild`/`swift test` in the same `.build`. Simulators the script booted are shut down at exit.

## Sizes (the script fails on any other)

| Set | Size | Simulator |
| --- | --- | --- |
| Apple TV | 3840 x 2160 (1920 x 1080 also accepted) | Apple TV 4K (4th generation) |
| iPhone 6.9" | 1320 x 2868 | newest "iPhone NN Pro Max" |
| iPad 13" | 2064 x 2752 portrait; Home also 2752 x 2064 landscape | iPad Pro 13-inch (M5) |

iPhone and iPad shots: light mode, `simctl status_bar override` (9:41, full battery, Wi-Fi, full bars; the iPad
status bar also shows the date, which `simctl` cannot set: it is the day of the run). The simulator language is set
to the shot language (and rebooted once) so the status bar matches. The app is uninstalled first (all three sets): a clean start, no profile from an earlier run.

## How

* **Apple TV**: `MatineUITests/testStoreShots` drives the Siri Remote (focus matters on tvOS) and writes each
  `XCUIScreen` screenshot. `scripts/screenshots.sh` passes the demo login, the titles and `MATINE_SHOTS_LANG`.
* **iPhone / iPad**: DebugLaunch routes (`-MatineDevScreen item:ID|search|home`, `-MatineDevSearch moon`) then
  `simctl io screenshot` after a 14 s wait (`MATINE_SHOTS_WAIT`) for sign-in and every poster.
* **iPad landscape**: `simctl` cannot rotate a simulator, so `MatineMobileUITests/testLandscapeShot` turns it
  (`XCUIDevice`, back to portrait in a teardown block), launches Home with the same arguments and writes
  `03-home-landscape.png`; the script checks it is 2064 x 2752 (XCUIScreen captures in the portrait frame), turns it
  upright with `sips -r 270` and checks 2752 x 2064. Like the TV, a non-zero xcodebuild exit after the shot is written
  only warns.
* Debug-only helpers added to both `DebugLaunch.swift`: `-MatineDevName NAME` (profile name shown: "Ana") and, on
  tvOS, `-MatineDevDemoProfiles YES` (adds made-up "Leo" (kid), "Marta", "Nico" (kid) with a dummy token, so the
  picker has several profiles; the demo server has one user). An empty password works: `MATINE_DEV_PASSWORD` is only
  required to be set.
* Titles, a different one per shot: Apple TV Sintel (film) and Caminandes (series), search "animation"; iPhone Spring
  (film) and Apollo: The NASA Films (series), search "moon"; iPad A Trip to the Moon. Each simulator trusts the demo
  server's CA (`simctl keychain add-root-cert`) before the app runs.

## The shots

| File | Shows |
| --- | --- |
| tv `01-home` | Home rows |
| tv `02-detail` | A film's page (Sintel) |
| tv `03-series` | Caminandes with the episode list focused |
| tv `04-profiles` | Profile picker: Ana plus three made-up profiles |
| tv `05-search` | Search "animation": the animated open movies |
| iphone `01-home` `02-detail` `03-search` `04-series` | Home, Spring, search "moon", the Apollo series |
| ipad `01-home` `02-detail` `03-home-landscape` | Home, A Trip to the Moon, Home in landscape |

Skipped: **iPhone downloads** (downloads work on the local server, but there is no debug hook yet to start one) and
the **iPhone profile** page (its Search section shows the keyword generator's last error from the simulator, which
is not store material).

## Website

`build/screenshots/web/<name>.webp` (en-US, at most 1600 px on the long side; `cwebp -q 85`, PNG if no `cwebp`):
`tv-home`, `tv-detail`, `tv-profiles`, `tv-search`, `iphone-home`, `iphone-detail`, `iphone-downloads` (skipped as
above), `ipad-home`, `ipad-home-wide` (landscape).

Rights: every title on the local demo server is CC BY or public domain (CREDITS.md), and every run still passes
`-MatineDevOnlyItems ID,ID,...` (`ONLY_ITEMS`: all of the server's ids, from `build/ids.json`): a DEBUG-only filter
(`Sources/MatineKit/API/DebugItemFilter.swift`) that drops anything else from every row, hero, search result and
library, so a title added to the server by mistake can never reach a shot. It does not touch the server or its watch state.

Picker language: outside a profile the app speaks Spanish (`AppModel.language`). In debug builds
`-MatineDevLanguage` also sets that no-profile language for the run (`debugDefaultLanguage`), so the en-US picker
reads "Who's watching?". Release behavior is unchanged.

Known quirks: the iPad shots show a small arc in the bottom-right corner (the iPadOS window-resize handle, not part of
the app). Once, `testmanagerd` crashed after all five TV shots were saved; the script accepts the shots and warns.

Look at every PNG before uploading.
