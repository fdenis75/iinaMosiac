# Intent: MosaicKit in iinaMosaic

## Why this fork exists

iinaMosaic is a personal fork of [IINA](https://github.com/iina/iina), the mpv-based video player
for macOS. It adds one thing upstream IINA does not have: turning what you are watching into
**visual summaries**, using [MosaicKit](https://github.com/fdenis75/MosaicKit), the Swift package
that already powers the Tessera app.

A mosaic (contact sheet) answers "what is in this video?" in one image. A preview (highlight reel)
answers it in a minute of video. Both are most useful at the moment you are already looking at the
file, or at a folder of files in a playlist, which is exactly where IINA is.

## What the user can do

1. **Mosaic of the current video.** While a video plays, one menu command (or key binding) writes
   a mosaic of that file using the saved mosaic settings. Playback is not interrupted. When it is
   done, IINA says so on screen and can reveal or open the image.
2. **Mosaics for the playlist.** One command generates a mosaic for every playable file in the
   current window's playlist, or for the rows selected in the playlist sidebar. Files that cannot
   be processed are skipped and listed, never silently dropped.
3. **Preview of the current video.** Same entry points, but MosaicKit's highlight-reel export. The
   finished preview can be played straight away in a new IINA window.
4. **Previews for the playlist.** Batch version of 3, for the whole playlist or the selection.
5. **See and control the work.** A small jobs window lists running and finished jobs with
   progress, lets the user cancel one job or all of them, and reveal results in Finder.
6. **Configure it once.** A "Mosaic" page in IINA Settings holds the mosaic and preview options
   (size, density, layout, format, header, output folder, preview length, audio, …).

## Principles

- **Playback comes first.** Generation runs in the background at low priority with conservative
  concurrency, and must never stall the player, the UI, or mpv.
- **MosaicKit is used as a library, unchanged.** iinaMosaic consumes tagged releases of MosaicKit
  (currently 1.13.x) through Swift Package Manager. If the integration needs something MosaicKit
  lacks, that is a MosaicKit change made in its own repo, with its own process (knowledge base,
  migration note, release), and then picked up here by bumping the version.
- **Stay close to upstream IINA.** The fork should keep merging `iina/iina` `develop` with little
  pain: new code lives in its own folder, and the existing IINA files get only small, well-marked
  hook points.
- **Honest about formats.** MosaicKit decodes with AVFoundation, so it handles fewer formats than
  mpv. Unsupported files (for example many `.mkv`, `.webm`, `.avi`) and network streams are
  reported as skipped with a reason, not attempted and failed.
- **No surprises on disk.** Outputs go to a predictable place (next to the video by default, or a
  folder the user picks), existing outputs are reused unless the user asks to overwrite, and
  cancelled work leaves no partial files (MosaicKit's staged publication already guarantees this).

## Out of scope for the first version

- Mosaics or previews of network streams, URLs, or `youtube-dl`/`yt-dlp` sources.
- Formats AVFoundation cannot read. A later phase may add them (see the plan, phase 8).
- A built-in image viewer for mosaics: results open in the system viewer or Quick Look.
- Exposing MosaicKit to IINA JavaScript plugins.
- Upstreaming any of this to `iina/iina`: MosaicKit requires macOS 26, which upstream IINA
  cannot adopt.

## Success looks like

- On macOS 26, a release build of iinaMosaic plays video exactly as IINA does, and the four
  commands above produce the same files MosaicKit/Tessera would produce for the same settings.
- A 40-file playlist can be processed while a video keeps playing smoothly.
- Merging a new upstream IINA release touches only the documented hook points.

The step-by-step plan is in
[docs/mosaickit/IMPLEMENTATION_PLAN.md](docs/mosaickit/IMPLEMENTATION_PLAN.md).
