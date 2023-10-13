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

import Dispatch
import Foundation
import LSPLogging
import LanguageServerProtocol
import SKCore
import SKSupport
import SourceKitD
import SwiftParser
import SwiftSyntax

#if os(Windows)
import WinSDK
#endif

fileprivate extension Range {
  /// Checks if this range overlaps with the other range, counting an overlap with an empty range as a valid overlap.
  /// The standard library implementation makes `1..<3.overlaps(2..<2)` return false because the second range is empty and thus the overlap is also empty.
  /// This implementation over overlap considers such an inclusion of an empty range as a valid overlap.
  func overlapsIncludingEmptyRanges(other: Range<Bound>) -> Bool {
    switch (self.isEmpty, other.isEmpty) {
    case (true, true):
      return self.lowerBound == other.lowerBound
    case (true, false):
      return other.contains(self.lowerBound)
    case (false, true):
      return self.contains(other.lowerBound)
    case (false, false):
      return self.overlaps(other)
    }
  }
}

/// Explicitly blacklisted `DocumentURI` schemes.
fileprivate let excludedDocumentURISchemes: [String] = [
  "git",
  "hg",
]

/// Returns true if diagnostics should be emitted for the given document.
///
/// Some editors  (like Visual Studio Code) use non-file URLs to manage source control diff bases
/// for the active document, which can lead to duplicate diagnostics in the Problems view.
/// As a workaround we explicitly blacklist those URIs and don't emit diagnostics for them.
///
/// Additionally, as of Xcode 11.4, sourcekitd does not properly handle non-file URLs when
/// the `-working-directory` argument is passed since it incorrectly applies it to the input
/// argument but not the internal primary file, leading sourcekitd to believe that the input
/// file is missing.
fileprivate func diagnosticsEnabled(for document: DocumentURI) -> Bool {
  guard let scheme = document.scheme else { return true }
  return !excludedDocumentURISchemes.contains(scheme)
}

/// A swift compiler command derived from a `FileBuildSettingsChange`.
public struct SwiftCompileCommand: Equatable {

  /// The compiler arguments, including working directory. This is required since sourcekitd only
  /// accepts the working directory via the compiler arguments.
  public let compilerArgs: [String]

  /// Whether the compiler arguments are considered fallback - we withhold diagnostics for
  /// fallback arguments and represent the file state differently.
  public let isFallback: Bool

  public init(_ settings: FileBuildSettings, isFallback: Bool = false) {
    let baseArgs = settings.compilerArguments
    // Add working directory arguments if needed.
    if let workingDirectory = settings.workingDirectory, !baseArgs.contains("-working-directory") {
      self.compilerArgs = baseArgs + ["-working-directory", workingDirectory]
    } else {
      self.compilerArgs = baseArgs
    }
    self.isFallback = isFallback
  }
}

public actor SwiftLanguageServer: ToolchainLanguageServer {
  /// The ``SourceKitServer`` instance that created this `ClangLanguageServerShim`.
  private weak var sourceKitServer: SourceKitServer?

  let sourcekitd: SourceKitD

  /// Queue on which notes from sourcekitd are handled to ensure we are
  /// handling them in-order.
  let sourcekitdNoteHandlingQueue = AsyncQueue(.serial)

  let capabilityRegistry: CapabilityRegistry

  let serverOptions: SourceKitServer.Options

  /// Directory where generated Swift interfaces will be stored.
  let generatedInterfacesPath: URL

  // FIXME: ideally we wouldn't need separate management from a parent server in the same process.
  var documentManager: DocumentManager

  var currentDiagnostics: [DocumentURI: [CachedDiagnostic]] = [:]

  var currentCompletionSession: CodeCompletionSession? = nil

  let syntaxTreeManager = SyntaxTreeManager()
  let semanticTokensManager = SemanticTokensManager()

  nonisolated var keys: sourcekitd_keys { return sourcekitd.keys }
  nonisolated var requests: sourcekitd_requests { return sourcekitd.requests }
  nonisolated var values: sourcekitd_values { return sourcekitd.values }

  var enablePublishDiagnostics: Bool {
    // Since LSP 3.17.0, diagnostics can be reported through pull-based requests,
    // in addition to the existing push-based publish notes.
    // If the client supports pull diagnostics, we report the capability
    // and we should disable the publish notes to avoid double-reporting.
    return capabilityRegistry.pullDiagnosticsRegistration(for: .swift) == nil
  }

  private var state: LanguageServerState {
    didSet {
      for handler in stateChangeHandlers {
        handler(oldValue, state)
      }
    }
  }

  private var stateChangeHandlers: [(_ oldState: LanguageServerState, _ newState: LanguageServerState) -> Void] = []

  /// Creates a language server for the given client using the sourcekitd dylib specified in `toolchain`.
  /// `reopenDocuments` is a closure that will be called if sourcekitd crashes and the `SwiftLanguageServer` asks its parent server to reopen all of its documents.
  /// Returns `nil` if `sourcektid` couldn't be found.
  public init?(
    sourceKitServer: SourceKitServer,
    toolchain: Toolchain,
    options: SourceKitServer.Options,
    workspace: Workspace
  ) throws {
    guard let sourcekitd = toolchain.sourcekitd else { return nil }
    self.sourceKitServer = sourceKitServer
    self.sourcekitd = try SourceKitDImpl.getOrCreate(dylibPath: sourcekitd)
    self.capabilityRegistry = workspace.capabilityRegistry
    self.serverOptions = options
    self.documentManager = DocumentManager()
    self.state = .connected
    self.generatedInterfacesPath = options.generatedInterfacesPath.asURL
    try FileManager.default.createDirectory(at: generatedInterfacesPath, withIntermediateDirectories: true)
  }

  /// - Important: For testing only
  public func setReusedNodeCallback(_ callback: ReusedNodeCallback?) async {
    await self.syntaxTreeManager.setReusedNodeCallback(callback)
  }

  func buildSettings(for document: DocumentURI) async -> SwiftCompileCommand? {
    guard let sourceKitServer else {
      log("Cannot retrieve build settings because SourceKitServer is no longer alive", level: .error)
      return nil
    }
    guard let workspace = await sourceKitServer.workspaceForDocument(uri: document) else {
      return nil
    }
    if let settings = await workspace.buildSystemManager.buildSettingsInferredFromMainFile(
      for: document,
      language: .swift
    ) {
      return SwiftCompileCommand(settings.buildSettings, isFallback: settings.isFallback)
    } else {
      return nil
    }
  }

  public nonisolated func canHandle(workspace: Workspace) -> Bool {
    // We have a single sourcekitd instance for all workspaces.
    return true
  }

  public func addStateChangeHandler(
    handler: @escaping (_ oldState: LanguageServerState, _ newState: LanguageServerState) -> Void
  ) {
    self.stateChangeHandlers.append(handler)
  }

  /// Returns the semantic tokens in `response` for the given `snapshot`.
  private func semanticTokens(
    of response: SKDResponseDictionary,
    for snapshot: DocumentSnapshot
  ) -> [SyntaxHighlightingToken]? {
    logExecutionTime(level: .debug) {
      guard let skTokens: SKDResponseArray = response[keys.annotations] else {
        return nil
      }
      let tokenParser = SyntaxHighlightingTokenParser(sourcekitd: sourcekitd)
      var tokens: [SyntaxHighlightingToken] = []
      tokenParser.parseTokens(skTokens, in: snapshot, into: &tokens)

      return tokens
    }
  }

  /// Inform the client about changes to the syntax highlighting tokens.
  private func requestTokensRefresh() async {
    guard let sourceKitServer else {
      log("Cannot request a token refresh because SourceKitServer has been destructed", level: .error)
      return
    }
    if capabilityRegistry.clientHasSemanticTokenRefreshSupport {
      Task {
        do {
          _ = try await sourceKitServer.sendRequestToClient(WorkspaceSemanticTokensRefreshRequest())
        } catch {
          log("refreshing tokens failed: \(error)", level: .warning)
        }
      }
    }
  }

  /// Shift the ranges of all current diagnostics in the document with the given `uri` to account for `edit`.
  private func adjustDiagnosticRanges(of uri: DocumentURI, for edit: TextDocumentContentChangeEvent) {
    guard let rangeAdjuster = RangeAdjuster(edit: edit) else {
      return
    }
    currentDiagnostics[uri] = currentDiagnostics[uri]?.compactMap({ cachedDiag in
      if let adjustedRange = rangeAdjuster.adjust(cachedDiag.diagnostic.range) {
        return cachedDiag.withRange(adjustedRange)
      } else {
        return nil
      }
    })
  }

  /// Register the diagnostics returned from sourcekitd in `currentDiagnostics`
  /// and returns the corresponding LSP diagnostics.
  ///
  /// If `isFromFallbackBuildSettings` is `true`, then only parse diagnostics are
  /// stored and any semantic diagnostics are ignored since they are probably
  /// incorrect in the absence of build settings.
  private func registerDiagnostics(
    sourcekitdDiagnostics: SKDResponseArray?,
    snapshot: DocumentSnapshot,
    stage: DiagnosticStage,
    isFromFallbackBuildSettings: Bool
  ) -> [Diagnostic] {
    let supportsCodeDescription = capabilityRegistry.clientHasDiagnosticsCodeDescriptionSupport

    var newDiags: [CachedDiagnostic] = []
    sourcekitdDiagnostics?.forEach { _, diag in
      if let diag = CachedDiagnostic(diag, in: snapshot, useEducationalNoteAsCode: supportsCodeDescription) {
        newDiags.append(diag)
      }
      return true
    }

    let result = mergeDiagnostics(
      old: currentDiagnostics[snapshot.uri] ?? [],
      new: newDiags,
      stage: stage,
      isFallback: isFromFallbackBuildSettings
    )
    currentDiagnostics[snapshot.uri] = result

    return result.map(\.diagnostic)

  }

  /// Publish diagnostics for the given `snapshot`. We withhold semantic diagnostics if we are using
  /// fallback arguments.
  func publishDiagnostics(
    response: SKDResponseDictionary,
    for snapshot: DocumentSnapshot,
    compileCommand: SwiftCompileCommand?
  ) async {
    let documentUri = snapshot.uri
    guard diagnosticsEnabled(for: documentUri) else {
      log("Ignoring diagnostics for blacklisted file \(documentUri.pseudoPath)", level: .debug)
      return
    }

    let stageUID: sourcekitd_uid_t? = response[sourcekitd.keys.diagnostic_stage]
    let stage = stageUID.flatMap { DiagnosticStage($0, sourcekitd: sourcekitd) } ?? .sema

    let diagnostics = registerDiagnostics(
      sourcekitdDiagnostics: response[keys.diagnostics],
      snapshot: snapshot,
      stage: stage,
      isFromFallbackBuildSettings: compileCommand?.isFallback ?? true
    )

    await sourceKitServer?.sendNoteToClient(
      PublishDiagnosticsNote(
        uri: documentUri,
        version: snapshot.version,
        diagnostics: diagnostics
      )
    )
  }

  func handleDocumentUpdate(uri: DocumentURI) async {
    guard let snapshot = documentManager.latestSnapshot(uri) else {
      return
    }
    let compileCommand = await self.buildSettings(for: uri)

    // Make the magic 0,0 replacetext request to update diagnostics and semantic tokens.

    let req = SKDRequestDictionary(sourcekitd: sourcekitd)
    req[keys.request] = requests.editor_replacetext
    req[keys.name] = uri.pseudoPath
    req[keys.offset] = 0
    req[keys.length] = 0
    req[keys.sourcetext] = ""

    if let dict = try? self.sourcekitd.sendSync(req) {
      let isSemaStage = dict[keys.diagnostic_stage] as sourcekitd_uid_t? == sourcekitd.values.diag_stage_sema
      if isSemaStage, let semanticTokens = semanticTokens(of: dict, for: snapshot) {
        // Only update semantic tokens if the 0,0 replacetext request returned semantic information.
        await semanticTokensManager.setSemanticTokens(for: snapshot.id, semanticTokens: semanticTokens)
      }
      if enablePublishDiagnostics {
        await publishDiagnostics(response: dict, for: snapshot, compileCommand: compileCommand)
      }
      if isSemaStage {
        await requestTokensRefresh()
      }
    }
  }
}

extension SwiftLanguageServer {

  public func initializeSync(_ initialize: InitializeRequest) throws -> InitializeResult {
    sourcekitd.addNoteHandler(self)

    return InitializeResult(
      capabilities: ServerCapabilities(
        textDocumentSync: .options(
          TextDocumentSyncOptions(
            openClose: true,
            change: .incremental
          )
        ),
        hoverProvider: .bool(true),
        completionProvider: CompletionOptions(
          resolveProvider: false,
          triggerCharacters: [".", "("]
        ),
        definitionProvider: nil,
        implementationProvider: .bool(true),
        referencesProvider: nil,
        documentHighlightProvider: .bool(true),
        documentSymbolProvider: .bool(true),
        codeActionProvider: .value(
          CodeActionServerCapabilities(
            clientCapabilities: initialize.capabilities.textDocument?.codeAction,
            codeActionOptions: CodeActionOptions(codeActionKinds: [.quickFix, .refactor]),
            supportsCodeActions: true
          )
        ),
        colorProvider: .bool(true),
        foldingRangeProvider: .bool(true),
        executeCommandProvider: ExecuteCommandOptions(
          commands: builtinSwiftCommands
        ),
        semanticTokensProvider: SemanticTokensOptions(
          legend: SemanticTokensLegend(
            tokenTypes: SyntaxHighlightingToken.Kind.allCases.map(\.lspName),
            tokenModifiers: SyntaxHighlightingToken.Modifiers.allModifiers.map { $0.lspName! }
          ),
          range: .bool(true),
          full: .bool(true)
        ),
        inlayHintProvider: .value(
          InlayHintOptions(
            resolveProvider: false
          )
        ),
        diagnosticProvider: DiagnosticOptions(
          interFileDependencies: true,
          workspaceDiagnostics: false
        )
      )
    )
  }

  public func clientInitialized(_: InitializedNote) {
    // Nothing to do.
  }

  public func shutdown() async {
    if let session = self.currentCompletionSession {
      await session.close()
      self.currentCompletionSession = nil
    }
    self.sourcekitd.removeNoteHandler(self)
  }

  /// Tell sourcekitd to crash itself. For testing purposes only.
  public func _crash() {
    let req = SKDRequestDictionary(sourcekitd: sourcekitd)
    req[sourcekitd.keys.request] = sourcekitd.requests.crash_exit
    _ = try? sourcekitd.sendSync(req)
  }

  // MARK: - Build System Integration

  private func reopenDocument(_ snapshot: DocumentSnapshot, _ compileCmd: SwiftCompileCommand?) async {
    let keys = self.keys
    let path = snapshot.uri.pseudoPath

    let closeReq = SKDRequestDictionary(sourcekitd: self.sourcekitd)
    closeReq[keys.request] = self.requests.editor_close
    closeReq[keys.name] = path
    _ = try? self.sourcekitd.sendSync(closeReq)

    let openReq = SKDRequestDictionary(sourcekitd: self.sourcekitd)
    openReq[keys.request] = self.requests.editor_open
    openReq[keys.name] = path
    openReq[keys.sourcetext] = snapshot.text
    if let compileCmd = compileCmd {
      openReq[keys.compilerargs] = compileCmd.compilerArgs
    }

    guard let dict = try? self.sourcekitd.sendSync(openReq) else {
      // Already logged failure.
      return
    }
    await self.publishDiagnostics(
      response: dict,
      for: snapshot,
      compileCommand: compileCmd
    )
  }

  public func documentUpdatedBuildSettings(_ uri: DocumentURI) async {
    // We may not have a snapshot if this is called just before `openDocument`.
    guard let snapshot = self.documentManager.latestSnapshot(uri) else {
      return
    }

    // Close and re-open the document internally to inform sourcekitd to update the compile
    // command. At the moment there's no better way to do this.
    await self.reopenDocument(snapshot, await self.buildSettings(for: uri))
  }

  public func documentDependenciesUpdated(_ uri: DocumentURI) async {
    guard let snapshot = self.documentManager.latestSnapshot(uri) else {
      return
    }

    // Forcefully reopen the document since the `BuildSystem` has informed us
    // that the dependencies have changed and the AST needs to be reloaded.
    await self.reopenDocument(snapshot, self.buildSettings(for: uri))
  }

  // MARK: - Text synchronization

  public func openDocument(_ note: DidOpenTextDocumentNote) async {
    let keys = self.keys

    guard let snapshot = self.documentManager.open(note) else {
      // Already logged failure.
      return
    }

    let req = SKDRequestDictionary(sourcekitd: self.sourcekitd)
    req[keys.request] = self.requests.editor_open
    req[keys.name] = note.textDocument.uri.pseudoPath
    req[keys.sourcetext] = snapshot.text

    let compileCommand = await self.buildSettings(for: snapshot.uri)

    if let compilerArgs = compileCommand?.compilerArgs {
      req[keys.compilerargs] = compilerArgs
    }

    guard let dict = try? self.sourcekitd.sendSync(req) else {
      // Already logged failure.
      return
    }
    await self.publishDiagnostics(response: dict, for: snapshot, compileCommand: compileCommand)
  }

  public func closeDocument(_ note: DidCloseTextDocumentNote) async {
    let keys = self.keys

    self.documentManager.close(note)

    let uri = note.textDocument.uri

    let req = SKDRequestDictionary(sourcekitd: self.sourcekitd)
    req[keys.request] = self.requests.editor_close
    req[keys.name] = uri.pseudoPath

    // Clear settings that should not be cached for closed documents.
    self.currentDiagnostics[uri] = nil

    _ = try? self.sourcekitd.sendSync(req)

    await semanticTokensManager.discardSemanticTokens(for: note.textDocument.uri)
  }

  public func changeDocument(_ note: DidChangeTextDocumentNote) async {
    let keys = self.keys
    var edits: [IncrementalEdit] = []

    var lastResponse: SKDResponseDictionary? = nil

    let editResult = self.documentManager.edit(note) {
      (before: LineTable, edit: TextDocumentContentChangeEvent) in
      let req = SKDRequestDictionary(sourcekitd: self.sourcekitd)
      req[keys.request] = self.requests.editor_replacetext
      req[keys.name] = note.textDocument.uri.pseudoPath

      if let range = edit.range {
        guard let offset = before.utf8OffsetOf(line: range.lowerBound.line, utf16Column: range.lowerBound.utf16index),
          let end = before.utf8OffsetOf(line: range.upperBound.line, utf16Column: range.upperBound.utf16index)
        else {
          fatalError("invalid edit \(range)")
        }

        let length = end - offset
        req[keys.offset] = offset
        req[keys.length] = length

        edits.append(IncrementalEdit(offset: offset, length: length, replacementLength: edit.text.utf8.count))
      } else {
        // Full text
        let length = before.content.utf8.count
        req[keys.offset] = 0
        req[keys.length] = length

        edits.append(IncrementalEdit(offset: 0, length: length, replacementLength: edit.text.utf8.count))
      }

      req[keys.sourcetext] = edit.text
      lastResponse = try? self.sourcekitd.sendSync(req)

      self.adjustDiagnosticRanges(of: note.textDocument.uri, for: edit)
    }
    guard let (preEditSnapshot, postEditSnapshot) = editResult else {
      return
    }
    await syntaxTreeManager.registerEdit(
      preEditSnapshot: preEditSnapshot,
      postEditSnapshot: postEditSnapshot,
      edits: ConcurrentEdits(fromSequential: edits)
    )
    await semanticTokensManager.registerEdit(
      preEditSnapshot: preEditSnapshot.id,
      postEditSnapshot: postEditSnapshot.id,
      edits: note.contentChanges
    )

    if let dict = lastResponse {
      let compileCommand = await self.buildSettings(for: note.textDocument.uri)
      await self.publishDiagnostics(response: dict, for: postEditSnapshot, compileCommand: compileCommand)
    }
  }

  public func willSaveDocument(_ note: WillSaveTextDocumentNote) {

  }

  public func didSaveDocument(_ note: DidSaveTextDocumentNote) {

  }

  // MARK: - Language features

  /// Returns true if the `ToolchainLanguageServer` will take ownership of the request.
  public func definition(_ request: DefinitionRequest) async throws -> LocationsOrLocationLinksResponse? {
    throw ResponseError.unknown("unsupported method")
  }

  public func declaration(_ request: DeclarationRequest) async throws -> LocationsOrLocationLinksResponse? {
    throw ResponseError.unknown("unsupported method")
  }

  public func hover(_ req: HoverRequest) async throws -> HoverResponse? {
    let uri = req.textDocument.uri
    let position = req.position
    guard let cursorInfo = try await cursorInfo(uri, position..<position) else {
      return nil
    }

    guard let name: String = cursorInfo.symbolInfo.name else {
      // There is a cursor but we don't know how to deal with it.
      return nil
    }

    /// Prepend backslash to `*` and `_`, to prevent them
    /// from being interpreted as markdown.
    func escapeNameMarkdown(_ str: String) -> String {
      return String(str.flatMap({ ($0 == "*" || $0 == "_") ? ["\\", $0] : [$0] }))
    }

    var result = escapeNameMarkdown(name)
    if let doc = cursorInfo.documentationXML {
      result += """

        \(orLog { try xmlDocumentationToMarkdown(doc) } ?? doc)
        """
    } else if let annotated: String = cursorInfo.annotatedDeclaration {
      result += """

        \(orLog { try xmlDocumentationToMarkdown(annotated) } ?? annotated)
        """
    }

    return HoverResponse(contents: .markupContent(MarkupContent(kind: .markdown, value: result)), range: nil)
  }

  public func symbolInfo(_ req: SymbolInfoRequest) async throws -> [SymbolDetails] {
    let uri = req.textDocument.uri
    let position = req.position
    guard let cursorInfo = try await cursorInfo(uri, position..<position) else {
      return []
    }
    return [cursorInfo.symbolInfo]
  }

  public func documentSymbol(_ req: DocumentSymbolRequest) async throws -> DocumentSymbolResponse? {
    guard let snapshot = self.documentManager.latestSnapshot(req.textDocument.uri) else {
      let msg = "failed to find snapshot for url \(req.textDocument.uri)"
      log(msg)
      throw ResponseError.unknown(msg)
    }

    let helperDocumentName = "DocumentSymbols:" + snapshot.uri.pseudoPath
    let skreq = SKDRequestDictionary(sourcekitd: self.sourcekitd)
    skreq[keys.request] = self.requests.editor_open
    skreq[keys.name] = helperDocumentName
    skreq[keys.sourcetext] = snapshot.text
    skreq[keys.syntactic_only] = 1

    let dict = try await self.sourcekitd.send(skreq)
    defer {
      let closeHelperReq = SKDRequestDictionary(sourcekitd: self.sourcekitd)
      closeHelperReq[self.keys.request] = self.requests.editor_close
      closeHelperReq[self.keys.name] = helperDocumentName
      // FIXME: (async) We might receive two concurrent document symbol requests for the
      // same document, in which race to open/close a document with the same name in
      // sourcekitd. The solution is to either
      //  - Not open the helper document and instead rely on the document that is already
      //    open or
      //  - Prefix the helper document with a UUID to make sure the two concurrent
      //    requests operate on different documents as far as sourcekitd is concerned.
      Task {
        _ = try await self.sourcekitd.send(closeHelperReq)
      }
    }

    guard let results: SKDResponseArray = dict[self.keys.substructure] else {
      return .documentSymbols([])
    }

    func documentSymbol(value: SKDResponseDictionary) -> DocumentSymbol? {
      guard let name: String = value[self.keys.name],
        let uid: sourcekitd_uid_t = value[self.keys.kind],
        let kind: SymbolKind = uid.asSymbolKind(self.values),
        let offset: Int = value[self.keys.offset],
        let start: Position = snapshot.positionOf(utf8Offset: offset),
        let length: Int = value[self.keys.length],
        let end: Position = snapshot.positionOf(utf8Offset: offset + length)
      else {
        return nil
      }

      let range = start..<end
      let selectionRange: Range<Position>
      if let nameOffset: Int = value[self.keys.nameoffset],
        let nameStart: Position = snapshot.positionOf(utf8Offset: nameOffset),
        let nameLength: Int = value[self.keys.namelength],
        let nameEnd: Position = snapshot.positionOf(utf8Offset: nameOffset + nameLength)
      {
        selectionRange = nameStart..<nameEnd
      } else {
        selectionRange = range
      }

      let children: [DocumentSymbol]
      if let substructure: SKDResponseArray = value[self.keys.substructure] {
        children = documentSymbols(array: substructure)
      } else {
        children = []
      }
      return DocumentSymbol(
        name: name,
        detail: value[self.keys.typename] as String?,
        kind: kind,
        deprecated: nil,
        range: range,
        selectionRange: selectionRange,
        children: children
      )
    }

    func documentSymbols(array: SKDResponseArray) -> [DocumentSymbol] {
      var result: [DocumentSymbol] = []
      array.forEach { (i: Int, value: SKDResponseDictionary) in
        if let documentSymbol = documentSymbol(value: value) {
          result.append(documentSymbol)
        } else if let substructure: SKDResponseArray = value[self.keys.substructure] {
          result += documentSymbols(array: substructure)
        }
        return true
      }
      return result
    }

    return .documentSymbols(documentSymbols(array: results))
  }

  public func documentColor(_ req: DocumentColorRequest) async throws -> [ColorInformation] {
    let keys = self.keys

    guard let snapshot = self.documentManager.latestSnapshot(req.textDocument.uri) else {
      log("failed to find snapshot for url \(req.textDocument.uri)")
      return []
    }

    let helperDocumentName = "DocumentColor:" + snapshot.uri.pseudoPath
    let skreq = SKDRequestDictionary(sourcekitd: self.sourcekitd)
    skreq[keys.request] = self.requests.editor_open
    skreq[keys.name] = helperDocumentName
    skreq[keys.sourcetext] = snapshot.text
    skreq[keys.syntactic_only] = 1

    let dict = try await self.sourcekitd.send(skreq)
    defer {
      let closeHelperReq = SKDRequestDictionary(sourcekitd: self.sourcekitd)
      closeHelperReq[keys.request] = self.requests.editor_close
      closeHelperReq[keys.name] = helperDocumentName
      // FIXME: (async) We might receive two concurrent document color requests for the
      // same document, in which race to open/close a document with the same name in
      // sourcekitd. The solution is to either
      //  - Not open the helper document and instead rely on the document that is already
      //    open or
      //  - Prefix the helper document with a UUID to make sure the two concurrent
      //    requests operate on different documents as far as sourcekitd is concerned.
      Task {
        _ = try? await self.sourcekitd.send(closeHelperReq)
      }
    }

    guard let results: SKDResponseArray = dict[self.keys.substructure] else {
      return []
    }

    func colorInformation(dict: SKDResponseDictionary) -> ColorInformation? {
      guard let kind: sourcekitd_uid_t = dict[self.keys.kind],
        kind == self.values.expr_object_literal,
        let name: String = dict[self.keys.name],
        name == "colorLiteral",
        let offset: Int = dict[self.keys.offset],
        let start: Position = snapshot.positionOf(utf8Offset: offset),
        let length: Int = dict[self.keys.length],
        let end: Position = snapshot.positionOf(utf8Offset: offset + length),
        let substructure: SKDResponseArray = dict[self.keys.substructure]
      else {
        return nil
      }
      var red, green, blue, alpha: Double?
      substructure.forEach { (i: Int, value: SKDResponseDictionary) in
        guard let name: String = value[self.keys.name],
          let bodyoffset: Int = value[self.keys.bodyoffset],
          let bodylength: Int = value[self.keys.bodylength]
        else {
          return true
        }
        let view = snapshot.text.utf8
        let bodyStart = view.index(view.startIndex, offsetBy: bodyoffset)
        let bodyEnd = view.index(view.startIndex, offsetBy: bodyoffset + bodylength)
        let value = String(view[bodyStart..<bodyEnd]).flatMap(Double.init)
        switch name {
        case "red":
          red = value
        case "green":
          green = value
        case "blue":
          blue = value
        case "alpha":
          alpha = value
        default:
          break
        }
        return true
      }
      if let red = red,
        let green = green,
        let blue = blue,
        let alpha = alpha
      {
        let color = Color(red: red, green: green, blue: blue, alpha: alpha)
        return ColorInformation(range: start..<end, color: color)
      } else {
        return nil
      }
    }

    func colorInformation(array: SKDResponseArray) -> [ColorInformation] {
      var result: [ColorInformation] = []
      array.forEach { (i: Int, value: SKDResponseDictionary) in
        if let documentSymbol = colorInformation(dict: value) {
          result.append(documentSymbol)
        } else if let substructure: SKDResponseArray = value[self.keys.substructure] {
          result += colorInformation(array: substructure)
        }
        return true
      }
      return result
    }

    return colorInformation(array: results)
  }

  public func colorPresentation(_ req: ColorPresentationRequest) async throws -> [ColorPresentation] {
    let color = req.color
    // Empty string as a label breaks VSCode color picker
    let label = "Color Literal"
    let newText = "#colorLiteral(red: \(color.red), green: \(color.green), blue: \(color.blue), alpha: \(color.alpha))"
    let textEdit = TextEdit(range: req.range, newText: newText)
    let presentation = ColorPresentation(label: label, textEdit: textEdit, additionalTextEdits: nil)
    return [presentation]
  }

  public func documentSymbolHighlight(_ req: DocumentHighlightRequest) async throws -> [DocumentHighlight]? {
    let keys = self.keys

    guard let snapshot = self.documentManager.latestSnapshot(req.textDocument.uri) else {
      log("failed to find snapshot for url \(req.textDocument.uri)")
      return nil
    }

    guard let offset = snapshot.utf8Offset(of: req.position) else {
      log("invalid position \(req.position)")
      return nil
    }

    let skreq = SKDRequestDictionary(sourcekitd: self.sourcekitd)
    skreq[keys.request] = self.requests.relatedidents
    skreq[keys.offset] = offset
    skreq[keys.sourcefile] = snapshot.uri.pseudoPath

    // FIXME: SourceKit should probably cache this for us.
    if let compileCommand = await self.buildSettings(for: snapshot.uri) {
      skreq[keys.compilerargs] = compileCommand.compilerArgs
    }

    let dict = try await self.sourcekitd.send(skreq)

    guard let results: SKDResponseArray = dict[self.keys.results] else {
      return []
    }

    try Task.checkCancellation()

    var highlights: [DocumentHighlight] = []

    results.forEach { _, value in
      if let offset: Int = value[self.keys.offset],
        let start: Position = snapshot.positionOf(utf8Offset: offset),
        let length: Int = value[self.keys.length],
        let end: Position = snapshot.positionOf(utf8Offset: offset + length)
      {
        highlights.append(
          DocumentHighlight(
            range: start..<end,
            kind: .read  // unknown
          )
        )
      }
      return true
    }

    return highlights
  }

  public func foldingRange(_ req: FoldingRangeRequest) async throws -> [FoldingRange]? {
    let foldingRangeCapabilities = capabilityRegistry.clientCapabilities.textDocument?.foldingRange
    let uri = req.textDocument.uri
    guard let snapshot = self.documentManager.latestSnapshot(uri) else {
      log("failed to find snapshot for url \(req.textDocument.uri)")
      return nil
    }

    let sourceFile = await syntaxTreeManager.syntaxTree(for: snapshot)

    final class FoldingRangeFinder: SyntaxVisitor {
      private let snapshot: DocumentSnapshot
      /// Some ranges might occur multiple times.
      /// E.g. for `print("hi")`, `"hi"` is both the range of all call arguments and the range the first argument in the call.
      /// It doesn't make sense to report them multiple times, so use a `Set` here.
      private var ranges: Set<FoldingRange>
      /// The client-imposed limit on the number of folding ranges it would
      /// prefer to recieve from the LSP server. If the value is `nil`, there
      /// is no preset limit.
      private var rangeLimit: Int?
      /// If `true`, the client is only capable of folding entire lines. If
      /// `false` the client can handle folding ranges.
      private var lineFoldingOnly: Bool

      init(snapshot: DocumentSnapshot, rangeLimit: Int?, lineFoldingOnly: Bool) {
        self.snapshot = snapshot
        self.ranges = []
        self.rangeLimit = rangeLimit
        self.lineFoldingOnly = lineFoldingOnly
        super.init(viewMode: .sourceAccurate)
      }

      override func visit(_ node: TokenSyntax) -> SyntaxVisitorContinueKind {
        // Index comments, so we need to see at least '/*', or '//'.
        if node.leadingTriviaLength.utf8Length > 2 {
          self.addTrivia(from: node, node.leadingTrivia)
        }

        if node.trailingTriviaLength.utf8Length > 2 {
          self.addTrivia(from: node, node.trailingTrivia)
        }

        return .visitChildren
      }

      private func addTrivia(from node: TokenSyntax, _ trivia: Trivia) {
        let pieces = trivia.pieces
        var start = node.position.utf8Offset
        /// The index of the trivia piece we are currently inspecting.
        var index = 0

        while index < pieces.count {
          let piece = pieces[index]
          defer {
            start += pieces[index].sourceLength.utf8Length
            index += 1
          }
          switch piece {
          case .blockComment:
            _ = self.addFoldingRange(
              start: start,
              end: start + piece.sourceLength.utf8Length,
              kind: .comment
            )
          case .docBlockComment:
            _ = self.addFoldingRange(
              start: start,
              end: start + piece.sourceLength.utf8Length,
              kind: .comment
            )
          case .lineComment, .docLineComment:
            let lineCommentBlockStart = start

            // Keep scanning the upcoming trivia pieces to find the end of the
            // block of line comments.
            // As we find a new end of the block comment, we set `index` and
            // `start` to `lookaheadIndex` and `lookaheadStart` resp. to
            // commit the newly found end.
            var lookaheadIndex = index
            var lookaheadStart = start
            var hasSeenNewline = false
            LOOP: while lookaheadIndex < pieces.count {
              let piece = pieces[lookaheadIndex]
              defer {
                lookaheadIndex += 1
                lookaheadStart += piece.sourceLength.utf8Length
              }
              switch piece {
              case .newlines(let count), .carriageReturns(let count), .carriageReturnLineFeeds(let count):
                if count > 1 || hasSeenNewline {
                  // More than one newline is separating the two line comment blocks.
                  // We have reached the end of this block of line comments.
                  break LOOP
                }
                hasSeenNewline = true
              case .spaces, .tabs:
                // We allow spaces and tabs because the comments might be indented
                continue
              case .lineComment, .docLineComment:
                // We have found a new line comment in this block. Commit it.
                index = lookaheadIndex
                start = lookaheadStart
                hasSeenNewline = false
              default:
                // We assume that any other trivia piece terminates the block
                // of line comments.
                break LOOP
              }
            }
            _ = self.addFoldingRange(
              start: lineCommentBlockStart,
              end: start + pieces[index].sourceLength.utf8Length,
              kind: .comment
            )
          default:
            break
          }
        }
      }

      override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind {
        return self.addFoldingRange(
          start: node.statements.position.utf8Offset,
          end: node.rightBrace.positionAfterSkippingLeadingTrivia.utf8Offset
        )
      }

      override func visit(_ node: MemberBlockSyntax) -> SyntaxVisitorContinueKind {
        return self.addFoldingRange(
          start: node.members.position.utf8Offset,
          end: node.rightBrace.positionAfterSkippingLeadingTrivia.utf8Offset
        )
      }

      override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        return self.addFoldingRange(
          start: node.statements.position.utf8Offset,
          end: node.rightBrace.positionAfterSkippingLeadingTrivia.utf8Offset
        )
      }

      override func visit(_ node: AccessorBlockSyntax) -> SyntaxVisitorContinueKind {
        return self.addFoldingRange(
          start: node.accessors.position.utf8Offset,
          end: node.rightBrace.positionAfterSkippingLeadingTrivia.utf8Offset
        )
      }

      override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind {
        return self.addFoldingRange(
          start: node.cases.position.utf8Offset,
          end: node.rightBrace.positionAfterSkippingLeadingTrivia.utf8Offset
        )
      }

      override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        return self.addFoldingRange(
          start: node.arguments.position.utf8Offset,
          end: node.arguments.endPosition.utf8Offset
        )
      }

      override func visit(_ node: SubscriptCallExprSyntax) -> SyntaxVisitorContinueKind {
        return self.addFoldingRange(
          start: node.arguments.position.utf8Offset,
          end: node.arguments.endPosition.utf8Offset
        )
      }

      __consuming func finalize() -> Set<FoldingRange> {
        return self.ranges
      }

      private func addFoldingRange(start: Int, end: Int, kind: FoldingRangeKind? = nil) -> SyntaxVisitorContinueKind {
        if let limit = self.rangeLimit, self.ranges.count >= limit {
          return .skipChildren
        }

        guard let start: Position = snapshot.positionOf(utf8Offset: start),
          let end: Position = snapshot.positionOf(utf8Offset: end)
        else {
          log("folding range failed to retrieve position of \(snapshot.uri): \(start)-\(end)", level: .warning)
          return .visitChildren
        }
        let range: FoldingRange
        if lineFoldingOnly {
          // Since the client cannot fold less than a single line, if the
          // fold would span 1 line there's no point in reporting it.
          guard end.line > start.line else {
            return .visitChildren
          }

          // If the client only supports folding full lines, don't report
          // the end of the range since there's nothing they could do with it.
          range = FoldingRange(
            startLine: start.line,
            startUTF16Index: nil,
            endLine: end.line,
            endUTF16Index: nil,
            kind: kind
          )
        } else {
          range = FoldingRange(
            startLine: start.line,
            startUTF16Index: start.utf16index,
            endLine: end.line,
            endUTF16Index: end.utf16index,
            kind: kind
          )
        }
        ranges.insert(range)
        return .visitChildren
      }
    }

    try Task.checkCancellation()

    // If the limit is less than one, do nothing.
    if let limit = foldingRangeCapabilities?.rangeLimit, limit <= 0 {
      return []
    }

    let rangeFinder = FoldingRangeFinder(
      snapshot: snapshot,
      rangeLimit: foldingRangeCapabilities?.rangeLimit,
      lineFoldingOnly: foldingRangeCapabilities?.lineFoldingOnly ?? false
    )
    rangeFinder.walk(sourceFile)
    let ranges = rangeFinder.finalize()

    return ranges.sorted()
  }

  public func codeAction(_ req: CodeActionRequest) async throws -> CodeActionRequestResponse? {
    let providersAndKinds: [(provider: CodeActionProvider, kind: CodeActionKind)] = [
      (retrieveRefactorCodeActions, .refactor),
      (retrieveQuickFixCodeActions, .quickFix),
    ]
    let wantedActionKinds = req.context.only
    let providers = providersAndKinds.filter { wantedActionKinds?.contains($0.1) != false }
    let codeActionCapabilities = capabilityRegistry.clientCapabilities.textDocument?.codeAction
    let codeActions = try await retrieveCodeActions(req, providers: providers.map { $0.provider })
    let response = CodeActionRequestResponse(
      codeActions: codeActions,
      clientCapabilities: codeActionCapabilities
    )
    return response
  }

  func retrieveCodeActions(_ req: CodeActionRequest, providers: [CodeActionProvider]) async throws -> [CodeAction] {
    guard providers.isEmpty == false else {
      return []
    }
    let codeActions = await withTaskGroup(of: [CodeAction].self) { taskGroup in
      for provider in providers {
        taskGroup.addTask {
          do {
            return try await provider(req)
          } catch {
            // Ignore any providers that failed to provide refactoring actions.
            return []
          }
        }
      }
      var results: [CodeAction] = []
      for await taskResults in taskGroup {
        results += taskResults
      }
      return results
    }
    return codeActions
  }

  func retrieveRefactorCodeActions(_ params: CodeActionRequest) async throws -> [CodeAction] {
    let additionalCursorInfoParameters: ((SKDRequestDictionary) -> Void) = { skreq in
      skreq[self.keys.retrieve_refactor_actions] = 1
    }

    let cursorInfoResponse = try await cursorInfo(
      params.textDocument.uri,
      params.range,
      additionalParameters: additionalCursorInfoParameters
    )

    guard let cursorInfoResponse else {
      throw ResponseError.unknown("CursorInfo failed.")
    }
    guard let refactorActions = cursorInfoResponse.refactorActions else {
      return []
    }
    let codeActions: [CodeAction] = refactorActions.compactMap {
      do {
        let lspCommand = try $0.asCommand()
        return CodeAction(title: $0.title, kind: .refactor, command: lspCommand)
      } catch {
        log("Failed to convert SwiftCommand to Command type: \(error)", level: .error)
        return nil
      }
    }
    return codeActions
  }

  func retrieveQuickFixCodeActions(_ params: CodeActionRequest) -> [CodeAction] {
    guard let cachedDiags = currentDiagnostics[params.textDocument.uri] else {
      return []
    }

    let codeActions = cachedDiags.flatMap { (cachedDiag) -> [CodeAction] in
      let diag = cachedDiag.diagnostic

      let codeActions: [CodeAction] =
        (diag.codeActions ?? []) + (diag.relatedInformation?.flatMap { $0.codeActions ?? [] } ?? [])

      if codeActions.isEmpty {
        // The diagnostic doesn't have fix-its. Don't return anything.
        return []
      }

      // Check if the diagnostic overlaps with the selected range.
      guard params.range.overlapsIncludingEmptyRanges(other: diag.range) else {
        return []
      }

      // Check if the set of diagnostics provided by the request contains this diagnostic.
      // For this, only compare the 'basic' properties of the diagnostics, excluding related information and code actions since
      // code actions are only defined in an LSP extension and might not be sent back to us.
      guard
        params.context.diagnostics.contains(where: { (contextDiag) -> Bool in
          return contextDiag.range == diag.range && contextDiag.severity == diag.severity
            && contextDiag.code == diag.code && contextDiag.source == diag.source
            && contextDiag.message == diag.message
        })
      else {
        return []
      }

      // Flip the attachment of diagnostic to code action instead of the code action being attached to the diagnostic
      return codeActions.map({
        var codeAction = $0
        var diagnosticWithoutCodeActions = diag
        diagnosticWithoutCodeActions.codeActions = nil
        if let related = diagnosticWithoutCodeActions.relatedInformation {
          diagnosticWithoutCodeActions.relatedInformation = related.map {
            var withoutCodeActions = $0
            withoutCodeActions.codeActions = nil
            return withoutCodeActions
          }
        }
        codeAction.diagnostics = [diagnosticWithoutCodeActions]
        return codeAction
      })
    }

    return codeActions
  }

  public func inlayHint(_ req: InlayHintRequest) async throws -> [InlayHint] {
    let uri = req.textDocument.uri
    let infos = try await variableTypeInfos(uri, req.range)
    let hints = infos
      .lazy
      .filter { !$0.hasExplicitType }
      .map { info -> InlayHint in
        let position = info.range.upperBound
        let label = ": \(info.printedType)"
        let textEdits: [TextEdit]?
        if info.canBeFollowedByTypeAnnotation {
          textEdits = [TextEdit(range: position..<position, newText: label)]
        } else {
          textEdits = nil
        }
        return InlayHint(
          position: position,
          label: .string(label),
          kind: .type,
          textEdits: textEdits
        )
      }

    return Array(hints)
  }

  public func documentDiagnostic(_ req: DocumentDiagnosticsRequest) async throws -> DocumentDiagnosticReport {
    guard let snapshot = documentManager.latestSnapshot(req.textDocument.uri) else {
      let msg = "failed to find snapshot for url \(req.textDocument.uri)"
      log(msg)
      throw ResponseError.unknown(msg)
    }

    let keys = self.keys

    let skreq = SKDRequestDictionary(sourcekitd: self.sourcekitd)
    skreq[keys.request] = requests.diagnostics
    skreq[keys.sourcefile] = snapshot.uri.pseudoPath

    // FIXME: SourceKit should probably cache this for us.
    let areFallbackBuildSettings: Bool
    if let buildSettings = await self.buildSettings(for: req.textDocument.uri) {
      skreq[keys.compilerargs] = buildSettings.compilerArgs
      areFallbackBuildSettings = buildSettings.isFallback
    } else {
      areFallbackBuildSettings = true
    }

    let dict = try await self.sourcekitd.send(skreq)
    let diagnostics = self.registerDiagnostics(
      sourcekitdDiagnostics: dict[keys.diagnostics],
      snapshot: snapshot,
      stage: .sema,
      isFromFallbackBuildSettings: areFallbackBuildSettings
    )

    return .full(RelatedFullDocumentDiagnosticReport(items: diagnostics))
  }

  public func executeCommand(_ req: ExecuteCommandRequest) async throws -> LSPAny? {
    // TODO: If there's support for several types of commands, we might need to structure this similarly to the code actions request.
    guard let sourceKitServer else {
      // `SourceKitServer` has been destructed. We are tearing down the language
      // server. Nothing left to do.
      throw ResponseError.unknown("Connection to the editor closed")
    }
    guard let swiftCommand = req.swiftCommand(ofType: SemanticRefactorCommand.self) else {
      let message = "semantic refactoring: unknown command \(req.command)"
      log(message, level: .warning)
      throw ResponseError.unknown(message)
    }
    let refactor = try await semanticRefactoring(swiftCommand)
    let edit = refactor.edit
    let req = ApplyEditRequest(label: refactor.title, edit: edit)
    let response = try await sourceKitServer.sendRequestToClient(req)
    if !response.applied {
      let reason: String
      if let failureReason = response.failureReason {
        reason = " reason: \(failureReason)"
      } else {
        reason = ""
      }
      log("client refused to apply edit for \(refactor.title)!\(reason)", level: .warning)
    }
    return edit.encodeToLSPAny()
  }
}

extension SwiftLanguageServer: SKDNoteHandler {
  public nonisolated func note(_ note: SKDResponse) {
    sourcekitdNoteHandlingQueue.async {
      await self.noteImpl(note)
    }
  }

  private func noteImpl(_ note: SKDResponse) async {
    // Check if we need to update our `state` based on the contents of the note.
    if note.value?[self.keys.note] == self.values.note_sema_enabled {
      self.state = .connected
    }

    if self.state == .connectionInterrupted {
      // If we get a note while we are restoring the connection, it means that the server has restarted.
      // We still need to wait for semantic functionality to come back up.
      self.state = .semanticFunctionalityDisabled

      // Ask our parent to re-open all of our documents.
      if let sourceKitServer {
        await sourceKitServer.reopenDocuments(for: self)
      } else {
        log("Cannot reopen documents because SourceKitServer is no longer alive", level: .error)
      }
    }

    if note.error == .connectionInterrupted {
      self.state = .connectionInterrupted

      // We don't have any open documents anymore after sourcekitd crashed.
      // Reset the document manager to reflect that.
      self.documentManager = DocumentManager()
    }

    guard let dict = note.value else {
      log(note.description, level: .error)
      return
    }

    logAsync(level: .debug) { _ in note.description }

    if let kind: sourcekitd_uid_t = dict[self.keys.note],
      kind == self.values.note_documentupdate,
      let name: String = dict[self.keys.name]
    {

      let uri: DocumentURI

      // Paths are expected to be absolute; on Windows, this means that the
      // path is either drive letter prefixed (and thus `PathGetDriveNumberW`
      // will provide the driver number OR it is a UNC path and `PathIsUNCW`
      // will return `true`.  On Unix platforms, the path will start with `/`
      // which takes care of both a regular absolute path and a POSIX
      // alternate root path.

      // TODO: this is not completely portable, e.g. MacOS 9 HFS paths are
      // unhandled.
      #if os(Windows)
      let isPath: Bool = name.withCString(encodedAs: UTF16.self) {
        !PathIsURLW($0)
      }
      #else
      let isPath: Bool = name.starts(with: "/")
      #endif
      if isPath {
        // If sourcekitd returns us a path, translate it back into a URL
        uri = DocumentURI(URL(fileURLWithPath: name))
      } else {
        uri = DocumentURI(string: name)
      }
      await self.handleDocumentUpdate(uri: uri)
    }
  }
}

extension DocumentSnapshot {

  func utf8Offset(of pos: Position) -> Int? {
    return lineTable.utf8OffsetOf(line: pos.line, utf16Column: pos.utf16index)
  }

  func utf8OffsetRange(of range: Range<Position>) -> Range<Int>? {
    guard let startOffset = utf8Offset(of: range.lowerBound),
      let endOffset = utf8Offset(of: range.upperBound)
    else {
      return nil
    }
    return startOffset..<endOffset
  }

  func positionOf(utf8Offset: Int) -> Position? {
    return lineTable.lineAndUTF16ColumnOf(utf8Offset: utf8Offset).map {
      Position(line: $0.line, utf16index: $0.utf16Column)
    }
  }

  func positionOf(zeroBasedLine: Int, utf8Column: Int) -> Position? {
    return lineTable.utf16ColumnAt(line: zeroBasedLine, utf8Column: utf8Column).map {
      Position(line: zeroBasedLine, utf16index: $0)
    }
  }

  func indexOf(utf8Offset: Int) -> String.Index? {
    return text.utf8.index(text.startIndex, offsetBy: utf8Offset, limitedBy: text.endIndex)
  }
}

extension sourcekitd_uid_t {
  func isCommentKind(_ vals: sourcekitd_values) -> Bool {
    switch self {
    case vals.syntaxtype_comment, vals.syntaxtype_comment_marker, vals.syntaxtype_comment_url:
      return true
    default:
      return isDocCommentKind(vals)
    }
  }

  func isDocCommentKind(_ vals: sourcekitd_values) -> Bool {
    return self == vals.syntaxtype_doccomment || self == vals.syntaxtype_doccomment_field
  }

  func asCompletionItemKind(_ vals: sourcekitd_values) -> CompletionItemKind? {
    switch self {
    case vals.kind_keyword:
      return .keyword
    case vals.decl_module:
      return .module
    case vals.decl_class:
      return .class
    case vals.decl_struct:
      return .struct
    case vals.decl_enum:
      return .enum
    case vals.decl_enumelement:
      return .enumMember
    case vals.decl_protocol:
      return .interface
    case vals.decl_associatedtype:
      return .typeParameter
    case vals.decl_typealias:
      return .typeParameter  // FIXME: is there a better choice?
    case vals.decl_generic_type_param:
      return .typeParameter
    case vals.decl_function_constructor:
      return .constructor
    case vals.decl_function_destructor:
      return .value  // FIXME: is there a better choice?
    case vals.decl_function_subscript:
      return .method  // FIXME: is there a better choice?
    case vals.decl_function_method_static:
      return .method
    case vals.decl_function_method_instance:
      return .method
    case vals.decl_function_operator_prefix,
      vals.decl_function_operator_postfix,
      vals.decl_function_operator_infix:
      return .operator
    case vals.decl_precedencegroup:
      return .value
    case vals.decl_function_free:
      return .function
    case vals.decl_var_static, vals.decl_var_class:
      return .property
    case vals.decl_var_instance:
      return .property
    case vals.decl_var_local,
      vals.decl_var_global,
      vals.decl_var_parameter:
      return .variable
    default:
      return nil
    }
  }

  func asSymbolKind(_ vals: sourcekitd_values) -> SymbolKind? {
    switch self {
    case vals.decl_class:
      return .class
    case vals.decl_function_method_instance,
      vals.decl_function_method_static,
      vals.decl_function_method_class:
      return .method
    case vals.decl_var_instance,
      vals.decl_var_static,
      vals.decl_var_class:
      return .property
    case vals.decl_enum:
      return .enum
    case vals.decl_enumelement:
      return .enumMember
    case vals.decl_protocol:
      return .interface
    case vals.decl_function_free:
      return .function
    case vals.decl_var_global,
      vals.decl_var_local:
      return .variable
    case vals.decl_struct:
      return .struct
    case vals.decl_generic_type_param:
      return .typeParameter
    case vals.decl_extension:
      // There are no extensions in LSP, so I return something vaguely similar
      return .namespace
    case vals.ref_module:
      return .module
    default:
      return nil
    }
  }
}
