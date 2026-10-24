# Implementation plan: MosaicKit in iinaMosaic

Goal and scope are in [`intent.md`](../../intent.md). This document records what the analysis of
both codebases found, the architecture chosen, and the phases to build it. It is a plan only: no
code has been written yet.

Analysed versions: iinaMosaic `develop` at `61f97fa` (IINA 1.5.1, build 180, October 2026) and
MosaicKit `main` at `0b5af02` (release 1.13.0).

---

## 1. Findings

### 1.1 IINA, the parts that matter here

| Area | Where | What it means for the integration |
|---|---|---|
| Player instances | `iina/PlayerCore.swift` | One `PlayerCore` per window. `PlayerCore.active` / `lastActive` give the focused player (main thread only). |
| Current file | `PlayerCore.info.currentURL` (`iina/PlaybackInfo.swift`) | A `URL`; `info.isNetworkResource` tells file vs stream. Set in `fileStarted(path:)`. |
| Playlist | `PlayerCore.info.playlist: [MPVPlaylistItem]`, guarded by `@Atomic` (`info.$playlist.withLock { … }`) | Items carry `filename` (a path or URL string) and `isNetworkResource`. Must be snapshotted under the lock. |
| Main menu | `iina/Base.lproj/MainMenu.xib`, wired in `iina/MenuController.swift` (`bindMenuItems()`), actions in `iina/MainMenuActions.swift` (`MainMenuActionHandler`) | Editing the xib causes merge conflicts with upstream and its ~60 localized copies. Insert our submenu in code instead. |
| Key bindings | `iina/IINACommand.swift` (`iina-command` names such as `save-playlist`) | New commands make our actions bindable in the key-binding settings. |
| Playlist sidebar | `iina/SidebarPlaylistPane.swift`, `buildMenu(forRows:)` and `menuNeedsUpdate(_:)` | The row context menu is rebuilt each time; one hook adds a "Mosaic" section for the clicked/selected rows. |
| Settings | New page-based system: `iina/SettingsWindow.swift` lists `SettingsPage` subclasses (`SettingsPageUtilities` is a compact example), each with its own localization table | A new `SettingsPageMosaic` slots in with one line in the page list. |
| Preferences | `iina/Preference.swift`: `Preference.Key` statics + `defaultPreference` dictionary | New keys use a `mosaic` prefix and are registered with defaults. |
| On-screen messages | `PlayerCore.sendOSD(_:)` with `OSDMessage.custom(String)` / `.customWithDetail` (`iina/OSDMessage.swift`) | Enough for "Mosaic started / saved / failed" feedback without a new OSD case. |
| Thumbnails | `iina/ThumbnailCache.swift`, `iina/FFmpegController.m` (bundled libav) | IINA already decodes frames with its own FFmpeg for the seek-bar preview. Not used by MosaicKit, but relevant for phase 8. |
| Plugins | `iina/JavascriptAPI*.swift`, docs.iina.io | JS plugins get menu, playlist context-menu, sidebar and `utils.exec`, but no access to native Swift packages. |
| Build | `iina.xcodeproj` (objectVersion 54, no synchronized folders), `Configs/*.xcconfig`, SPM packages Sparkle/PromiseKit/GRMustache/Just, mpv dylibs fetched by `other/download_libs.sh` | **`MACOSX_DEPLOYMENT_TARGET = 12`** (`Configs/Deployment.xcconfig`), **`SWIFT_VERSION = 5.0`** (`Configs/Shared.xcconfig`). Hardened runtime, no sandbox (`iina/IINA.entitlements`). No unit-test target. |

### 1.2 MosaicKit, the parts that matter here

| Area | API | Notes for IINA |
|---|---|---|
| Platform | `Package.swift`: macOS 26, Swift tools 6.2 | **The blocker**: an Xcode target cannot link an SPM product whose minimum platform is above its own deployment target. |
| Input | `VideoSource(url:).inspect()` / `VideoInput(from:)` (throwing, async) | AVFoundation only, local files. Throws `MosaicError.invalidVideo` for files it cannot read: this is our preflight. |
| Mosaic | `MosaicGeneratorCoordinator<MetalMosaicGenerator>` via `createDefaultMosaicCoordinator(concurrencyLimit:)`; `generateMosaic(for:config:progressHandler:)`, `generateMosaicsforbatch(videos:config:progressHandler:)`, `cancelGeneration(for:)`, `cancelAllGenerations()` | Per-video failures come back as results; a cancelled batch throws `CancellationError`. Progress is `MosaicGenerationProgress` (0…1, monotonic since 1.13, `MosaicGenerationStatus`). |
| Preview | `PreviewGeneratorCoordinator`; `generatePreview(for:config:progressHandler:)`, `generatePreviewsForBatch(…)` | File export only for IINA: `generateComposition` returns an `AVPlayerItem`, which mpv cannot play. |
| Config | `MosaicConfiguration`, `PreviewConfiguration` (Codable, Sendable) | Defaults to note: `animatedFormat` is `.webp` (needs `MosaicKitWebP.register()`), `gifMode` `.disabled`, `overwrite` `false`, output next to the video in a `{configurationHash}` subfolder. |
| Output | `OutputTransaction` (staging + rename) | No partial files on cancel or failure. Skip-if-exists when `overwrite == false`. |
| Background | `PreviewConfiguration.enableAppLifecycleMonitor` (default `true`) | **On macOS it treats "app not active" as background** (`AppLifecycleMonitor` listens to `NSApplication.didResignActiveNotification`) and pauses preview export until IINA is frontmost again. IINA must set it to `false`. |
| Known issue | I-26: native preview export can stall under macOS background scheduling | IINA is a foreground GUI app, so it is less exposed than a CLI, but the jobs window must show a stalled job and allow cancel. |
| WebP | Separate product `MosaicKitWebP` | Optional. Not linked in v1; the UI must not offer `.webp` and the config must set `animatedFormat` explicitly. |

### 1.3 Consequences

1. **Deployment target.** iinaMosaic must move to macOS 26 to link MosaicKit (decision D1, decided: yes). It
   is the smallest change and the fork is personal; upstream IINA keeps supporting 12. The
   alternatives are worse: an embedded framework at 26 weak-linked from a 12 app needs
   `@available` everywhere and still only works on 26; a JS plugin driving an external CLI (for
   example Tessera's) keeps IINA unchanged but cannot show native progress, cannot see playlist
   selection state beyond what the plugin API offers, and adds a second app to install.
2. **Language mode.** The app stays in Swift 5 mode. MosaicKit compiles as its own module in
   Swift 6 mode; calling its actors from Swift 5 code with `Task { await … }` is fine. Xcode 26
   is required (it is anyway for macOS 26).
3. **Format coverage gap.** mpv plays far more than AVFoundation reads. v1 filters by preflight
   (`inspect()`), not by extension, and reports skipped files.
4. **Merge hygiene.** All new code goes to `iina/Mosaic/`. Existing files get small hooks, each
   marked `// iinaMosaic:` so they are easy to find when merging upstream.

---

## 2. Architecture

```
 IINA UI (main thread)                          iina/Mosaic/                     MosaicKit
 ─────────────────────                          ────────────                     ─────────
 Main menu "Mosaic" submenu ─┐
 IINACommand key bindings ───┼──▶ MosaicActions ──▶ MosaicInputResolver ──▶ VideoSource.inspect()
 Playlist context menu ──────┘        │                  (snapshot + preflight)
                                      ▼
                               MosaicJobCenter (@MainActor, ObservableObject-like)
                                      │   owns jobs, Task handles, progress
                                      ├──▶ MosaicSettings ──▶ MosaicConfiguration / PreviewConfiguration
                                      ├──▶ MosaicGeneratorCoordinator<MetalMosaicGenerator>
                                      └──▶ PreviewGeneratorCoordinator
                                      │
 OSD messages ◀───────────────────────┤
 Jobs window (MosaicJobsWindowController) ◀──┘
 Settings page (SettingsPageMosaic) ──▶ Preference keys ──▶ MosaicSettings
```

### 2.1 New types (all in `iina/Mosaic/`)

| Type | Kind | Responsibility |
|---|---|---|
| `MosaicJobKind` | enum | `.mosaic`, `.preview` |
| `MosaicJob` | final class, main-actor | One request: kind, origin player (weak), inputs, per-file items (`pending / skipped(reason) / running(progress, phase) / done(URL) / failed(Error) / cancelled`), overall state, the `Task` handle. |
| `MosaicInputResolver` | struct | Turns "current file", "whole playlist" or "these playlist rows" into file URLs. Snapshots under `info.$playlist.withLock`, drops network items, dedupes, then runs `VideoSource(url:).inspect()` with bounded concurrency (2) and returns `[VideoInput]` plus `[(URL, reason)]` skipped. |
| `MosaicSettings` | struct | Reads `Preference` keys and builds `MosaicConfiguration` and `PreviewConfiguration`. Pins the values IINA must control: `enableAppLifecycleMonitor = false`, `animatedFormat` never `.webp`, `exportMode` never `.ffmpeg` unless a binary path is set. Pure, so it is the first thing worth unit-testing. |
| `MosaicJobCenter` | final class, `@MainActor`, singleton | Creates the coordinators lazily (`createDefaultMosaicCoordinator(concurrencyLimit:)`, `PreviewGeneratorCoordinator(concurrencyLimit:)`), runs jobs in `Task(priority: .utility)`, forwards progress to the main actor (throttled to ~10 Hz per job), posts a `Notification` on change, sends OSD messages to the origin player, cancels one job (`cancelGeneration(for:)` per video) or all (`cancelAllGenerations()`), and cancels everything on app termination. |
| `MosaicActions` | enum / small class | The menu and command entry points: `mosaicCurrent(player:)`, `mosaicPlaylist(player:rows:)`, `previewCurrent(player:)`, `previewPlaylist(player:rows:)`, `showJobs()`. Validates (no file loaded, network stream, empty playlist) and shows an OSD explanation instead of doing nothing. |
| `MosaicMenuBuilder` | enum | Builds the main-menu submenu and the playlist context-menu section; menu validation (disabled with no player/file). |
| `MosaicJobsWindowController` | `NSWindowController` hosting a SwiftUI view (`NSHostingView`; macOS 26 is guaranteed) | List of jobs and per-file rows, progress bars, Cancel / Cancel All, Reveal in Finder, Open, Play preview in IINA, copy error. Session-only history. |
| `SettingsPageMosaic` | `SettingsPage` subclass | The settings UI (section 2.4) with its own localization table `SettingsMosaicLocalizable`. |

### 2.2 Hook points in existing IINA files

Keep each one to a few lines, marked `// iinaMosaic:`.

| File | Change |
|---|---|
| `Configs/Deployment.xcconfig` | `MACOSX_DEPLOYMENT_TARGET = 26` (D1). |
| `iina.xcodeproj/project.pbxproj` | MosaicKit package reference (`https://github.com/fdenis75/MosaicKit`, up to next minor from 1.13.0), product linked to the `iina` target, `iina/Mosaic` group. |
| `iina/MenuController.swift` | In `bindMenuItems()`, insert the "Mosaic" submenu built by `MosaicMenuBuilder` (under the File menu, after "Show in Finder", or as its own top-level menu: D3). |
| `iina/IINACommand.swift` + its dispatcher (`PlayerWindowController`, where `IINACommand(rawValue:)` is matched) | `mosaic-current`, `mosaic-playlist`, `preview-current`, `preview-playlist`, `mosaic-jobs`. |
| `iina/SidebarPlaylistPane.swift` | In `buildMenu(forRows:)`, append the "Mosaic" section for the target rows (only for non-network rows). |
| `iina/SettingsWindow.swift` | Add `SettingsPageMosaic()` to the page list. |
| `iina/Preference.swift` | `Preference.Key` statics and defaults for the `mosaic*` keys. |
| `iina/AppDelegate.swift` | On `applicationShouldTerminate`, if jobs are running, ask once and cancel them (reuse IINA's existing termination flow). |

### 2.3 Threading and performance

- IINA's UI and `PlayerCore` APIs are main-thread; MosaicKit's engines are actors. Everything in
  `MosaicJobCenter` is `@MainActor`; work starts in `Task(priority: .utility)`; progress handlers
  (`@Sendable`) hop back with `Task { @MainActor in … }`.
- Mosaic generation uses VideoToolbox decode and Metal at the same time as mpv playback. Defaults:
  mosaic concurrency **1**, preview concurrency **1**, configurable up to 4. Measure on a 4K HEVC
  file playing while a 40-file batch runs (phase 7) before raising them.
- Never block the main thread on MosaicKit: no `await` in menu validation, no synchronous
  `inspect()`.
- Read the playlist only inside `withLock` and copy out `filename`s; never hold the lock across an
  `await`.

### 2.4 Settings (initial set)

| Group | Setting | Preference key | Default | Maps to |
|---|---|---|---|---|
| Output | Save location | `mosaicOutputLocation` | next to video | `outputdirectory` / `outputDirectory` = `nil` |
| Output | Custom folder | `mosaicOutputFolder` | `~/Movies/IINA Mosaics` | same, when location = custom |
| Output | Overwrite existing | `mosaicOverwrite` | off | `overwrite` (both) |
| Output | When finished | `mosaicOnFinish` | show OSD | OSD / reveal in Finder / open |
| Mosaic | Width | `mosaicWidth` | 5120 | `width` |
| Mosaic | Density | `mosaicDensity` | M | `density` |
| Mosaic | Layout | `mosaicLayout` | custom | `layout.layoutType` (fixed grid adds rows/columns) |
| Mosaic | Aspect ratio | `mosaicAspectRatio` | 16:9 | `layout.aspectRatio` |
| Mosaic | Format / quality | `mosaicFormat`, `mosaicQuality` | HEIF, 0.4 | `format`, `compressionQuality` |
| Mosaic | Header, frame labels | `mosaicIncludeHeader`, `mosaicFrameLabels` | on, timestamp | `includeMetadata`, `overlay.frameLabel` |
| Mosaic | Animated version | `mosaicAnimated` | off | `gifMode`, `animatedFormat` (.gif/.heic) |
| Preview | Length | `mosaicPreviewDuration` | 60 s | `targetDuration` |
| Preview | Clip density | `mosaicPreviewDensity` | M | `density` |
| Preview | Audio | `mosaicPreviewAudio` | on | `includeAudio` |
| Preview | Max resolution / quality | `mosaicPreviewMaxResolution`, `mosaicPreviewQuality` | 1080p, 0.8 | `exportMaxResolution`, `compressionQuality` |
| Preview | Encoder | `mosaicPreviewExportMode` | native | `exportMode` (`.sjs`; `.ffmpeg` only with a path) |
| Advanced | Concurrency | `mosaicConcurrency`, `mosaicPreviewConcurrency` | 1, 1 | coordinator limits |

An "Advanced: import/export settings as JSON" option is cheap later because both configurations
are Codable, and it would let iinaMosaic share settings with Tessera.

### 2.5 Behaviour details

- **Current video**: uses `PlayerCore.lastActive` (the player whose window was last key), so the
  command works from the menu bar even when the jobs window is focused.
- **Playlist**: from the main menu, all items of that player's playlist; from the sidebar, the
  clicked/selected rows. Order is playlist order.
- **Already generated**: with overwrite off, MosaicKit returns the existing file immediately; the
  row shows "Already exists" (detected by the result arriving without passing through extraction).
- **Finished preview**: "Play" opens it with `PlayerCore.newPlayerCore.openURL(_:)`; optional
  "add to playlist" later.
- **Finished mosaic**: OSD `customWithDetail("Mosaic saved", filename)`; Reveal uses
  `NSWorkspace.shared.activateFileViewerSelecting`; Open uses `NSWorkspace.shared.open`.
- **Errors**: one line per file in the jobs window using `localizedDescription` of the typed
  MosaicKit errors (`MosaicError`, `VideoError`, `PreviewError`); cancelled is shown as
  cancelled, never as failed (MosaicKit reports `.cancelled`).

---

## 3. Phases

Each phase ends in a buildable, usable app and is one PR into `develop` of iinaMosaic.

### Phase 0: build foundation

**Status:** done (#2), verified on Xcode 27.1 / macOS 26.
- Raise the deployment target to macOS 26; fix any new deprecation errors this exposes
  (warnings are acceptable; `#available(macOS 12…14)` branches can stay for upstream parity).
- Add the MosaicKit package (1.13.0, up to next minor) to the `iina` target.
- Add `iina/Mosaic/` with a single debug-only menu item that generates a mosaic of the current file
  with default settings, to prove linking, Metal shader resources and code signing (hardened
  runtime) work in a Release build.
- Document in the fork's README: macOS 26 + Xcode 26 required, `other/download_libs.sh` unchanged.

**Done when** a Release build launches on macOS 26, plays video, and writes a mosaic.

### Phase 1: core service
- `MosaicJob`, `MosaicJobCenter`, `MosaicInputResolver`, `MosaicSettings` (hard-coded defaults
  for now, read from `Preference` in phase 6).
- Preflight with `VideoSource.inspect()`; skip reasons: network resource, file missing,
  AVFoundation cannot read it, no video track.
- Cancel-all on termination.

**Status:** done (#3). Jobs of the same kind run one after the other (a second request queues
behind the first); the experimental File menu command now goes through `MosaicJobCenter`. The
unit-test target moved to phase 7: adding a test target by hand to `project.pbxproj` is better done
from Xcode.

### Phase 2: mosaic of the current video
- `MosaicMenuBuilder` submenu (Generate Mosaic, plus disabled placeholders for the rest),
  `mosaic-current` command, OSD start/finish/fail, Reveal/Open action per `mosaicOnFinish`.

**Status:** done (#4). Since the phase 1 service already handled playlists and previews, the
submenu (`MosaicMenu`, File ▸ Mosaic) enables all four commands at once: mosaic or preview, of the
current video or of the playlist, plus the `mosaic-current`, `mosaic-playlist`,
`preview-current` and `preview-playlist` key-binding commands (`MosaicActions`). Results are
revealed in Finder until the jobs window (phase 5) and the `mosaicOnFinish` setting (phase 6)
exist. Phase 3 still adds the playlist sidebar context menu; phase 4 adds "Play preview".

### Phase 3: mosaics for the playlist
- `mosaic-playlist` command and menu item, playlist sidebar context-menu section, batch via
  `generateMosaicsforbatch`, skipped-files summary (OSD "12 mosaics, 3 skipped" with details in
  the jobs window).

**Status:** in review. The playlist sidebar's right-click menu gets a "Mosaic" section with
"Generate Mosaic(s)" and "Generate Preview(s)" for the clicked or selected rows
(`MosaicActions.Scope.playlistRows`, `MosaicMenu.playlistContextMenuItems`). Network rows are
skipped, and the section is disabled when every target row is a network resource. The command,
the menu item and the batch summary OSD shipped in phase 2.

### Phase 4: previews (current and playlist)
- `PreviewGeneratorCoordinator`, `preview-current` / `preview-playlist`, context-menu entries,
  `enableAppLifecycleMonitor = false`, "Play preview" action.

### Phase 5: jobs window
- SwiftUI list hosted in `MosaicJobsWindowController`; Window menu entry and `mosaic-jobs`
  command; per-job and global cancel; per-file status, progress and errors.
- Optional: a small progress indicator in the playlist sidebar header while a job runs.

### Phase 6: settings page
- `SettingsPageMosaic` with the section 2.4 options, `Preference` keys and defaults, and the
  `MosaicSettings` mapping. Settings search (`SettingsSearch.swift`) picks the page up through its
  localization table.

### Phase 7: polish and verification
- English strings in a dedicated table (no Crowdin churn); other languages fall back to English.
- Performance check from section 2.3 and tuning of the defaults.
- Manual QA matrix (section 4) on Apple silicon.
- Fork README section: features, settings, known limits.

### Phase 8 (later, optional)
- **Formats mpv plays but AVFoundation cannot.** Two routes, to be decided with data:
  (a) a MosaicKit change adding a frame-source abstraction that IINA feeds from its bundled libav
  (`FFmpegController`), done in the MosaicKit repo with its own plan item and migration note; or
  (b) for MKV/WebM holding H.264/HEVC, a temporary passthrough remux to `.mov` before handing it to
  MosaicKit. (b) is simpler but needs an ffmpeg binary or libavformat remux code in IINA.
- Show the mosaic of the current file inside IINA (overlay or sidebar pane) and seek by clicking a
  tile (frame index × interval gives the timestamp).
- Expose `iina.mosaic` to JS plugins.
- Link `MosaicKitWebP` if WebP output is wanted.

---

## 4. Verification

There is no test target in IINA today. Plan:

- **Unit tests (a small `iinaMosaicTests` target, created in Xcode in phase 7):** `MosaicSettings` mapping
  (each preference → config field, pinned values), and `MosaicInputResolver` filtering with a fake
  playlist (network items, duplicates, missing files).
- **Manual QA matrix (phase 7):**

| Case | Expected |
|---|---|
| H.264 MP4 playing, mosaic current | Mosaic written next to the file, OSD shown, playback smooth |
| HEVC 4K MOV playing, preview current | Preview written; Play opens it in a new window |
| MKV / WebM / AVI in playlist | Listed as skipped with reason, others processed |
| Network stream playing | Commands disabled or OSD explains why |
| 40-file playlist, mosaics, while playing 4K | No dropped frames visible, UI responsive |
| Cancel one file, then cancel all | Cancelled rows, no partial files, batch stops |
| Switch to another app during preview export | Export keeps going (lifecycle monitor off) |
| Quit during a batch | One confirmation, work cancelled, no leftovers |
| Overwrite off, run twice | Second run reports "already exists" quickly |
| Read-only video folder | Clear write error; custom output folder works |

---

## 5. Decisions

| ID | Question | Recommendation |
|---|---|---|
| D1 | Raise iinaMosaic's deployment target to macOS 26 to link MosaicKit? | **Decided 2026-10-24: yes** (François). Personal fork; MosaicKit cannot go lower; the alternatives (weak-linked framework, JS plugin + CLI) cost more and still need macOS 26 for the feature. |
| D2 | Default output location | Next to the video (MosaicKit's default, matches Tessera), with a custom-folder option. |
| D3 | Menu placement | A "Mosaic" submenu in the File menu (near Save Playlist / Show in Finder); revisit a top-level menu if it grows. |
| D4 | WebP in v1 | No; offer HEIF/JPEG/PNG and GIF/HEICS animations. Linking `MosaicKitWebP` later is one line plus `register()`. |
| D5 | Non-AVFoundation formats | Skip and report in v1; decide phase 8's route after seeing how many files in real playlists are skipped. |
| D6 | Fork naming | Keep the IINA bundle id and name for now; consider a distinct bundle id (`…iinaMosaic`) so it can sit next to stock IINA. Needs a choice before the first distributed build because it changes where preferences live. |

---

## 6. Upstream sync rules

- Merge `iina/iina` `develop` into the fork regularly; conflicts should only appear at the hook
  points in section 2.2.
- Never edit `MainMenu.xib` or the `*.lproj` copies for this feature.
- If upstream raises its own deployment target or changes `SettingsPage` / sidebar APIs, update
  the hook points and note it here.
