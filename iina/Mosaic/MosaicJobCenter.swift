//
//  MosaicJobCenter.swift
//  iina
//
//  iinaMosaic: runs mosaic and preview jobs with MosaicKit's coordinators, tracks their progress
//  and cancels them. See docs/mosaickit/IMPLEMENTATION_PLAN.md, sections 2.1 and 2.3.
//

import Cocoa
import MosaicKit

@MainActor
final class MosaicJobCenter {

  static let shared = MosaicJobCenter()

  /// Posted on the main thread whenever a job or one of its files changes state or progress.
  static let didChangeNotification = Notification.Name("IINAMosaicJobCenterDidChange")

  var settings = MosaicSettings()

  /// Every job started in this session, oldest first.
  private(set) var jobs: [MosaicJob] = []

  var hasActiveJobs: Bool { jobs.contains { $0.isActive } }

  private var mosaicCoordinator: MosaicGeneratorCoordinator<MetalMosaicGenerator>?
  private var previewCoordinator: PreviewGeneratorCoordinator?

  private let subsystem = Logger.makeSubsystem("mosaic")

  private init() {}

  // MARK: - Starting and cancelling

  /// Starts a job for `candidates`. Jobs of the same kind run one after the other; inside a job
  /// MosaicKit's coordinator applies the concurrency limit from `settings`.
  ///
  /// - Returns: The job, or `nil` when there is nothing to process.
  @discardableResult
  func start(_ kind: MosaicJobKind, candidates: [MosaicInputResolver.Candidate], player: PlayerCore?,
             onFinish: ((MosaicJob) -> Void)? = nil) -> MosaicJob? {
    guard !candidates.isEmpty else { return nil }
    let items = candidates.map { candidate -> MosaicJobItem in
      if let reason = candidate.skipReason {
        return MosaicJobItem(url: candidate.url, state: .skipped(reason: reason))
      }
      return MosaicJobItem(url: candidate.url)
    }
    let job = MosaicJob(kind: kind, items: items, player: player)
    let previous = jobs.last { $0.kind == kind && $0.isActive }?.task
    jobs.append(job)
    log("Queued \(kind) job \(job.id) with \(items.count) file(s)")

    job.task = Task(priority: .utility) {
      await previous?.value
      await self.run(job)
      onFinish?(job)
    }
    notifyChange()
    return job
  }

  func cancel(_ job: MosaicJob) {
    guard job.isActive else { return }
    log("Cancelling \(job.kind) job \(job.id)")
    job.state = .cancelled
    job.task?.cancel()
    // Cancelling the awaiting task stops MosaicKit's work; cancelling each video as well makes
    // sure an attempt already running inside the coordinator stops promptly.
    let videos = job.items.filter { !$0.state.isFinal }.compactMap(\.video)
    let kind = job.kind
    Task {
      for video in videos {
        switch kind {
        case .mosaic: await mosaicCoordinator?.cancelGeneration(for: video)
        case .preview: await previewCoordinator?.cancelGeneration(for: video)
        }
      }
    }
    job.cancelRemainingItems()
    notifyChange()
  }

  func cancelAll() {
    for job in jobs where job.isActive {
      cancel(job)
    }
  }

  // MARK: - Running a job

  private func run(_ job: MosaicJob) async {
    guard !Task.isCancelled, job.state == .queued else {
      finish(job)
      return
    }

    job.state = .inspecting
    notifyChange()
    let pending = job.items.filter { !$0.state.isFinal }
    let inspections = await MosaicInputResolver.inspect(pending.map(\.url))
    for (item, inspection) in zip(pending, inspections) {
      switch inspection {
      case .readable(let video): item.video = video
      case .unreadable(let reason): item.state = .skipped(reason: reason)
      }
    }
    let videos = pending.compactMap(\.video)
    guard !Task.isCancelled, job.state == .inspecting, !videos.isEmpty else {
      finish(job)
      return
    }

    job.state = .running
    notifyChange()
    do {
      switch job.kind {
      case .mosaic: try await runMosaics(videos, job: job)
      case .preview: try await runPreviews(videos, job: job)
      }
    } catch {
      // A cancelled batch throws; any other error applies to every file still running.
      if !isCancellation(error) && job.state != .cancelled {
        log("\(job.kind) job \(job.id) failed: \(error)", level: .error)
        for item in job.items where !item.state.isFinal {
          item.state = .failed(message: error.localizedDescription)
        }
      }
    }
    finish(job)
  }

  private func runMosaics(_ videos: [VideoInput], job: MosaicJob) async throws {
    if mosaicCoordinator == nil {
      mosaicCoordinator = try createDefaultMosaicCoordinator(concurrencyLimit: settings.mosaicConcurrency)
    }
    guard let coordinator = mosaicCoordinator else { return }
    let jobID = job.id
    let results = try await coordinator.generateMosaicsforbatch(videos: videos,
                                                                config: settings.mosaicConfiguration()) { progress in
      Task { @MainActor in
        MosaicJobCenter.shared.apply(progress, jobID: jobID)
      }
    }
    for result in results {
      guard let item = job.item(for: result.video) else { continue }
      item.state = finalState(output: result.outputURL, error: result.error, job: job)
    }
  }

  private func runPreviews(_ videos: [VideoInput], job: MosaicJob) async throws {
    if previewCoordinator == nil {
      previewCoordinator = PreviewGeneratorCoordinator(concurrencyLimit: settings.previewConcurrency)
    }
    guard let coordinator = previewCoordinator else { return }
    let jobID = job.id
    let results = try await coordinator.generatePreviewsForBatch(videos: videos,
                                                                 config: settings.previewConfiguration()) { progress in
      Task { @MainActor in
        MosaicJobCenter.shared.apply(progress, jobID: jobID)
      }
    }
    for result in results {
      guard let item = job.item(for: result.video) else { continue }
      item.state = finalState(output: result.outputURL, error: result.error, job: job)
    }
  }

  private func finish(_ job: MosaicJob) {
    if job.state == .cancelled || Task.isCancelled {
      job.state = .cancelled
      job.cancelRemainingItems()
    } else {
      job.state = .finished
      for item in job.items where !item.state.isFinal {
        item.state = .failed(message: "No result from MosaicKit")
      }
    }
    log("\(job.kind) job \(job.id) ended: \(job.state); \(job.outputs.count) output(s)")
    notifyChange()
    sendSummaryOSD(for: job)
  }

  // MARK: - Progress

  private func apply(_ progress: MosaicGenerationProgress, jobID: UUID) {
    guard let job = jobs.first(where: { $0.id == jobID }), job.isActive,
          let item = job.item(for: progress.video), !item.state.isFinal else { return }
    switch progress.status {
    case .completed:
      if let url = progress.outputURL { item.state = .done(url) }
    case .failed:
      item.state = .failed(message: progress.error?.localizedDescription ?? "Failed")
    case .cancelled:
      item.state = .cancelled
    case .queued:
      return
    case .inProgress, .countingThumbnails, .computingLayout:
      updateRunning(item, progress: progress.progress, phase: "Preparing")
      return
    case .extractingThumbnails:
      updateRunning(item, progress: progress.progress, phase: "Extracting frames")
      return
    case .creatingMosaic:
      updateRunning(item, progress: progress.progress, phase: "Composing")
      return
    case .savingMosaic:
      updateRunning(item, progress: progress.progress, phase: "Saving")
      return
    }
    notifyChange()
  }

  private func apply(_ progress: PreviewGenerationProgress, jobID: UUID) {
    guard let job = jobs.first(where: { $0.id == jobID }), job.isActive,
          let item = job.item(for: progress.video), !item.state.isFinal else { return }
    switch progress.status {
    case .completed:
      if let url = progress.outputURL { item.state = .done(url) }
    case .failed:
      item.state = .failed(message: progress.error?.localizedDescription ?? progress.message ?? "Failed")
    case .cancelled:
      item.state = .cancelled
    case .queued:
      return
    case .analyzing, .extracting, .composing, .encoding, .saving:
      updateRunning(item, progress: progress.progress, phase: progress.status.displayLabel)
      return
    }
    notifyChange()
  }

  /// Updates a running file and notifies only when the phase changes or progress moves by at
  /// least 1 %, so a batch does not flood the UI.
  private func updateRunning(_ item: MosaicJobItem, progress: Double, phase: String) {
    if case .running(let previous, let previousPhase) = item.state,
       previousPhase == phase, abs(progress - previous) < 0.01 {
      return
    }
    item.state = .running(progress: progress, phase: phase)
    notifyChange()
  }

  // MARK: - Helpers

  private func finalState(output: URL?, error: Error?, job: MosaicJob) -> MosaicItemState {
    if let output { return .done(output) }
    if job.state == .cancelled || error.map(isCancellation) == true { return .cancelled }
    return .failed(message: error?.localizedDescription ?? "Failed")
  }

  private func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if case .cancelled? = error as? PreviewError { return true }
    if case .cancelled? = error as? VideoError { return true }
    return false
  }

  private func sendSummaryOSD(for job: MosaicJob) {
    guard let player = job.player else { return }
    let noun = job.kind == .mosaic ? "Mosaic" : "Preview"
    let done = job.outputs.count
    let skipped = job.count { if case .skipped = $0 { return true } else { return false } }
    let failed = job.count { if case .failed = $0 { return true } else { return false } }

    if job.state == .cancelled {
      player.sendOSD(.custom("\(noun) cancelled"))
    } else if job.items.count == 1 {
      switch job.items[0].state {
      case .done(let url): player.sendOSD(.customWithDetail("\(noun) saved", url.lastPathComponent))
      case .skipped(let reason): player.sendOSD(.customWithDetail("\(noun) not generated", reason))
      case .failed(let message): player.sendOSD(.customWithDetail("\(noun) failed", message))
      default: break
      }
    } else {
      player.sendOSD(.customWithDetail("\(noun)s finished", "\(done) saved, \(skipped) skipped, \(failed) failed"))
    }
  }

  private func notifyChange() {
    NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
  }

  private func log(_ message: String, level: Logger.Level = .debug) {
    Logger.log(message, level: level, subsystem: subsystem)
  }
}
