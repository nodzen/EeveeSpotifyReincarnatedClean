![Banner](Images/banner.png?)

# EeveeSpotifyReincarnatedClean

**Maintainer:** [Nodzen](https://github.com/nodzen) <br />
**Based on:** [EeveeSpotifyReincarnated](https://github.com/SideloadLabs/EeveeSpotifyReincarnated) <br />
**Release:** `6.7.3` **Spotify:** `9.1.x` (tested on `9.1.90`)

This is an independent clean fork with its own direction. Stability and no-bloat
come first; scope decisions are the maintainer's. Useful changes are ported
selectively in both directions — this fork is not synced commit-for-commit with
upstream, and upstream is welcome to port back from here the same way.

It keeps the original project and community contributions while excluding
unrelated prank and donation additions.

> [!IMPORTANT]
> This fork has diverged substantially from the original repository.

> [!NOTE]
> The original EeveeSpotify repository was disabled due to a [DMCA takedown](https://github.com/github/dmca/blob/master/2025/08/2025-08-14-spotify.md). This repository will not contain IPA packages in the repo itself.

Release files may also be shared in Telegram at [@ESRClean](https://t.me/ESRClean) if GitHub distribution is unavailable.

This tweak makes Spotify think you have a Premium subscription, granting free listening, just like Spotilife, and provides some additional features like custom lyrics.

## How this fork differs from upstream

Verified against upstream `Master`, not slogans:

- **Lyrics rework.** Per-track lookup state, single-flight provider requests,
  Genius fallback when the primary source misses, instrumental detection via
  LRCLIB probe, and `hide-on-error` that drops the card instead of showing an
  empty one.
- **Lyrics cards where 9.1.x omits them.** The lower Now Playing card is
  injected when the catalog response has no lyrics section (and re-identified
  per track so fast skips don't paint old lyrics), with the palette matched to
  the artwork. Upstream has neither the injection nor the palette fallback.
- **Login protection without logout loops.** Session hooks forward Spotify's
  auth lifecycle instead of blocking it; only the narrow credential-deletion
  request is cancelled. Upstream blocks `logout`/`destroy` outright, which is
  where the logout loops came from.
- **No secrets in git, no feature bloat.** No hardcoded provider keys (the token
  is read from Spotify's own requests), no LiquidGlass/flag-browser glitter —
  about 40 fewer files than upstream for things this tweak is not about.
- **AMOLED theme, analytics hardening, rating-prompt blocker.**
- **Release-like builds by default.** Diagnostics live behind `EEVEE_DEBUG=1`
  (see below), not in the IPA you listen to every day.
- **Tests that run.** Focused `swiftc` suites plus a configuration-snapshot
  check, executed by `build-debs-local.sh` before every local package build.

## Lyrics status

Custom lyrics on Spotify `9.1.x` are usable — not perfect, but this is already a win.

Providers (pick one in settings, Genius fallback is optional):

- **Spicy Lyrics** — word-synced where available.
- **Musixmatch** — the service Spotify uses; time-synced for many songs, but needs
  a user token. To obtain it, download Musixmatch from the App Store, sign up,
  then go to Settings > Get help > Copy debug info and paste it into the
  EeveeSpotify prompt. You can also extract the token using MITM.
- **LRCLIB** — the most open service, time-synced, but lacks lyrics for many songs
  and may be slow or unreachable without a VPN depending on the network.
- **Genius** — best coverage and fastest updates, never time-synced. Also serves
  as the automatic fallback when the primary source finds nothing.
- **PetitLyrics** — plenty of time-synced Japanese and some international lyrics.

Notes:

- When LRCLIB cannot be reached, the Genius fallback usually still provides
  lyrics, but without synchronization.
- If the tweak cannot find a song, you'll see a "Couldn't load the lyrics for
  this song" message (or no card at all with hide-on-error). Lyrics may be wrong
  for some songs with Genius due to text search — kindly refrain from opening
  issues about it.

## How to build an EeveeSpotify IPA using Github actions
> [!NOTE]
> If this is your first time, complete the following steps before starting:
>
> 1. Fork this repository using the fork button on the top right
> 2. On your forked repository, go to **Repository Settings** > **Actions**, enable **Read and Write** permissions.

<details>
  <summary>How to build the EeveeSpotify IPA</summary>
  <ol>
    <li>Click on <strong>Sync fork</strong>, and if your branch is out-of-date, click on <strong>Update branch</strong>.</li>
    <li>Navigate to the <strong>Actions tab</strong> in your forked repository and select <strong>Create IPA Packages</strong> if you're on desktop/widescreen. Tap on <strong>All Workflows</strong> and select <strong>Create IPA Packages</strong> if you're on mobile/portrait.</li>
    <li>Click the <strong>Run workflow</strong> button located on the right side.</li>
    <li>Prepare a decrypted .ipa file <em>(we cannot provide this due to legal reasons)</em>, then upload it to a file provider (e.g., filebin.net, filemail.com, or Dropbox is recommended). Paste the URL of the decrypted IPA file in the provided field.</li>
    <li><strong>NOTE:</strong> Make sure to provide a direct download link to the file, not a link to a webpage. Otherwise, the process will fail.</li>
    <li>Go to the releases page of the EeveeSpotify repository (<strong>NOT</strong> the fork). Hold and copy the link of the .deb file, which corresponds to your phone's architecture.</li>
    <li>Make sure all inputs are correct, then click <strong>Run workflow</strong> to start the process.</li>
    <li>Wait for the build to finish. You can download the EeveeSpotify IPA from the releases section of your forked repo. (If you can't find the releases section, go to your forked repo and add /releases to the URL, i.e., github.com/user/EeveeSpotifyReborn/releases.)</li>
  </ol>
</details>

## Local debug build

The normal build is release-like: diagnostic probes, detailed logs and the
legacy broad response blocking are disabled. To build a separate diagnostic
variant locally, set `EEVEE_DEBUG=1`; its IPA receives a `-debug` suffix:

```sh
EEVEE_DEBUG=1 ./build-ipa-local.sh Spotify_v9.1.80.ipa
```

Use the default command without `EEVEE_DEBUG=1` for the regular release-like
IPA. The debug variant retains the old broad response behavior as a
compatibility fallback; set `EEVEE_DISABLE_LEGACY_RESPONSE_BLOCKS=1` at runtime
to disable it while investigating a problem.

## Local tests

`./build-debs-local.sh` runs the focused Swift suites and the
configuration-snapshot check before building both jailbreak packages
(rootless + roothide). Use `./build-debs-local.sh --skip-tests` to skip them.
The Spotify-version → hook-target map lives in `version-update-locations.txt`.

## The History

In January 2024, Spotilife, the only tweak to get Spotify Premium, stopped working on new Spotify versions. [whoeevee](https://github.com/whoeevee) decompiled Spotilife, reverse-engineered Spotify, intercepted requests, etc., and created this tweak.

In December 2025, whoeevee announced he'll be discontinuing the tweak because of the burden of keeping up with Spotify's constantly changing architectures. Soon after, [Skye](https://github.com/Meeep1) forked the original repo and continued development under the name EeveeSpotifyRevivedPublic.

In March 2026, EeveeSpotifyRevivedPublic users hit constant logout issues with no fix in sight. I forked it, fixed the logout problem, and that fork became the upstream [EeveeSpotifyReincarnated](https://github.com/SideloadLabs/EeveeSpotifyReincarnated) project, now maintained by [jaydenjcpy](https://github.com/jaydenjcpy), [Ryuk](https://github.com/faroukbmiled) and [Mod4](https://github.com/M0d-4).

This repository is my clean fork of that project: same roots, my own direction —
the lyrics rework, the no-block login protection, no bloat, release-like builds.
See [How this fork differs](#how-this-fork-differs-from-upstream) for the full list.

## Restrictions

Please refrain from opening issues about the following features, as they are server-sided and will **NEVER** work:

- Very High audio quality
- Native playlist downloading (you can download podcast episodes though)
- Jam (hosting a Spotify Jam and joining it remotely requires Premium; only joining in-person works)
- AI DJ/Playlist
- Spotify Connect (When using Spotify Connect, the device will act as a remote control and stream directly to the connected device. This is a server-sided limitation and is beyond the control of EeveeSpotify, so it will behave as if you have a Free subscription while using this feature.)

## [Common Issues](common_issues.md)
Please check out the page above before opening an issue.

## How It Works

EeveeSpotify intercepts Spotify requests to load user data, deserializes it, and modifies the parameters in real-time. This method works incredibly stable across supported Spotify versions.

The tweak also sets `trackRowsEnabled` to `true`, allowing you to see track rows and liked tracks on artist pages just like with Premium.

Supported targets: `8.9.8` (last for iOS 14), `9.0.48` (last for iOS 15),
`9.1.x`, and newer (`latest`, forward-compatible). Details in
`version-update-locations.txt`.

## Installation

For sideloaded IPAs, we recommend using **SideStore** or certificate-based signing tools like **Ksign** for best compatibility.

To open Spotify links in sideloaded app, use [OpenSpotifySafariExtension](https://github.com/BillyCurtis/OpenSpotifySafariExtension). Remember to activate it and allow access in Settings > Safari > Extensions.

## Credits
Thanks for all of the community's support, also, thanks to all the devs who worked along with me to revive this project Go check the other dev's out:

[Ryuk](https://github.com/faroukbmiled)

[Mod4](https://github.com/M0d-4)

[estrogencat](https://github.com/estrogencat)

[Skye](https://github.com/Meeep1)

[whoeevee](https://github.com/whoeevee)

## Disclaimer

This project is an **independent modification (tweak)** for the Spotify app. We are **not affiliated, associated, authorized, endorsed by, or in any way officially connected with Spotify**, or any of its subsidiaries or affiliates.

This tweak is created solely for **personal and educational purposes**. Use it at your own risk.

**We do not take any responsibility for any issues, damages, or consequences** resulting from the use or misuse of this tweak. If something breaks, it's not our problem.

## Star History

<a href="https://www.star-history.com/?repos=nodzen%2FEeveeSpotifyReincarnatedClean&type=date&legend=top-left">
  <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=nodzen/EeveeSpotifyReincarnatedClean&type=date&legend=top-left" />
</a>
