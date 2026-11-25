# CLAUDE.md — Matiné

Guidance for coding agents (and a summary of the project's rules for people).
Matiné is an Apple TV, iPhone and iPad client for a Jellyfin server. Read `README.md`
(layout, build, storage) and `THIRD_PARTY.md` (the import rule) first.

## Rules

- **Package first.** Logic goes in `MatineKit` with unit tests (`swift test`,
  seconds). `Apps/Matine` and `Apps/MatineMobile` hold views and focus only.
  Every feature also gets a `matine` CLI command, so it can be checked against a
  real server before the UI exists.
- **No third-party code** without the review in `THIRD_PARTY.md`: need, minimal,
  folded into our structure, swept, licensed and credited.
- **Privacy.** The token never goes in a URL (images are tokenless); no
  analytics, no logging of what anyone watches; each profile has its own random
  device id (Jellyfin keeps one session per device id).
  Test fixtures are synthetic: no real titles, ids, server addresses or user
  names. The app has no built-in server address; the person types theirs.
- **Every UI string** is Spanish in code and has an English entry in
  `Apps/Matine/Matine/Localizable.xcstrings` (Apple TV) or
  `Apps/MatineMobile/MatineMobile/Localizable.xcstrings` (iPhone and iPad);
  `scripts/check-strings.py` checks both.
- **Swift 6 language mode**, strict concurrency, zero warnings.
- **Delivery**: work on a branch, open a pull request, and squash-merge it; never push
  straight to `main`.
- **Dev account**: commands that sign in (`matine dev-login`, `scripts/app.sh run-dev`)
  read `~/.config/matine/dev-account` (`server=`, `user=`, `password=` lines): use a
  non-admin test account on a server you control. Never commit it.
- Run one `swift test` / `xcodebuild` at a time per checkout: concurrent runs hang
  on the shared `.build`.
