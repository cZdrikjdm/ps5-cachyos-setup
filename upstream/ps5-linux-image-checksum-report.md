# ps5-linux-image issue: SHA256 checksums on "latest" release don't match the served assets

**Release:** PS5 Linux Image (latest), build `20260731-185014`, kernel 7.1.4, patches `daa2e49`
**Asset:** `ps5-cachyos.img.xz` (other assets not verified)

## Problem

The release page publishes this SHA256 for `ps5-cachyos.img.xz`:

```
ad25c068fd38cd247fd32fb1be34694a7247d447b1694c129252eb90eb1e8a87
```

but the file actually being served hashes to:

```
84b193c1e9016699ff8d4b1df4d94f155135809187f3975d0886d131747b622d
```

## Evidence it's the checksum, not the download

- Two fully independent downloads — GitHub release asset via browser, and the R2 mirror (`pub-561df4012f1a46fbbdf618d5cc5941f6.r2.dev/ps5-cachyos.img.xz`) via curl — produce **byte-identical** files, both hashing to `84b193c1…` (size ~1.95 GB / 1998 MiB).
- A corrupted transfer would differ between sources and between attempts; this is perfectly reproducible.
- The image itself is healthy: flashed with balenaEtcher (which validates the xz stream during the flash), boots fine, `uname -r` reports `7.1.4` as the release notes say.

So the served asset is self-consistent and good; the published checksum appears to be stale or from a different build (checksums generated before the final asset upload, or the asset replaced without regenerating them).

## Why it matters

Users verifying their downloads (as any README tells them to) will re-download endlessly or assume their image/connection is broken. If checksum regeneration on release isn't automated, a manual refresh of the sums for this release would already help.

(Aside: `https://github.com/ps5-linux/ps5-linux-image/releases/download/latest/ps5-cachyos.img.xz` currently answers with a 9-byte "Not Found" body instead of the asset — the browser works because it uses the real asset links, but the conventional direct-download URL is broken too.)
