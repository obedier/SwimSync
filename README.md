# SwimSync

macOS and iOS apps for loading podcasts and MP3s onto a USB mass-storage MP3
player — built for a PSIER bone-conduction headset that mounts as
`/Volumes/SWIM` on a Mac and appears in the Files app on an iPhone.

| | macOS `SwimSync` | iOS `SwimSyncMobile` |
|---|---|---|
| Source of audio | Apple Podcasts and Music.app folders, drag and drop | Built-in podcast client (search, top chart, favourites), Files app, share sheet |
| Finds the player | Automatically on mount, can auto-launch | Pick the drive once in Files; reconnects on later launches |
| Copy engine, naming, duplicate detection | Shared `Shared/` core | Shared `Shared/` core |
| Extras | Spotlight suppression, xattr and sidecar cleanup, eject | Send again, replace on player, erase player, TestFlight script |

The macOS app is documented first; the iPhone app is in
[The iPhone app](#the-iphone-app) below.

## Why it exists

The player enumerates at **USB full speed (12 Mbit/s)**, not high speed, despite
reporting itself as "USB2.0 Device". Measured on this hardware:

| | Throughput |
|---|---|
| Raw read (link saturated) | 1.12 MB/s |
| Write, Spotlight indexing the volume | 0.30 MB/s |
| Write, indexing suppressed | **0.94 MB/s** |

Letting Spotlight index the device costs a **3.1x** write penalty on a link that
only has ~1.1 MB/s to give. The app suppresses indexing on every mount.

Two other macOS behaviours matter:

- FAT32 can't store extended attributes, so the `com.apple.provenance` xattr
  macOS adds on write spills into `._Track.mp3` AppleDouble sidecars. The player
  lists those as phantom unplayable tracks. The app strips xattrs after each
  copy and runs `dot_clean`.
- Apple Podcasts stores downloads under UUID filenames. The player displays raw
  filenames, so the app reads ID3 tags and renames on the way across —
  `BEEDA464-….mp3` becomes `ABC News Update - Wednesday, August 05, 2026 10-30AM ET.mp3`,
  with FAT32-illegal characters sanitised.

## Features

- Three shelves — **Podcasts** (the Apple Podcasts download folder), **Music**
  (the Music.app media folder), and **Files** (anything dropped or added)
- **Hides what the player already has**, so the list is only what's left to copy
- Drag and drop audio or folders anywhere onto the window
- ID3-derived titles, show names, and durations in the picker
- Capacity bar that previews whether the selection fits before you start
- Live per-file and overall progress with a measured MB/s rate and ETA
- Optional `01 - ` numbering, because these players sort by filename
- Auto-launches when the player is plugged in (launchd `StartOnMount`)
- Flush, clean, and eject in one action

## Knowing what's already on the player

A file's name changes on the way across — ID3 titles replace UUID stems,
FAT32-illegal characters are substituted, long names are truncated, and a
`01 - ` prefix is prepended. Comparing raw filenames would report every
transferred track as missing, so `DeviceIndex` reduces both sides to the same
normal form (no extension, no ordering prefix, no ` (2)` collision suffix,
whitespace collapsed, case-folded) and also matches on **exact byte size** —
the copy is byte-exact, so an MP3's length is effectively a fingerprint.

Matches are hidden rather than deleted, and the chip above the list always
reports the count, so a false positive is visible and one click away from being
undone.

## Formats

The player is an MP3 decoder with a little PCM support, so the library filters
to **MP3 and WAV** by default. Anything else — the `m4a` files Music.app is
full of — is one click away behind the format chip and carries a badge, because
those copy across perfectly well and then refuse to play. Apple Music's
FairPlay downloads (`.m4p`) are shown locked and can never be selected.

`ffmpeg` and `lame` are both installed on this machine, so transcoding to MP3
on the way across is a viable addition if the badge turns out to be annoying
rather than sufficient.

## Build

```sh
xcodegen generate
xcodebuild -project SwimSync.xcodeproj -scheme SwimSync \
  -configuration Release -derivedDataPath build build
cp -R build/Build/Products/Release/SwimSync.app /Applications/
```

Requires Xcode 26+, macOS 14+. Built unsandboxed so it can read the Podcasts
group container and write to `/Volumes`.

**Do not re-sign the copied app.** `xcodebuild` already signs it with the
Developer ID identity, and `codesign --force --sign -` would replace that with
an ad-hoc signature — which is what used to make macOS forget the permission
(see below).

## Why it is signed with a Developer ID

Writing to a removable volume needs the `SystemPolicyRemovableVolumes`
permission. macOS stores that grant against the app's **designated
requirement**, and for an ad-hoc signature the requirement is a bare content
hash:

```
designated => cdhash H"20b169b0a5494e9e…"
```

That hash changes on every single rebuild, so each new build looked like a
different application to TCC: a fresh prompt every time, and a pile of stale
duplicate entries in the permissions database. Signing with a Developer ID
pins the requirement to the team instead —

```
designated => anchor apple generic and identifier "com.osamabedier.SwimSync"
              and … certificate leaf[subject.OU] = U3972W2GDJ
```

— which survives rebuilds, so the grant is asked for once and then remembered.
If the permission ever needs to be re-asked from scratch:

```sh
tccutil reset SystemPolicyRemovableVolumes com.osamabedier.SwimSync
```

## Auto-open

Toggling "Open when player connects" installs
`~/Library/LaunchAgents/com.osamabedier.swimsync.mount.plist` with
`StartOnMount`. launchd fires on *any* volume mount, so the agent runs a guard
script that opens the app only when the expected volume is present.

## CLI fallback

`~/.local/bin/swimsync` does the same transfer from the terminal:

```sh
swimsync ~/Podcasts/*.mp3   # copy with progress
swimsync --list             # what's on the player
swimsync --clean            # strip macOS junk
swimsync --eject            # flush and eject
```

## The iPhone app

`SwimSyncMobile` is a second target sharing the same `Shared/` core — naming,
tag reading, duplicate detection, and the chunked copy engine are one
implementation used by both.

```sh
xcodegen generate
open SwimSync.xcodeproj      # pick your team under Signing & Capabilities
# then Run to a connected iPhone
```

It works, with two platform limits worth knowing before you rely on it:

**It cannot read Apple Podcasts.** On macOS the app reads the Podcasts download
folder directly. On iOS those files live inside the Podcasts app's own
container, and no API exposes them — Podcasts' share sheet offers a link to the
episode, not the audio. So the phone version is a queue you build from the
Files app or another app's share sheet, not a library it reads for you.

**It cannot detect the drive on its own.** iOS gives third-party apps no
equivalent of `NSWorkspace.didMountNotification`; an app cannot see volumes
appear. You pick the drive once through the Files picker and the grant is kept
alive with a bookmark, so it reconnects on later launches while the drive is
plugged in.

What does carry over: ID3-based renaming, FAT32 name sanitising, `01 - `
numbering that continues from what's already there, skip-what's-already-on-the
player, per-file progress with a real MB/s rate, and the copy-protection and
format badges.

### Finding podcasts

The Find tab is a podcast client without an account. It uses Apple's public
directory (the iTunes Search and Lookup APIs), the public Top Shows chart,
and the show's own RSS feed — no key, no server, nothing to sign up for.

- **Browse** — with nothing typed, the tab shows your favourite shows, saved
  episodes, every show you've downloaded from before, and the Top 50 chart
  for your storefront.
- **Search by show or by episode** — the segmented control switches the
  query between `entity=podcast` and `entity=podcastEpisode`. An episode hit
  can be downloaded on the spot or tapped to open its show.
- **Every episode in a show** — the feed is read in full, following
  RFC 5005 `rel="next"` pages when a show paginates its archive, with a
  filter box for finding one. Feeds that only publish their last N episodes
  (Simplecast does this by default) can't be extended; Apple's own catalogue
  holds fewer episodes than the feed, not more, so there is nothing to fall
  back to.
- **Favourites and history** — heart a show or an episode from anywhere.
  Every completed download is remembered, so an episode shows "downloaded
  before" even after the file is gone from the phone. All of it lives in
  one JSON file in the app's Documents folder.

### Sending again, and erasing

- **Send again** — after a transfer, every row in the Done panel has a
  *Retry* (failed) or *Send again* (succeeded) button. The file is rewritten
  under the same name, so the track numbering is untouched. This exists
  because a copy can report every byte landed and still produce a track the
  player refuses.
- **Replace a track that's already on the player** — a queued track the
  player already has shows a ↺ button. Toggling it removes the matching file
  from the player before the copy, so the new one lands under a clean name
  rather than as `Track (2).mp3`.
- **Erase player** — removes every audio file the app can see in the chosen
  folder, after a confirmation that states the count. Only top-level audio
  files; folders and anything the player's firmware relies on are left alone.
  Refused when the chosen folder is on the phone rather than the drive.

### TestFlight

```sh
scripts/testflight.sh
```

Archives, signs with the team's distribution certificate (Xcode mints the
App Store profile itself via the API key in `~/.appstoreconnect/`), and
uploads. The app record in App Store Connect has to exist first; the public
API can't create one, so it's a one-time step in the website or
`fastlane produce`.

Hardware: an iPhone 15 or later connects with a plain USB-C cable; earlier
phones need a Lightning-to-USB adapter. The phone has to power the player, so
if it fails to appear in Files, a powered hub is the fix.

## Not possible: Bluetooth transfer

The headphones are a Bluetooth audio *sink* (A2DP/AVRCP/HFP). No profile in
their firmware writes to internal storage, and the companion Boean app does AI
music generation, transcription, and EQ — not file transfer. iOS never exposes
OBEX; macOS Bluetooth File Exchange needs an OPP server the headphones don't
run. 2.4 GHz Bluetooth is also absorbed by water within centimetres, which is
precisely why the device has onboard storage. USB is the only path.
