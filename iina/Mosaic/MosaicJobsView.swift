//
//  MosaicJobsView.swift
//  iina
//
//  iinaMosaic: the content of the Mosaic Jobs window: every job of this session with the state of
//  each file, progress, errors, and actions (cancel, reveal, open, play preview).
//

import Cocoa
import SwiftUI

/// A value snapshot of `MosaicJobCenter.jobs`, rebuilt whenever the center posts a change.
@MainActor
final class MosaicJobsModel: ObservableObject {

  struct JobRow: Identifiable {
    let id: UUID
    let title: String
    let status: String
    let isActive: Bool
    let isPreview: Bool
    let outputs: [URL]
    let items: [ItemRow]
  }

  struct ItemRow: Identifiable {
    enum Kind {
      case pending, running, done, skipped, failed, cancelled
    }

    let id: UUID
    let name: String
    let kind: Kind
    let status: String
    let progress: Double?
    let output: URL?
    let error: String?
  }

  @Published private(set) var jobs: [JobRow] = []
  /// Never removed: the model lives as long as the shared jobs window.
  private var observer: NSObjectProtocol?

  init() {
    reload()
    observer = NotificationCenter.default.addObserver(forName: MosaicJobCenter.didChangeNotification,
                                                      object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.reload() }
    }
  }

  var hasActiveJobs: Bool { jobs.contains { $0.isActive } }
  var hasFinishedJobs: Bool { jobs.contains { !$0.isActive } }

  private func reload() {
    // Newest first.
    jobs = MosaicJobCenter.shared.jobs.reversed().map(Self.row(for:))
  }

  private static func row(for job: MosaicJob) -> JobRow {
    let noun = job.kind == .mosaic ? "Mosaic" : "Preview"
    let count = job.items.count
    let time = job.createdAt.formatted(date: .omitted, time: .shortened)
    let title = count == 1 ? "\(noun) of \(job.items[0].url.lastPathComponent)"
                           : "\(noun)s of \(count) files"
    return JobRow(id: job.id,
                  title: title,
                  status: "\(status(of: job)) · started \(time)",
                  isActive: job.isActive,
                  isPreview: job.kind == .preview,
                  outputs: job.outputs,
                  items: job.items.map(row(for:)))
  }

  private static func status(of job: MosaicJob) -> String {
    switch job.state {
    case .queued: return "Waiting for the previous job"
    case .inspecting: return "Checking files"
    case .running:
      let finished = job.count { $0.isFinal }
      return "\(finished) of \(job.items.count) done"
    case .cancelled: return "Cancelled"
    case .finished:
      let done = job.outputs.count
      let skipped = job.count { if case .skipped = $0 { return true } else { return false } }
      let failed = job.count { if case .failed = $0 { return true } else { return false } }
      var parts = ["\(done) saved"]
      if skipped > 0 { parts.append("\(skipped) skipped") }
      if failed > 0 { parts.append("\(failed) failed") }
      return parts.joined(separator: ", ")
    }
  }

  private static func row(for item: MosaicJobItem) -> ItemRow {
    let kind: ItemRow.Kind
    let status: String
    var progress: Double?
    var output: URL?
    var error: String?
    switch item.state {
    case .pending:
      kind = .pending
      status = "Waiting"
    case .skipped(let reason):
      kind = .skipped
      status = "Skipped"
      error = reason
    case .running(let value, let phase):
      kind = .running
      status = phase
      progress = value
    case .done(let url):
      kind = .done
      status = "Saved"
      output = url
    case .failed(let message):
      kind = .failed
      status = "Failed"
      error = message
    case .cancelled:
      kind = .cancelled
      status = "Cancelled"
    }
    return ItemRow(id: item.id, name: item.url.lastPathComponent, kind: kind, status: status,
                   progress: progress, output: output, error: error)
  }

  // MARK: - Actions

  func cancel(_ jobID: UUID) {
    guard let job = MosaicJobCenter.shared.jobs.first(where: { $0.id == jobID }) else { return }
    MosaicJobCenter.shared.cancel(job)
  }

  func cancelAll() {
    MosaicJobCenter.shared.cancelAll()
  }

  func clearFinished() {
    MosaicJobCenter.shared.removeFinishedJobs()
  }

  func reveal(_ urls: [URL]) {
    NSWorkspace.shared.activateFileViewerSelecting(urls)
  }

  func open(_ url: URL) {
    NSWorkspace.shared.open(url)
  }

  func play(_ preview: URL, jobID: UUID) {
    let player = MosaicJobCenter.shared.jobs.first { $0.id == jobID }?.player
    MosaicActions.playPreview(preview, pausing: player)
  }

  func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

struct MosaicJobsView: View {

  @ObservedObject var model: MosaicJobsModel

  var body: some View {
    VStack(spacing: 0) {
      if model.jobs.isEmpty {
        ContentUnavailableView("No Mosaic Jobs",
                               systemImage: "square.grid.3x3",
                               description: Text("Use File ▸ Mosaic or the playlist's context menu to generate mosaics and previews."))
      } else {
        List {
          ForEach(model.jobs) { job in
            Section {
              ForEach(job.items) { item in
                itemRow(item, job: job)
              }
            } header: {
              jobHeader(job)
            }
          }
        }
        .listStyle(.inset)
      }
      Divider()
      HStack {
        Button("Clear Finished") { model.clearFinished() }
          .disabled(!model.hasFinishedJobs)
        Spacer()
        Button("Cancel All") { model.cancelAll() }
          .disabled(!model.hasActiveJobs)
      }
      .padding(10)
    }
    .frame(minWidth: 420, minHeight: 240)
  }

  private func jobHeader(_ job: MosaicJobsModel.JobRow) -> some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text(job.title).font(.headline).lineLimit(1).truncationMode(.middle)
        Text(job.status).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if job.isActive {
        Button("Cancel") { model.cancel(job.id) }
      } else if job.outputs.count > 1 {
        Button("Show All in Finder") { model.reveal(job.outputs) }
      }
    }
    .padding(.vertical, 4)
  }

  private func itemRow(_ item: MosaicJobsModel.ItemRow, job: MosaicJobsModel.JobRow) -> some View {
    HStack(spacing: 8) {
      statusIcon(item)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 3) {
        Text(item.name).lineLimit(1).truncationMode(.middle)
        if let progress = item.progress {
          ProgressView(value: min(max(progress, 0), 1))
            .progressViewStyle(.linear)
        }
        Text(item.error.map { "\(item.status): \($0)" } ?? item.status)
          .font(.caption)
          .foregroundStyle(item.error == nil ? Color.secondary : Color.red)
          .lineLimit(2)
          .textSelection(.enabled)
      }
      Spacer()
      if let output = item.output {
        if job.isPreview {
          Button { model.play(output, jobID: job.id) } label: { Image(systemName: "play.fill") }
            .help("Play preview in IINA")
        } else {
          Button { model.open(output) } label: { Image(systemName: "photo") }
            .help("Open mosaic")
        }
        Button { model.reveal([output]) } label: { Image(systemName: "folder") }
          .help("Show in Finder")
      }
    }
    .buttonStyle(.borderless)
    .padding(.vertical, 2)
    .contextMenu {
      if let output = item.output {
        if job.isPreview {
          Button("Play Preview") { model.play(output, jobID: job.id) }
        } else {
          Button("Open") { model.open(output) }
        }
        Button("Show in Finder") { model.reveal([output]) }
        Button("Copy Path") { model.copy(output.path) }
      }
      if let error = item.error {
        Button("Copy Message") { model.copy(error) }
      }
    }
  }

  @ViewBuilder
  private func statusIcon(_ item: MosaicJobsModel.ItemRow) -> some View {
    switch item.kind {
    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
    case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
    case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
    case .running: ProgressView().controlSize(.small)
    case .pending: Image(systemName: "clock").foregroundStyle(.secondary)
    }
  }
}
