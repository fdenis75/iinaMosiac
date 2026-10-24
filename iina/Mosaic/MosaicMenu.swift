//
//  MosaicMenu.swift
//  iina
//
//  iinaMosaic: the File ▸ Mosaic submenu. It is built in code rather than in MainMenu.xib so
//  merging upstream IINA stays easy. See docs/mosaickit/IMPLEMENTATION_PLAN.md, section 2.2.
//

import Cocoa

@MainActor
final class MosaicMenu: NSObject, NSMenuItemValidation {

  static let shared = MosaicMenu()

  private enum Command: Int {
    case mosaicCurrent = 1
    case mosaicPlaylist
    case previewCurrent
    case previewPlaylist
    case playPreview

    /// The job a generate command starts; `nil` for Play Preview.
    var job: (kind: MosaicJobKind, scope: MosaicActions.Scope)? {
      switch self {
      case .mosaicCurrent: return (.mosaic, .currentFile)
      case .mosaicPlaylist: return (.mosaic, .playlist)
      case .previewCurrent: return (.preview, .currentFile)
      case .previewPlaylist: return (.preview, .playlist)
      case .playPreview: return nil
      }
    }
  }

  /// The "Mosaic" item with its submenu, to insert into the File menu.
  func makeMenuItem() -> NSMenuItem {
    let menu = NSMenu(title: "Mosaic")
    addItem(to: menu, title: "Generate Mosaic of Current Video", command: .mosaicCurrent)
    addItem(to: menu, title: "Generate Mosaics for Playlist", command: .mosaicPlaylist)
    menu.addItem(.separator())
    addItem(to: menu, title: "Generate Preview of Current Video", command: .previewCurrent)
    addItem(to: menu, title: "Generate Previews for Playlist", command: .previewPlaylist)
    addItem(to: menu, title: "Play Preview of Current Video", command: .playPreview)

    let item = NSMenuItem(title: "Mosaic", action: nil, keyEquivalent: "")
    item.submenu = menu
    return item
  }

  private func addItem(to menu: NSMenu, title: String, command: Command) {
    let item = NSMenuItem(title: title, action: #selector(performCommand(_:)), keyEquivalent: "")
    item.target = self
    item.tag = command.rawValue
    menu.addItem(item)
  }

  /// The "Mosaic" section of the playlist sidebar's context menu, for the clicked or selected
  /// `rows` of `player`'s playlist. Empty when none of the rows is a local file.
  func playlistContextMenuItems(for rows: IndexSet, of player: PlayerCore) -> [NSMenuItem] {
    let scope = MosaicActions.Scope.playlistRows(rows)
    guard MosaicActions.canRun(scope, player: player) else { return [] }
    let plural = rows.count > 1
    var items: [NSMenuItem] = []
    if #available(macOS 14.0, *) {
      items.append(.sectionHeader(title: "Mosaic"))
    }
    for kind in [MosaicJobKind.mosaic, .preview] {
      let noun = kind == .mosaic ? "Mosaic" : "Preview"
      let item = NSMenuItem(title: "Generate \(noun)\(plural ? "s" : "")",
                            action: #selector(performPlaylistRowsCommand(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = PlaylistRowsCommand(kind: kind, rows: rows, player: player)
      items.append(item)
    }
    if rows.count == 1, let row = rows.first, let preview = previewOfRow(row, of: player) {
      let item = NSMenuItem(title: "Play Preview", action: #selector(performPlayPreview(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = PlayPreviewCommand(preview: preview, player: player)
      items.append(item)
    }
    return items
  }

  /// The preview generated in this session for a local file at `row` of `player`'s playlist.
  private func previewOfRow(_ row: Int, of player: PlayerCore) -> URL? {
    let filename: String? = player.info.$playlist.withLock { playlist in
      guard row < playlist.count, !playlist[row].isNetworkResource else { return nil }
      return playlist[row].filename
    }
    guard let filename else { return nil }
    return MosaicJobCenter.shared.latestPreview(for: URL(fileURLWithPath: filename))
  }

  /// A preview to play from the playlist context menu.
  private final class PlayPreviewCommand {
    let preview: URL
    weak var player: PlayerCore?

    init(preview: URL, player: PlayerCore) {
      self.preview = preview
      self.player = player
    }
  }

  @objc private func performPlayPreview(_ sender: NSMenuItem) {
    guard let command = sender.representedObject as? PlayPreviewCommand else { return }
    MosaicActions.playPreview(command.preview, pausing: command.player)
  }

  /// What a playlist context-menu item works on.
  private final class PlaylistRowsCommand {
    let kind: MosaicJobKind
    let rows: IndexSet
    weak var player: PlayerCore?

    init(kind: MosaicJobKind, rows: IndexSet, player: PlayerCore) {
      self.kind = kind
      self.rows = rows
      self.player = player
    }
  }

  @objc private func performPlaylistRowsCommand(_ sender: NSMenuItem) {
    guard let command = sender.representedObject as? PlaylistRowsCommand,
          let player = command.player else { return }
    MosaicActions.generate(command.kind, for: .playlistRows(command.rows), player: player)
  }

  @objc private func performCommand(_ sender: NSMenuItem) {
    guard let command = Command(rawValue: sender.tag) else { return }
    if let job = command.job {
      MosaicActions.generate(job.kind, for: job.scope, player: PlayerCore.lastActive)
    } else {
      MosaicActions.playPreviewOfCurrentFile(of: PlayerCore.lastActive)
    }
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if let command = menuItem.representedObject as? PlaylistRowsCommand {
      guard let player = command.player else { return false }
      return MosaicActions.canRun(.playlistRows(command.rows), player: player)
    }
    if menuItem.representedObject is PlayPreviewCommand {
      return true
    }
    guard let command = Command(rawValue: menuItem.tag) else { return false }
    guard let job = command.job else {
      return MosaicActions.previewOfCurrentFile(of: PlayerCore.lastActive) != nil
    }
    return MosaicActions.canRun(job.scope, player: PlayerCore.lastActive)
  }
}
