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

    var kind: MosaicJobKind {
      switch self {
      case .mosaicCurrent, .mosaicPlaylist: return .mosaic
      case .previewCurrent, .previewPlaylist: return .preview
      }
    }

    var scope: MosaicActions.Scope {
      switch self {
      case .mosaicCurrent, .previewCurrent: return .currentFile
      case .mosaicPlaylist, .previewPlaylist: return .playlist
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
    return items
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
    MosaicActions.generate(command.kind, for: command.scope, player: PlayerCore.lastActive)
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if let command = menuItem.representedObject as? PlaylistRowsCommand {
      return command.player != nil
    }
    guard let command = Command(rawValue: menuItem.tag) else { return false }
    return MosaicActions.canRun(command.scope, player: PlayerCore.lastActive)
  }
}
