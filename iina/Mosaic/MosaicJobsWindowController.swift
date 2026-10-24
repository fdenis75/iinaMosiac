//
//  MosaicJobsWindowController.swift
//  iina
//
//  iinaMosaic: the Mosaic Jobs window (Window ▸ Mosaic Jobs). It hosts MosaicJobsView, which lists
//  this session's jobs. See docs/mosaickit/IMPLEMENTATION_PLAN.md, section 2.1.
//

import Cocoa
import SwiftUI

@MainActor
final class MosaicJobsWindowController: NSWindowController {

  static let shared = MosaicJobsWindowController()

  private init() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: true)
    window.title = "Mosaic Jobs"
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 420, height: 240)
    window.contentView = NSHostingView(rootView: MosaicJobsView(model: MosaicJobsModel()))
    window.center()
    window.setFrameAutosaveName("IINAMosaicJobsWindow")
    super.init(window: window)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  /// Shows the window and makes it key.
  func show() {
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }
}
