# Third-party code

Matiné has **no third-party dependencies**: no Swift packages, no vendored
libraries. The Jellyfin calls are our own, written against the server's
OpenAPI spec (`/api-docs/openapi.json`) for exactly the endpoints we use.

## Before adding or borrowing anything

External code (a package, a file, or a few functions adapted from another
project) comes in only after a review, written up in the PR:

1. **Need**: what it does that we can't do in a few dozen lines ourselves.
2. **Minimal**: only the parts for features Matiné has. Strip everything else.
3. **Organized**: fold it into our structure and naming. We don't keep the
   source project's layout.
4. **Sweep** the result for redundancy, efficiency, security, privacy (what it
   sends, logs or stores about the people watching) and bugs.
5. **License**: compatible, and credited below with its copyright line.

## Credits

No third-party code. These were written by us from published descriptions, with nothing copied:

- **BlurHash** (`Sources/MatineKit/API/BlurHash.swift`): the decoder for the
  blurred previews Jellyfin sends with each image, from the algorithm as
  documented at <https://blurha.sh> (Wolt; the reference code is MIT). We
  decode only; the server encodes.
- **SplitMix64** (in `Robot.swift`): Sebastiano Vigna's public-domain generator,
  a handful of constants, so a seed draws the same robot everywhere.

Art, not code (nothing here ships as a file in the app):

- **Tangerine Bold** (Toshi Omagari, SIL Open Font License 1.1): the "Matiné en
  casa" lettering drawn into the Top Shelf images by `scripts/art.py`, which
  fetches the font at a pinned google/fonts commit and checks its SHA-256. The
  OFL allows using it in images; the font itself is not bundled.
