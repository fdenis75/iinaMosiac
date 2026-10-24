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

  @objc private func performCommand(_ sender: NSMenuItem) {
    guard let command = Command(rawValue: sender.tag) else { return }
    MosaicActions.generate(command.kind, for: command.scope, player: PlayerCore.lastActive)
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    guard let command = Command(rawValue: menuItem.tag) else { return false }
    return MosaicActions.canRun(command.scope, player: PlayerCore.lastActive)
  }
}
