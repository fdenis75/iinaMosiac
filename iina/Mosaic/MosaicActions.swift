//
//  MosaicActions.swift
//  iina
//
//  iinaMosaic: the user-facing commands (menu items and key-binding commands) that start mosaic
//  and preview jobs. See docs/mosaickit/IMPLEMENTATION_PLAN.md, sections 2.1 and 2.5.
//

import Cocoa

@MainActor
enum MosaicActions {

  /// Which files of a player a command works on.
  enum Scope {
    case currentFile
    case playlist
    /// Some rows of the playlist, from the playlist sidebar's context menu.
    case playlistRows(IndexSet)
  }

  /// Whether `player` has something the command can work on: a local file playing, or at least
  /// one local file in the playlist.
  static func canRun(_ scope: Scope, player: PlayerCore) -> Bool {
    switch scope {
    case .currentFile:
      return player.info.currentURL?.isFileURL ?? false
    case .playlist:
      return player.info.$playlist.withLock { playlist in
        playlist.contains { item in !item.isNetworkResource }
      }
    case .playlistRows(let rows):
      return player.info.$playlist.withLock { playlist in
        rows.contains { $0 < playlist.count && !playlist[$0].isNetworkResource }
      }
    }
  }

  /// The preview generated in this session for the file playing in `player`, if any.
  static func previewOfCurrentFile(of player: PlayerCore) -> URL? {
    guard let url = player.info.currentURL, url.isFileURL else { return nil }
    return MosaicJobCenter.shared.latestPreview(for: url)
  }

  /// Plays the preview of the file playing in `player` in a new player window, and pauses
  /// `player` so the two do not play over each other.
  static func playPreviewOfCurrentFile(of player: PlayerCore) {
    guard let preview = previewOfCurrentFile(of: player) else {
      player.sendOSD(.customWithDetail("No preview yet", "Generate a preview of this video first"))
      return
    }
    playPreview(preview, pausing: player)
  }

  /// Plays `preview` in a new player window and pauses `player`.
  static func playPreview(_ preview: URL, pausing player: PlayerCore?) {
    player?.pause()
    // No folder autoload: previews sit beside their source videos, which would otherwise be
    // added to the playlist and play after the preview.
    PlayerCore.newPlayerCore.openURL(preview, shouldAutoLoad: false)
  }

  /// Starts a mosaic or preview job for the current file or the playlist of `player`.
  static func generate(_ kind: MosaicJobKind, for scope: Scope, player: PlayerCore) {
    let candidates: [MosaicInputResolver.Candidate]
    switch scope {
    case .currentFile: candidates = MosaicInputResolver.currentFile(of: player)
    case .playlist: candidates = MosaicInputResolver.playlist(of: player)
    case .playlistRows(let rows): candidates = MosaicInputResolver.playlist(of: player, rows: rows)
    }
    guard !candidates.isEmpty else {
      if case .currentFile = scope {
        player.sendOSD(.custom("No video is playing"))
      } else {
        player.sendOSD(.custom("The playlist is empty"))
      }
      return
    }

    let noun = kind == .mosaic ? "mosaic" : "preview"
    let count = candidates.filter { $0.skipReason == nil }.count
    player.sendOSD(.custom(count > 1 ? "Generating \(count) \(noun)s…" : "Generating \(noun)…"))

    MosaicJobCenter.shared.start(kind, candidates: candidates, player: player) { job in
      // Until the jobs window exists (phase 5), show the results in Finder. A preview of the
      // current video is ready to play from File ▸ Mosaic ▸ Play Preview of Current Video.
      let outputs = job.outputs
      if !outputs.isEmpty {
        NSWorkspace.shared.activateFileViewerSelecting(outputs)
      }
    }
  }
}
