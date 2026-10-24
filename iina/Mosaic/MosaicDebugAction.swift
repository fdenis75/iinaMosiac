//
//  MosaicDebugAction.swift
//  iina
//
//  iinaMosaic: phase 0 of docs/mosaickit/IMPLEMENTATION_PLAN.md.
//  A single File menu command that writes a mosaic of the current video with MosaicKit's default
//  settings. It proves that the package links, its Metal shaders load and the signed app can write
//  output. Phase 2 replaces it with the Mosaic submenu.
//

import Cocoa
import MosaicKit

@MainActor
class MosaicDebugAction: NSObject, NSMenuItemValidation {

  static let shared = MosaicDebugAction()

  private var isRunning = false

  func makeMenuItem() -> NSMenuItem {
    let item = NSMenuItem(title: "Generate Mosaic of Current Video (Experimental)",
                          action: #selector(generateMosaic(_:)), keyEquivalent: "")
    item.target = self
    return item
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    guard !isRunning, let url = PlayerCore.lastActive.info.currentURL else { return false }
    return url.isFileURL
  }

  @objc func generateMosaic(_ sender: NSMenuItem) {
    let player = PlayerCore.lastActive
    guard !isRunning, let url = player.info.currentURL, url.isFileURL else { return }
    isRunning = true
    player.sendOSD(.custom("Generating mosaic…"))
    Logger.log("Generating mosaic for \(url.path)", subsystem: subsystem)

    // MosaicKit's defaults, spelled out: `MosaicConfiguration()` is ambiguous between its
    // initializers. `animatedFormat` is set to `.gif` because the default, `.webp`, needs the
    // MosaicKitWebP product, which is not linked.
    let config = MosaicConfiguration(width: 5120, density: .m, format: .heif,
                                     gifMode: .disabled, animatedFormat: .gif)

    Task {
      defer { isRunning = false }
      do {
        let video = try await VideoInput(from: url)
        let generator = try MetalMosaicGenerator()
        let output = try await generator.generate(for: video, config: config)
        Logger.log("Mosaic saved to \(output.path)", subsystem: subsystem)
        player.sendOSD(.customWithDetail("Mosaic saved", output.lastPathComponent))
        NSWorkspace.shared.activateFileViewerSelecting([output])
      } catch {
        Logger.log("Mosaic failed: \(error)", level: .error, subsystem: subsystem)
        player.sendOSD(.customWithDetail("Mosaic failed", error.localizedDescription))
      }
    }
  }

  private let subsystem = Logger.makeSubsystem("mosaic")
}
