//
//  MosaicInputResolver.swift
//  iina
//
//  iinaMosaic: turns "the current file", "the playlist" or "these playlist rows" into the files a
//  job works on, and checks with MosaicKit which of them it can read.
//  See docs/mosaickit/IMPLEMENTATION_PLAN.md, sections 2.1 and 2.5.
//

import Foundation
import MosaicKit

enum MosaicInputResolver {

  /// A file to process, or the reason it is skipped before any work starts.
  struct Candidate {
    let url: URL
    let skipReason: String?
  }

  /// The file playing in `player`, or nothing when no file is loaded.
  static func currentFile(of player: PlayerCore) -> [Candidate] {
    guard let url = player.info.currentURL else { return [] }
    return [candidate(for: url, isNetwork: !url.isFileURL)]
  }

  /// The playlist of `player`, in playlist order, or only the given rows.
  ///
  /// The playlist is copied under its lock; nothing is awaited while the lock is held.
  static func playlist(of player: PlayerCore, rows: IndexSet? = nil) -> [Candidate] {
    let entries: [(filename: String, isNetwork: Bool)] = player.info.$playlist.withLock { playlist in
      let indices = rows.map { Array($0.filter { $0 < playlist.count }) } ?? Array(playlist.indices)
      return indices.map { (filename: playlist[$0].filename, isNetwork: playlist[$0].isNetworkResource) }
    }
    var seen = Set<URL>()
    var result: [Candidate] = []
    for entry in entries {
      let url = entry.isNetwork ? (URL(string: entry.filename) ?? URL(fileURLWithPath: entry.filename))
                                : URL(fileURLWithPath: entry.filename)
      guard seen.insert(url.standardizedFileURL).inserted else { continue }
      result.append(candidate(for: url, isNetwork: entry.isNetwork))
    }
    return result
  }

  private static func candidate(for url: URL, isNetwork: Bool) -> Candidate {
    if isNetwork || !url.isFileURL {
      return Candidate(url: url, skipReason: "Network streams are not supported")
    }
    if !FileManager.default.fileExists(atPath: url.path) {
      return Candidate(url: url, skipReason: "File not found")
    }
    return Candidate(url: url, skipReason: nil)
  }

  /// Result of asking MosaicKit to inspect one file.
  enum Inspection: Sendable {
    case readable(VideoInput)
    case unreadable(reason: String)
  }

  /// Inspects `urls` with MosaicKit, at most `concurrency` at a time, and returns one result per
  /// URL in the same order. A file AVFoundation cannot read is reported, not thrown.
  static func inspect(_ urls: [URL], concurrency: Int = 2) async -> [Inspection] {
    var results = [Inspection?](repeating: nil, count: urls.count)
    await withTaskGroup(of: (Int, Inspection).self) { group in
      for (index, url) in urls.enumerated() {
        if index >= max(1, concurrency), let finished = await group.next() {
          results[finished.0] = finished.1
        }
        if Task.isCancelled { break }
        group.addTask {
          do {
            return (index, .readable(try await VideoSource(url: url).inspect()))
          } catch {
            return (index, .unreadable(reason: unreadableReason(error)))
          }
        }
      }
      for await (done, inspection) in group {
        results[done] = inspection
      }
    }
    return results.map { $0 ?? .unreadable(reason: "Cancelled") }
  }

  private static func unreadableReason(_ error: Error) -> String {
    if error is CancellationError { return "Cancelled" }
    if case .invalidVideo? = error as? MosaicError {
      return "Format not supported by AVFoundation"
    }
    return error.localizedDescription
  }
}
