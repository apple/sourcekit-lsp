//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import LSPLogging
import LanguageServerProtocol
import SKCore
import SKSupport
import SourceKitD
import SwiftExtensions
import SwiftParserDiagnostics

actor DiagnosticReportManager {
  /// A task to produce diagnostics, either from a diagnostics request to `sourcektid` or by using the built-in swift-syntax.
  private typealias ReportTask = RefCountedCancellableTask<RelatedFullDocumentDiagnosticReport>

  private let sourcekitd: SourceKitD
  private let options: SourceKitLSPOptions
  private let syntaxTreeManager: SyntaxTreeManager
  private let documentManager: DocumentManager
  private let clientHasDiagnosticsCodeDescriptionSupport: Bool

  private nonisolated var keys: sourcekitd_api_keys { return sourcekitd.keys }
  private nonisolated var requests: sourcekitd_api_requests { return sourcekitd.requests }

  /// The cache that stores reportTasks for snapshot id and buildSettings
  ///
  /// Conceptually, this is a dictionary. To prevent excessive memory usage we
  /// only keep `cacheSize` entries within the array. Older entries are at the
  /// end of the list, newer entries at the front.
  private var reportTaskCache:
    [(
      snapshotID: DocumentSnapshot.ID,
      buildSettings: SwiftCompileCommand?,
      reportTask: ReportTask
    )] = []

  /// The number of reportTasks to keep
  ///
  /// - Note: This has been chosen without scientific measurements.
  private let cacheSize = 5

  init(
    sourcekitd: SourceKitD,
    options: SourceKitLSPOptions,
    syntaxTreeManager: SyntaxTreeManager,
    documentManager: DocumentManager,
    clientHasDiagnosticsCodeDescriptionSupport: Bool
  ) {
    self.sourcekitd = sourcekitd
    self.options = options
    self.syntaxTreeManager = syntaxTreeManager
    self.documentManager = documentManager
    self.clientHasDiagnosticsCodeDescriptionSupport = clientHasDiagnosticsCodeDescriptionSupport
  }

  func diagnosticReport(
    for snapshot: DocumentSnapshot,
    buildSettings: SwiftCompileCommand?
  ) async throws -> RelatedFullDocumentDiagnosticReport {
    if let reportTask = reportTask(for: snapshot.id, buildSettings: buildSettings), await !reportTask.isCancelled {
      return try await reportTask.value
    }
    let reportTask: ReportTask
    if let buildSettings, !buildSettings.isFallback {
      reportTask = ReportTask {
        return try await self.requestReport(with: snapshot, compilerArgs: buildSettings.compilerArgs)
      }
    } else {
      logger.log(
        "Producing syntactic diagnostics from the built-in swift-syntax because we \(buildSettings != nil ? "have fallback build settings" : "don't have build settings", privacy: .public))"
      )
      // If we don't have build settings or we only have fallback build settings,
      // sourcekitd won't be able to give us accurate semantic diagnostics.
      // Fall back to providing syntactic diagnostics from the built-in
      // swift-syntax. That's the best we can do for now.
      reportTask = ReportTask {
        return try await self.requestFallbackReport(with: snapshot)
      }
    }
    setReportTask(for: snapshot.id, buildSettings: buildSettings, reportTask: reportTask)
    return try await reportTask.value
  }

  func removeItemsFromCache(with uri: DocumentURI) async {
    reportTaskCache.removeAll(where: { $0.snapshotID.uri == uri })
  }

  private func requestReport(
    with snapshot: DocumentSnapshot,
    compilerArgs: [String]
  ) async throws -> LanguageServerProtocol.RelatedFullDocumentDiagnosticReport {
    try Task.checkCancellation()

    let keys = self.keys

    let skreq = sourcekitd.dictionary([
      keys.request: requests.diagnostics,
      keys.sourceFile: snapshot.uri.pseudoPath,
      keys.compilerArgs: compilerArgs as [SKDRequestValue],
    ])

    let dict = try await self.sourcekitd.send(
      skreq,
      timeout: options.sourcekitdRequestTimeoutOrDefault,
      fileContents: snapshot.text
    )

    try Task.checkCancellation()

    let diagnostics: [Diagnostic] =
      dict[keys.diagnostics]?.compactMap({ diag in
        Diagnostic(
          diag,
          in: snapshot,
          documentManager: documentManager,
          useEducationalNoteAsCode: self.clientHasDiagnosticsCodeDescriptionSupport
        )
      }) ?? []

    return RelatedFullDocumentDiagnosticReport(items: diagnostics)
  }

  private func requestFallbackReport(
    with snapshot: DocumentSnapshot
  ) async throws -> LanguageServerProtocol.RelatedFullDocumentDiagnosticReport {
    // If we don't have build settings or we only have fallback build settings,
    // sourcekitd won't be able to give us accurate semantic diagnostics.
    // Fall back to providing syntactic diagnostics from the built-in
    // swift-syntax. That's the best we can do for now.
    let syntaxTree = await syntaxTreeManager.syntaxTree(for: snapshot)
    let swiftSyntaxDiagnostics = ParseDiagnosticsGenerator.diagnostics(for: syntaxTree)
    let diagnostics = swiftSyntaxDiagnostics.compactMap { (diag) -> Diagnostic? in
      if diag.diagnosticID == StaticTokenError.editorPlaceholder.diagnosticID {
        // Ignore errors about editor placeholders in the source file, similar to how sourcekitd ignores them.
        return nil
      }
      return Diagnostic(diag, in: snapshot)
    }
    return RelatedFullDocumentDiagnosticReport(items: diagnostics)
  }

  /// The reportTask for the given document snapshot and buildSettings.
  private func reportTask(
    for snapshotID: DocumentSnapshot.ID,
    buildSettings: SwiftCompileCommand?
  ) -> ReportTask? {
    return reportTaskCache.first(where: { $0.snapshotID == snapshotID && $0.buildSettings == buildSettings })?
      .reportTask
  }

  /// Set the reportTask for the given document snapshot and buildSettings.
  ///
  /// If we are already storing `cacheSize` many reports, the oldest one
  /// will get discarded.
  private func setReportTask(
    for snapshotID: DocumentSnapshot.ID,
    buildSettings: SwiftCompileCommand?,
    reportTask: ReportTask
  ) {
    reportTaskCache.insert((snapshotID, buildSettings, reportTask), at: 0)

    // Remove any reportTasks for old versions of this document.
    reportTaskCache.removeAll(where: { $0.snapshotID < snapshotID })

    // If we still have more than `cacheSize` reportTasks, delete the ones that
    // were produced last. We can always re-request them on-demand.
    while reportTaskCache.count > cacheSize {
      reportTaskCache.removeLast()
    }
  }
}
