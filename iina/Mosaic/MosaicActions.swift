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
      // Until the jobs window exists (phase 5), show the results in Finder.
      let outputs = job.outputs
      if !outputs.isEmpty {
        NSWorkspace.shared.activateFileViewerSelecting(outputs)
      }
    }
  }
}
