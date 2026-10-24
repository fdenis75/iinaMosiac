//
//  MosaicSettings.swift
//  iina
//
//  iinaMosaic: the options IINA passes to MosaicKit. Phase 1 uses fixed defaults; phase 6 reads
//  them from Preference keys (docs/mosaickit/IMPLEMENTATION_PLAN.md, section 2.4).
//

import Foundation
import MosaicKit

struct MosaicSettings {

  // MARK: Output

  /// `nil` saves next to each video (MosaicKit's default).
  var outputDirectory: URL? = nil
  var overwrite = false

  // MARK: Mosaic

  var width = 5120
  var density: DensityConfig = .m
  var format: OutputFormat = .heif
  var layout: LayoutConfiguration = .default
  var includeHeader = true
  var compressionQuality = 0.4

  // MARK: Preview

  var previewDuration: TimeInterval = 60
  var previewDensity: DensityConfig = .m
  var previewIncludesAudio = true
  var previewQuality = 0.8
  var previewExportMode: PreviewExportMode = .native

  // MARK: Concurrency

  var mosaicConcurrency = 1
  var previewConcurrency = 1

  // MARK: MosaicKit configurations

  func mosaicConfiguration() -> MosaicConfiguration {
    // `gifMode` and `width` are passed so the call matches only MosaicConfiguration's full
    // initializer. WebP is not offered because the MosaicKitWebP product is not linked, so the
    // animated format is pinned to GIF (it is only used when an animation is requested).
    var config = MosaicConfiguration(width: width,
                                     density: density,
                                     format: format == .webp ? .heif : format,
                                     layout: layout,
                                     includeMetadata: includeHeader,
                                     compressionQuality: compressionQuality,
                                     outputdirectory: outputDirectory,
                                     gifMode: .disabled,
                                     animatedFormat: .gif)
    config.overwrite = overwrite
    return config
  }

  func previewConfiguration() -> PreviewConfiguration {
    var config = PreviewConfiguration(targetDuration: previewDuration,
                                      density: previewDensity,
                                      format: .mp4,
                                      includeAudio: previewIncludesAudio,
                                      outputDirectory: outputDirectory,
                                      compressionQuality: previewQuality,
                                      // ffmpeg needs a binary path, which IINA does not configure.
                                      exportMode: previewExportMode == .ffmpeg ? .native : previewExportMode,
                                      // On macOS the lifecycle monitor pauses export whenever IINA
                                      // is not the frontmost app, so it must stay off.
                                      enableAppLifecycleMonitor: false,
                                      enableExportRetry: true)
    config.overwrite = overwrite
    return config
  }
}
