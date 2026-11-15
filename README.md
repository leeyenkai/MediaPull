<p align="center">
  <img src="docs/images/icon.png" width="128" alt="MediaPull icon">
</p>

<h1 align="center">MediaPull</h1>

<p align="center">Collect images and videos from the web into your own folders, then search and organise them. A native Mac app that never uploads anything.</p>

![Collect: browse a page and every image on it appears, at its largest size](docs/images/collect.jpg)

## What it does

- **Collect from any page.** Browse in the built-in browser and every image, video and stream on the page appears, including what loads as you scroll, at the largest size available. Drag items into a folder or press ⌘S.
- **Download whole accounts and galleries.** Instagram accounts (posts, Reels, stories, highlights, sorted into folders by type), videos from YouTube and over a thousand other sites (format, resolution, playlists, subtitles), and galleries on the hundreds of sites gallery-dl supports.
- **Search what you have.** Find photos by what they show ("dog on a beach"), by text in them, or by place, colour, faces, camera and more. Analysis runs entirely on your Mac.
- **Organise any folder.** Sort by date, event, source, subject or person, see the result before anything moves, and undo it all with ⌘Z. Sort in place or into a separate folder, leaving the original untouched.
- **Recognise people** (off until you turn it on). Name a person once; a folder named after someone is offered as their name.
- **Normal formats.** WebP, AVIF and HEIC become JPEG or PNG; videos are MP4. Each file can keep its caption, date and source in a small metadata file.

| Organise | Downloads |
|---|---|
| ![Organise: sort a folder by subject with a preview](docs/images/organise.jpg) | ![Downloads: choose a video's format and resolution](docs/images/downloads.jpg) |

## Install

Download `MediaPull-1.6.dmg` from [Releases](https://github.com/leeyenkai/MediaPull/releases) and drag MediaPull to Applications. Requires macOS 26 or later on Apple silicon.

The app is not notarized, so the first time, right-click MediaPull and choose Open.

## Build from source

Requires Xcode 27.

```bash
./scripts/install-app.sh
```

This fetches and verifies the bundled engines (Python with gallery-dl and yt-dlp), builds a minimal ffmpeg, converts the analysis models, and installs the app in `~/Applications`. `./scripts/check.sh` runs the tests; `./scripts/make-dmg.sh` builds the disk image. The full specification is in [docs/SPEC.md](docs/SPEC.md).

## Privacy

MediaPull only reads from the web: it never uploads files and never likes, follows or posts. Photo analysis, face recognition and place names are computed on your Mac and stored in MediaPull's own data, never in your folders. Face data can be deleted in one step.

## Notes

- Instagram needs you signed in (in MediaPull's browser) to list an account's posts. Automated collection may breach a site's terms; MediaPull paces its requests.
- Bundled components keep their own licences: gallery-dl (GPL-2.0), yt-dlp (Unlicense), Python (PSF), ffmpeg (LGPL-2.1), GeoNames place data (CC BY 4.0), and the analysis models listed in [docs/spikes/analysis-models.md](docs/spikes/analysis-models.md), some of which are for non-commercial or research use only.
