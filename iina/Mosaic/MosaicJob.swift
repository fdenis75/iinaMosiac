//
//  MosaicJob.swift
//  iina
//
//  iinaMosaic: one mosaic or preview request and the state of each of its files.
//  See docs/mosaickit/IMPLEMENTATION_PLAN.md, section 2.1.
//

import Foundation
import MosaicKit

enum MosaicJobKind {
  case mosaic
  case preview
}

/// State of one file in a job.
enum MosaicItemState {
  /// Waiting for inspection or for a free generation slot.
  case pending
  /// Never attempted: network resource, missing file, or AVFoundation cannot read it.
  case skipped(reason: String)
  case running(progress: Double, phase: String)
  case done(URL)
  case failed(message: String)
  case cancelled

  var isFinal: Bool {
    switch self {
    case .pending, .running: return false
    case .skipped, .done, .failed, .cancelled: return true
    }
  }
}

@MainActor
final class MosaicJobItem: Identifiable {
  let id = UUID()
  let url: URL
  /// Set once MosaicKit has inspected the file.
  var video: VideoInput?
  var state: MosaicItemState

  init(url: URL, state: MosaicItemState = .pending) {
    self.url = url
    self.state = state
  }
}

@MainActor
final class MosaicJob: Identifiable {
  enum State {
    /// Waiting for an earlier job of the same kind to finish.
    case queued
    /// Inspecting the files.
    case inspecting
    case running
    case finished
    case cancelled
  }

  let id = UUID()
  let kind: MosaicJobKind
  let createdAt = Date()
  /// The player the job was started from, used for on-screen messages.
  weak var player: PlayerCore?

  var state: State = .queued
  private(set) var items: [MosaicJobItem]
  var task: Task<Void, Never>?

  init(kind: MosaicJobKind, items: [MosaicJobItem], player: PlayerCore?) {
    self.kind = kind
    self.items = items
    self.player = player
  }

  var isActive: Bool {
    switch state {
    case .queued, .inspecting, .running: return true
    case .finished, .cancelled: return false
    }
  }

  /// The file MosaicKit reports `video` for: matched by the inspected video's ID, or by URL.
  func item(for video: VideoInput) -> MosaicJobItem? {
    items.first { $0.video?.id == video.id } ?? items.first { $0.video != nil && $0.url == video.url }
  }

  var outputs: [URL] {
    items.compactMap { if case .done(let url) = $0.state { return url } else { return nil } }
  }

  func count(where predicate: (MosaicItemState) -> Bool) -> Int {
    items.filter { predicate($0.state) }.count
  }

  /// Marks every file that has not finished as cancelled.
  func cancelRemainingItems() {
    for item in items where !item.state.isFinal {
      item.state = .cancelled
    }
  }
}
