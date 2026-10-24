//
//  MosaicDebugAction.swift
//  iina
//
//  iinaMosaic: the experimental File menu command from phase 0 of
//  docs/mosaickit/IMPLEMENTATION_PLAN.md. Since phase 1 it goes through MosaicJobCenter, so it
//  exercises the job queue, the MosaicKit preflight and the on-screen summary. Phase 2 replaces it
//  with the Mosaic submenu.
//

import Cocoa

@MainActor
class MosaicDebugAction: NSObject, NSMenuItemValidation {

  static let shared = MosaicDebugAction()

  func makeMenuItem() -> NSMenuItem {
    let item = NSMenuItem(title: "Generate Mosaic of Current Video (Experimental)",
                          action: #selector(generateMosaic(_:)), keyEquivalent: "")
    item.target = self
    return item
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    PlayerCore.lastActive.info.currentURL?.isFileURL ?? false
  }

  @objc func generateMosaic(_ sender: NSMenuItem) {
    let player = PlayerCore.lastActive
    let candidates = MosaicInputResolver.currentFile(of: player)
    guard !candidates.isEmpty else { return }
    player.sendOSD(.custom("Generating mosaic…"))
    MosaicJobCenter.shared.start(.mosaic, candidates: candidates, player: player) { job in
      if job.items.count == 1, let output = job.outputs.first {
        NSWorkspace.shared.activateFileViewerSelecting([output])
      }
    }
  }
}
