//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import LSPLogging
import LanguageServerProtocol
import SKSupport

import struct TSCBasic.AbsolutePath

/// Options that can be used to modify SourceKit-LSP's behavior.
///
/// See `ConfigurationFile.md` for a description of the configuration file's behavior.
public struct SourceKitLSPOptions: Sendable, Codable {
  public struct SwiftPMOptions: Sendable, Codable {
    /// Build configuration (debug|release).
    ///
    /// Equivalent to SwiftPM's `--configuration` option.
    public var configuration: BuildConfiguration?

    /// Build artifacts directory path. If nil, the build system may choose a default value.
    ///
    /// Equivalent to SwiftPM's `--scratch-path` option.
    public var scratchPath: String?

    /// Equivalent to SwiftPM's `--swift-sdks-path` option
    public var swiftSDKsDirectory: String?

    /// Equivalent to SwiftPM's `--swift-sdk` option
    public var swiftSDK: String?

    /// Equivalent to SwiftPM's `--triple` option
    public var triple: String?

    /// Equivalent to SwiftPM's `-Xcc` option
    public var cCompilerFlags: [String]?

    /// Equivalent to SwiftPM's `-Xcxx` option
    public var cxxCompilerFlags: [String]?

    /// Equivalent to SwiftPM's `-Xswiftc` option
    public var swiftCompilerFlags: [String]?

    /// Equivalent to SwiftPM's `-Xlinker` option
    public var linkerFlags: [String]?

    public init(
      configuration: BuildConfiguration? = nil,
      scratchPath: String? = nil,
      swiftSDKsDirectory: String? = nil,
      swiftSDK: String? = nil,
      triple: String? = nil,
      cCompilerFlags: [String]? = nil,
      cxxCompilerFlags: [String]? = nil,
      swiftCompilerFlags: [String]? = nil,
      linkerFlags: [String]? = nil
    ) {
      self.configuration = configuration
      self.scratchPath = scratchPath
      self.swiftSDKsDirectory = swiftSDKsDirectory
      self.swiftSDK = swiftSDK
      self.triple = triple
      self.cCompilerFlags = cCompilerFlags
      self.cxxCompilerFlags = cxxCompilerFlags
      self.swiftCompilerFlags = swiftCompilerFlags
      self.linkerFlags = linkerFlags
    }

    static func merging(base: SwiftPMOptions, override: SwiftPMOptions?) -> SwiftPMOptions {
      return SwiftPMOptions(
        configuration: override?.configuration ?? base.configuration,
        scratchPath: override?.scratchPath ?? base.scratchPath,
        swiftSDKsDirectory: override?.swiftSDKsDirectory ?? base.swiftSDKsDirectory,
        swiftSDK: override?.swiftSDK ?? base.swiftSDK,
        triple: override?.triple ?? base.triple,
        cCompilerFlags: override?.cCompilerFlags ?? base.cCompilerFlags,
        cxxCompilerFlags: override?.cxxCompilerFlags ?? base.cxxCompilerFlags,
        swiftCompilerFlags: override?.swiftCompilerFlags ?? base.swiftCompilerFlags,
        linkerFlags: override?.linkerFlags ?? base.linkerFlags
      )
    }
  }

  public struct CompilationDatabaseOptions: Sendable, Codable {
    /// Additional paths to search for a compilation database, relative to a workspace root.
    public var searchPaths: [String]?

    public init(searchPaths: [String]? = nil) {
      self.searchPaths = searchPaths
    }

    static func merging(
      base: CompilationDatabaseOptions,
      override: CompilationDatabaseOptions?
    ) -> CompilationDatabaseOptions {
      return CompilationDatabaseOptions(searchPaths: override?.searchPaths ?? base.searchPaths)
    }
  }

  public struct FallbackBuildSystemOptions: Sendable, Codable {
    public var cCompilerFlags: [String]?
    public var cxxCompilerFlags: [String]?
    public var swiftCompilerFlags: [String]?

    public init(
      cCompilerFlags: [String]? = nil,
      cxxCompilerFlags: [String]? = nil,
      swiftCompilerFlags: [String]? = nil
    ) {
      self.cCompilerFlags = cCompilerFlags
      self.cxxCompilerFlags = cxxCompilerFlags
      self.swiftCompilerFlags = swiftCompilerFlags
    }

    static func merging(
      base: FallbackBuildSystemOptions,
      override: FallbackBuildSystemOptions?
    ) -> FallbackBuildSystemOptions {
      return FallbackBuildSystemOptions(
        cCompilerFlags: override?.cCompilerFlags ?? base.cCompilerFlags,
        cxxCompilerFlags: override?.cxxCompilerFlags ?? base.cxxCompilerFlags,
        swiftCompilerFlags: override?.swiftCompilerFlags ?? base.swiftCompilerFlags
      )
    }
  }

  public struct IndexOptions: Sendable, Codable {
    public var indexStorePath: String?
    public var indexDatabasePath: String?
    public var indexPrefixMap: [String: String]?
    public var maxCoresPercentageToUseForBackgroundIndexing: Double?
    public var updateIndexStoreTimeout: Int?

    public var maxCoresPercentageToUseForBackgroundIndexingOrDefault: Double {
      return maxCoresPercentageToUseForBackgroundIndexing ?? 1
    }

    public var updateIndexStoreTimeoutOrDefault: Duration {
      if let updateIndexStoreTimeout {
        .seconds(updateIndexStoreTimeout)
      } else {
        .seconds(120)
      }
    }

    public init(
      indexStorePath: String? = nil,
      indexDatabasePath: String? = nil,
      indexPrefixMap: [String: String]? = nil,
      maxCoresPercentageToUseForBackgroundIndexing: Double? = nil,
      updateIndexStoreTimeout: Int? = nil
    ) {
      self.indexStorePath = indexStorePath
      self.indexDatabasePath = indexDatabasePath
      self.indexPrefixMap = indexPrefixMap
      self.maxCoresPercentageToUseForBackgroundIndexing = maxCoresPercentageToUseForBackgroundIndexing
      self.updateIndexStoreTimeout = updateIndexStoreTimeout
    }

    static func merging(base: IndexOptions, override: IndexOptions?) -> IndexOptions {
      return IndexOptions(
        indexStorePath: override?.indexStorePath ?? base.indexStorePath,
        indexDatabasePath: override?.indexDatabasePath ?? base.indexDatabasePath,
        indexPrefixMap: override?.indexPrefixMap ?? base.indexPrefixMap,
        maxCoresPercentageToUseForBackgroundIndexing: override?.maxCoresPercentageToUseForBackgroundIndexing
          ?? base.maxCoresPercentageToUseForBackgroundIndexing,
        updateIndexStoreTimeout: override?.updateIndexStoreTimeout ?? base.updateIndexStoreTimeout
      )
    }
  }

  public var swiftPM: SwiftPMOptions
  public var compilationDatabase: CompilationDatabaseOptions
  public var fallbackBuildSystem: FallbackBuildSystemOptions
  public var clangdOptions: [String]?
  public var index: IndexOptions

  /// Default workspace type (buildserver|compdb|swiftpm). Overrides workspace type selection logic.
  public var defaultWorkspaceType: WorkspaceType?
  public var generatedFilesPath: String?

  /// Whether background indexing is enabled.
  public var backgroundIndexing: Bool?

  /// Experimental features that are enabled.
  public var experimentalFeatures: Set<ExperimentalFeature>? = nil

  /// The time that `SwiftLanguageService` should wait after an edit before starting to compute diagnostics and
  /// sending a `PublishDiagnosticsNotification`.
  ///
  /// This is mostly intended for testing purposes so we don't need to wait the debouncing time to get a diagnostics
  /// notification when running unit tests.
  public var swiftPublishDiagnosticsDebounceDuration: Double? = nil

  public var swiftPublishDiagnosticsDebounceDurationOrDefault: Duration {
    if let swiftPublishDiagnosticsDebounceDuration {
      return .seconds(swiftPublishDiagnosticsDebounceDuration)
    }
    return .seconds(2)
  }

  /// When a task is started that should be displayed to the client as a work done progress, how many milliseconds to
  /// wait before actually starting the work done progress. This prevents flickering of the work done progress in the
  /// client for short-lived index tasks which end within this duration.
  public var workDoneProgressDebounceDuration: Double? = nil

  public var workDoneProgressDebounceDurationOrDefault: Duration {
    if let workDoneProgressDebounceDuration {
      return .seconds(workDoneProgressDebounceDuration)
    }
    return .seconds(1)
  }

  public var backgroundIndexingOrDefault: Bool {
    return backgroundIndexing ?? false
  }

  public init(
    swiftPM: SwiftPMOptions = .init(),
    fallbackBuildSystem: FallbackBuildSystemOptions = .init(),
    compilationDatabase: CompilationDatabaseOptions = .init(),
    clangdOptions: [String]? = nil,
    index: IndexOptions = .init(),
    defaultWorkspaceType: WorkspaceType? = nil,
    generatedFilesPath: String? = nil,
    backgroundIndexing: Bool? = nil,
    experimentalFeatures: Set<ExperimentalFeature>? = nil,
    swiftPublishDiagnosticsDebounceDuration: Double? = nil,
    workDoneProgressDebounceDuration: Double? = nil
  ) {
    self.swiftPM = swiftPM
    self.fallbackBuildSystem = fallbackBuildSystem
    self.compilationDatabase = compilationDatabase
    self.clangdOptions = clangdOptions
    self.index = index
    self.generatedFilesPath = generatedFilesPath
    self.defaultWorkspaceType = defaultWorkspaceType
    self.backgroundIndexing = backgroundIndexing
    self.experimentalFeatures = experimentalFeatures
    self.swiftPublishDiagnosticsDebounceDuration = swiftPublishDiagnosticsDebounceDuration
    self.workDoneProgressDebounceDuration = workDoneProgressDebounceDuration
  }

  public init?(fromLSPAny lspAny: LSPAny?) throws {
    guard let lspAny else {
      return nil
    }
    let jsonEncoded = try JSONEncoder().encode(lspAny)
    self = try JSONDecoder().decode(Self.self, from: jsonEncoded)
  }

  public var asLSPAny: LSPAny {
    get throws {
      let jsonEncoded = try JSONEncoder().encode(self)
      return try JSONDecoder().decode(LSPAny.self, from: jsonEncoded)
    }
  }

  public init?(path: URL?) {
    guard let path, let contents = try? String(contentsOf: path, encoding: .utf8) else {
      return nil
    }
    guard
      let decoded = orLog(
        "Parsing config.json",
        { try JSONDecoder().decode(Self.self, from: contents) }
      )
    else {
      return nil
    }
    self = decoded
  }

  public static func merging(base: SourceKitLSPOptions, override: SourceKitLSPOptions?) -> SourceKitLSPOptions {
    return SourceKitLSPOptions(
      swiftPM: SwiftPMOptions.merging(base: base.swiftPM, override: override?.swiftPM),
      fallbackBuildSystem: FallbackBuildSystemOptions.merging(
        base: base.fallbackBuildSystem,
        override: override?.fallbackBuildSystem
      ),
      compilationDatabase: CompilationDatabaseOptions.merging(
        base: base.compilationDatabase,
        override: override?.compilationDatabase
      ),
      clangdOptions: override?.clangdOptions ?? base.clangdOptions,
      index: IndexOptions.merging(base: base.index, override: override?.index),
      defaultWorkspaceType: override?.defaultWorkspaceType ?? base.defaultWorkspaceType,
      generatedFilesPath: override?.generatedFilesPath ?? base.generatedFilesPath,
      backgroundIndexing: override?.backgroundIndexing ?? base.backgroundIndexing,
      experimentalFeatures: override?.experimentalFeatures ?? base.experimentalFeatures,
      swiftPublishDiagnosticsDebounceDuration: override?.swiftPublishDiagnosticsDebounceDuration
        ?? base.swiftPublishDiagnosticsDebounceDuration,
      workDoneProgressDebounceDuration: override?.workDoneProgressDebounceDuration
        ?? base.workDoneProgressDebounceDuration
    )
  }

  public var generatedFilesAbsolutePath: AbsolutePath {
    if let absolutePath = AbsolutePath(validatingOrNil: generatedFilesPath) {
      return absolutePath
    }
    return defaultDirectoryForGeneratedFiles
  }

  public func hasExperimentalFeature(_ feature: ExperimentalFeature) -> Bool {
    guard let experimentalFeatures else {
      return false
    }
    return experimentalFeatures.contains(feature)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.swiftPM = try container.decodeIfPresent(SwiftPMOptions.self, forKey: CodingKeys.swiftPM) ?? .init()
    self.compilationDatabase =
      try container.decodeIfPresent(CompilationDatabaseOptions.self, forKey: CodingKeys.compilationDatabase) ?? .init()
    self.fallbackBuildSystem =
      try container.decodeIfPresent(FallbackBuildSystemOptions.self, forKey: CodingKeys.fallbackBuildSystem) ?? .init()
    self.clangdOptions = try container.decodeIfPresent([String].self, forKey: CodingKeys.clangdOptions)
    self.index = try container.decodeIfPresent(IndexOptions.self, forKey: CodingKeys.index) ?? .init()
    self.defaultWorkspaceType = try container.decodeIfPresent(
      WorkspaceType.self,
      forKey: CodingKeys.defaultWorkspaceType
    )
    self.generatedFilesPath = try container.decodeIfPresent(String.self, forKey: CodingKeys.generatedFilesPath)
    self.backgroundIndexing = try container.decodeIfPresent(Bool.self, forKey: CodingKeys.backgroundIndexing)
    self.experimentalFeatures = try container.decodeIfPresent(
      Set<ExperimentalFeature>.self,
      forKey: CodingKeys.experimentalFeatures
    )
    self.swiftPublishDiagnosticsDebounceDuration = try container.decodeIfPresent(
      Double.self,
      forKey: CodingKeys.swiftPublishDiagnosticsDebounceDuration
    )
    self.workDoneProgressDebounceDuration = try container.decodeIfPresent(
      Double.self,
      forKey: CodingKeys.workDoneProgressDebounceDuration
    )
  }
}
