# Matiné demo server (store screenshots)

A local Jellyfin with only freely licensed or public-domain titles and artwork made from the films' own frames. It
replaces `demo.jellyfin.org`, whose posters (TMDB, fanart.tv) have uncertain rightsholders. Licenses and attributions:
[CREDITS.md](CREDITS.md).

* **VM**: Lima `matine-demo` (vz, aarch64, 2 CPUs, 4 GiB, 30 GiB) running rootless Docker (`lima.yaml`). It mounts only
  `build/media`, read-only. It does not touch the other Lima VMs.
* **Stack** (`compose.yaml`): `jellyfin/jellyfin:12.4@sha256:fea863d0...` (the version the app is tested against, pinned by digest) behind
  `caddy:2.11-alpine` with `tls internal`. Jellyfin is not published; Caddy is, on guest port 8920, which Lima forwards to
  the Mac's `127.0.0.1:8920`. The app uses **`https://localhost:8920`**.
* **Library**: "Movies" (19 films) and "Shows" (Caminandes, 3 episodes; Apollo: The NASA Films, 4 episodes). Every remote metadata and image fetcher
  is off on both libraries, NFO + local images are the only readers, nothing is saved to the media folder (the mount is
  read-only too).
* **Media**: `build-media.py` grabs frames over HTTP range requests (no film is downloaded), makes posters (2:3, title
  lettering), backdrops (16:9) and episode thumbs from them, and builds a full-runtime placeholder per title: H.264,
  640 px wide, 1 fps, silent AAC tagged `eng` (a few MB each, they play in AVPlayer and download). The NFOs (own synopses,
  genres, tags; the license and attribution are in an XML comment, never in a visible field) are written from `catalog.py`.
* **Users**: `demo` (non-admin, empty password, downloads and remote control allowed) with a little state: three films part
  way (Sintel, The General, Steamboat Bill, Jr.), Tears of Steel and Caminandes E1 watched, Caminandes E2 and Apollo 11 part
  way, four favorites (Spring, Sherlock Jr., Caminandes, Wing It!). `admin` exists for setup (hidden from the login list; its password
  is in `build/admin-password`).

## Run

```bash
scripts/demo-server/demo-server.sh all        # media -> VM -> stack -> provision -> check (idempotent)
scripts/demo-server/demo-server.sh check      # curl --cacert https://localhost:8920/System/Info/Public
scripts/demo-server/demo-server.sh down       # stop the VM; `destroy` deletes it
```

Needs `limactl` 2.x, `ffmpeg`, `uv` and the macOS fonts used for poster lettering (Georgia Bold, Helvetica). Everything
generated is under `build/` (gitignored): frames, media, the VM yaml, `caddy-root.crt`, `ids.json`, `admin-password`.

## Trust the certificate in a simulator

Caddy's internal root CA is exported to `build/caddy-root.crt` (`demo-server.sh ca`). Add it to each simulator the shots
use:

```bash
xcrun simctl keychain <udid> add-root-cert scripts/demo-server/build/caddy-root.crt
```

The CA is generated inside the VM's `caddy-data` volume: `destroy` and rebuild it and the file changes.
Check from the Mac: `curl --cacert build/caddy-root.crt https://localhost:8920/System/Info/Public`.

## Item ids

`build/ids.json` maps each `catalog.py` slug to its Jellyfin item id (ids stay the same while the VM's `jf-config`
volume lives; a rebuilt server has new ones).

## Visible text

The app shows NFO `<tagline>` as a subtitle, so no license or credit goes into a visible field (tagline, plot, title).
The license and credit are in each NFO as an XML comment and in CREDITS.md; a few titles have a short tagline of our own.
NFOs carry no `lockdata`, so `provision.py` can refresh every item in place after an edit (ids never change).
