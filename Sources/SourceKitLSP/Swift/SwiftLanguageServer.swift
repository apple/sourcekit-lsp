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
import struct Foundation.CharacterSet
import LanguageServerProtocol
import LSPLogging
import SKCore
import SKSupport
import SourceKitD
import SwiftSyntax
import SwiftParser

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

  public init?(change: FileBuildSettingsChange) {
    switch change {
    case .fallback(let settings): self.init(settings, isFallback: true)
    case .modified(let settings): self.init(settings, isFallback: false)
    case .removedOrUnavailable: return nil
    }
  }
}

public final class SwiftLanguageServer: ToolchainLanguageServer {

  /// The server's request queue, used to serialize requests and responses to `sourcekitd`.
  public let queue: DispatchQueue = DispatchQueue(label: "swift-language-server-queue", qos: .userInitiated)

  let client: LocalConnection

  let sourcekitd: SourceKitD

  let clientCapabilities: ClientCapabilities

  let serverOptions: SourceKitServer.Options

  // FIXME: ideally we wouldn't need separate management from a parent server in the same process.
  var documentManager: DocumentManager

  var currentDiagnostics: [DocumentURI: [CachedDiagnostic]] = [:]

  var currentCompletionSession: CodeCompletionSession? = nil

  var commandsByFile: [DocumentURI: SwiftCompileCommand] = [:]

  var keys: sourcekitd_keys { return sourcekitd.keys }
  var requests: sourcekitd_requests { return sourcekitd.requests }
  var values: sourcekitd_values { return sourcekitd.values }
  
  private var state: LanguageServerState {
    didSet {
      // `state` must only be set from `queue`.
      dispatchPrecondition(condition: .onQueue(queue))
      for handler in stateChangeHandlers {
        handler(oldValue, state)
      }
    }
  }
  
  private var stateChangeHandlers: [(_ oldState: LanguageServerState, _ newState: LanguageServerState) -> Void] = []
  
  /// A callback with which `SwiftLanguageServer` can request its owner to reopen all documents in case it has crashed.
  private let reopenDocuments: (ToolchainLanguageServer) -> Void

  /// Creates a language server for the given client using the sourcekitd dylib specified in `toolchain`.
  /// `reopenDocuments` is a closure that will be called if sourcekitd crashes and the `SwiftLanguageServer` asks its parent server to reopen all of its documents.
  /// Returns `nil` if `sourcektid` couldn't be found.
  public init?(
    client: LocalConnection,
    toolchain: Toolchain,
    clientCapabilities: ClientCapabilities?,
    options: SourceKitServer.Options,
    workspace: Workspace,
    reopenDocuments: @escaping (ToolchainLanguageServer) -> Void
  ) throws {
    guard let sourcekitd = toolchain.sourcekitd else { return nil }
    self.client = client
    self.sourcekitd = try SourceKitDImpl.getOrCreate(dylibPath: sourcekitd)
    self.clientCapabilities = clientCapabilities ?? ClientCapabilities(workspace: nil, textDocument: nil)
    self.serverOptions = options
    self.documentManager = DocumentManager()
    self.state = .connected
    self.reopenDocuments = reopenDocuments
  }

  public func canHandle(workspace: Workspace) -> Bool {
    // We have a single sourcekitd instance for all workspaces.
    return true
  }

  public func addStateChangeHandler(handler: @escaping (_ oldState: LanguageServerState, _ newState: LanguageServerState) -> Void) {
    queue.async {
      self.stateChangeHandlers.append(handler)
    }
  }

  /// Updates the lexical tokens for the given `snapshot`.
  /// Must be called on `self.queue`.
  private func updateSyntacticTokens(
    for snapshot: DocumentSnapshot
  ) {
    dispatchPrecondition(condition: .onQueue(queue))

    let uri = snapshot.document.uri
    let docTokens = updateSyntaxTree(for: snapshot)

    do {
      try documentManager.updateTokens(uri, tokens: docTokens)
    } catch {
      log("Updating lexical and syntactic tokens failed: \(error)", level: .warning)
    }
  }

  /// Returns the updated lexical tokens for the given `snapshot`.
  private func updateSyntaxTree(
    for snapshot: DocumentSnapshot
  ) -> DocumentTokens {
    logExecutionTime(level: .debug) {
      var docTokens = snapshot.tokens

      docTokens.syntaxTree = Parser.parse(source: snapshot.text)

      return docTokens
    }
  }

  /// Updates the semantic tokens for the given `snapshot`.
  /// Must be called on `self.queue`.
  private func updateSemanticTokens(
    response: SKDResponseDictionary,
    for snapshot: DocumentSnapshot
  ) {
    dispatchPrecondition(condition: .onQueue(queue))

    let uri = snapshot.document.uri
    let docTokens = updatedSemanticTokens(response: response, for: snapshot)

    do {
      try documentManager.updateTokens(uri, tokens: docTokens)
    } catch {
      log("Updating semantic tokens failed: \(error)", level: .warning)
    }
  }

  /// Returns the updated semantic tokens for the given `snapshot`.
  private func updatedSemanticTokens(
    response: SKDResponseDictionary,
    for snapshot: DocumentSnapshot
  ) -> DocumentTokens {
    logExecutionTime(level: .debug) {
      var docTokens = snapshot.tokens

      if let skTokens: SKDResponseArray = response[keys.annotations] {
        let tokenParser = SyntaxHighlightingTokenParser(sourcekitd: sourcekitd)
        var tokens: [SyntaxHighlightingToken] = []
        tokenParser.parseTokens(skTokens, in: snapshot, into: &tokens)

        docTokens.semantic = tokens
      }

      return docTokens
    }
  }

  /// Inform the client about changes to the syntax highlighting tokens.
  private func requestTokensRefresh() {
    if clientCapabilities.workspace?.semanticTokens?.refreshSupport ?? false {
      _ = client.send(WorkspaceSemanticTokensRefreshRequest(), queue: queue) { result in
        if let error = result.failure {
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

  /// Publish diagnostics for the given `snapshot`. We withhold semantic diagnostics if we are using
  /// fallback arguments.
  ///
  /// Should be called on self.queue.
  func publishDiagnostics(
    response: SKDResponseDictionary,
    for snapshot: DocumentSnapshot,
    compileCommand: SwiftCompileCommand?
  ) {
    let documentUri = snapshot.document.uri
    guard diagnosticsEnabled(for: documentUri) else {
      log("Ignoring diagnostics for blacklisted file \(documentUri.pseudoPath)", level: .debug)
      return
    }

    let isFallback = compileCommand?.isFallback ?? true

    let stageUID: sourcekitd_uid_t? = response[sourcekitd.keys.diagnostic_stage]
    let stage = stageUID.flatMap { DiagnosticStage($0, sourcekitd: sourcekitd) } ?? .sema

    let supportsCodeDescription =
           (clientCapabilities.textDocument?.publishDiagnostics?.codeDescriptionSupport == true)

    // Note: we make the notification even if there are no diagnostics to clear the current state.
    var newDiags: [CachedDiagnostic] = []
    response[keys.diagnostics]?.forEach { _, diag in
      if let diag = CachedDiagnostic(diag,
                                     in: snapshot,
                                     useEducationalNoteAsCode: supportsCodeDescription) {
        newDiags.append(diag)
      }
      return true
    }

    let result = mergeDiagnostics(
      old: currentDiagnostics[documentUri] ?? [],
      new: newDiags, stage: stage, isFallback: isFallback)
    currentDiagnostics[documentUri] = result

    client.send(PublishDiagnosticsNotification(
        uri: documentUri, version: snapshot.version, diagnostics: result.map { $0.diagnostic }))
  }

  /// Should be called on self.queue.
  func handleDocumentUpdate(uri: DocumentURI) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard let snapshot = documentManager.latestSnapshot(uri) else {
      return
    }
    let compileCommand = self.commandsByFile[uri]

    // Make the magic 0,0 replacetext request to update diagnostics and semantic tokens.

    let req = SKDRequestDictionary(sourcekitd: sourcekitd)
    req[keys.request] = requests.editor_replacetext
    req[keys.name] = uri.pseudoPath
    req[keys.offset] = 0
    req[keys.length] = 0
    req[keys.sourcetext] = ""

    if let dict = try? self.sourcekitd.sendSync(req) {
      publishDiagnostics(response: dict, for: snapshot, compileCommand: compileCommand)
      if dict[keys.diagnostic_stage] as sourcekitd_uid_t? == sourcekitd.values.diag_stage_sema {
        // Only update semantic tokens if the 0,0 replacetext request returned semantic information.
        updateSemanticTokens(response: dict, for: snapshot)
        requestTokensRefresh()
      }
    }
  }
}

extension SwiftLanguageServer {

  public func initializeSync(_ initialize: InitializeRequest) throws -> InitializeResult {
    sourcekitd.addNotificationHandler(self)

    return InitializeResult(capabilities: ServerCapabilities(
      textDocumentSync: TextDocumentSyncOptions(
        openClose: true,
        change: .incremental,
        willSave: true,
        willSaveWaitUntil: false,
        save: .value(TextDocumentSyncOptions.SaveOptions(includeText: false))),
      hoverProvider: true,
      completionProvider: CompletionOptions(
        resolveProvider: true,
        triggerCharacters: [".", "("]),
      definitionProvider: nil,
      implementationProvider: .bool(true),
      referencesProvider: nil,
      documentHighlightProvider: true,
      documentSymbolProvider: true,
      codeActionProvider: .value(CodeActionServerCapabilities(
        clientCapabilities: initialize.capabilities.textDocument?.codeAction,
        codeActionOptions: CodeActionOptions(codeActionKinds: [.quickFix, .refactor]),
        supportsCodeActions: true)),
      colorProvider: .bool(true),
      foldingRangeProvider: .bool(true),
      executeCommandProvider: ExecuteCommandOptions(
        commands: builtinSwiftCommands),
      semanticTokensProvider: SemanticTokensOptions(
        legend: SemanticTokensLegend(
          tokenTypes: SyntaxHighlightingToken.Kind.allCases.map(\.lspName),
          tokenModifiers: SyntaxHighlightingToken.Modifiers.allModifiers.map { $0.lspName! }),
        range: .bool(true),
        full: .bool(true)),
      inlayHintProvider: InlayHintOptions(
        resolveProvider: false)
    ))
  }

  public func clientInitialized(_: InitializedNotification) {
    // Nothing to do.
  }

  public func shutdown(callback: @escaping () -> Void) {
    queue.async {
      if let session = self.currentCompletionSession {
        session.close()
        self.currentCompletionSession = nil
      }
      self.sourcekitd.removeNotificationHandler(self)
      self.client.close()
      callback()
    }
  }

  /// Tell sourcekitd to crash itself. For testing purposes only.
  public func _crash() {
    let req = SKDRequestDictionary(sourcekitd: sourcekitd)
    req[sourcekitd.keys.request] = sourcekitd.requests.crash_exit
    _ = try? sourcekitd.sendSync(req)
  }
  
  // MARK: - Build System Integration

  /// Should be called on self.queue.
  private func reopenDocument(_ snapshot: DocumentSnapshot, _ compileCmd: SwiftCompileCommand?) {
    let keys = self.keys
    let uri = snapshot.document.uri
    let path = uri.pseudoPath

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
    self.publishDiagnostics(
        response: dict, for: snapshot, compileCommand: compileCmd)
    self.updateSyntacticTokens(for: snapshot)
  }

  public func documentUpdatedBuildSettings(_ uri: DocumentURI, change: FileBuildSettingsChange) {
    self.queue.async {
      let compileCommand = SwiftCompileCommand(change: change)
      // Confirm that the compile commands actually changed, otherwise we don't need to do anything.
      // This includes when the compiler arguments are the same but the command is no longer
      // considered to be fallback.
      guard self.commandsByFile[uri] != compileCommand else {
        return
      }
      self.commandsByFile[uri] = compileCommand

      // We may not have a snapshot if this is called just before `openDocument`.
      guard let snapshot = self.documentManager.latestSnapshot(uri) else {
        return
      }

      // Close and re-open the document internally to inform sourcekitd to update the compile
      // command. At the moment there's no better way to do this.
      self.reopenDocument(snapshot, compileCommand)
    }
  }

  public func documentDependenciesUpdated(_ uri: DocumentURI) {
    self.queue.async {
      guard let snapshot = self.documentManager.latestSnapshot(uri) else {
        return
      }

      // Forcefully reopen the document since the `BuildSystem` has informed us
      // that the dependencies have changed and the AST needs to be reloaded.
      self.reopenDocument(snapshot, self.commandsByFile[uri])
    }
  }

  // MARK: - Text synchronization

  public func openDocument(_ note: DidOpenTextDocumentNotification) {
    let keys = self.keys

    self.queue.async {
      guard let snapshot = self.documentManager.open(note) else {
        // Already logged failure.
        return
      }

      let uri = snapshot.document.uri
      let req = SKDRequestDictionary(sourcekitd: self.sourcekitd)
      req[keys.request] = self.requests.editor_open
      req[keys.name] = note.textDocument.uri.pseudoPath
      req[keys.sourcetext] = snapshot.text

      let compileCommand = self.commandsByFile[uri]

      if let compilerArgs = compileCommand?.compilerArgs {
        req[keys.compilerargs] = compilerArgs
      }

      guard let dict = try? self.sourcekitd.sendSync(req) else {
        // Already logged failure.
        return
      }
      self.publishDiagnostics(response: dict, for: snapshot, compileCommand: compileCommand)
      self.updateSyntacticTokens(for: snapshot)
    }
  }

  public func closeDocument(_ note: DidCloseTextDocumentNotification) {
    let keys = self.keys

    self.queue.async {
      self.documentManager.close(note)

      let uri = note.textDocument.uri

      let req = SKDRequestDictionary(sourcekitd: self.sourcekitd)
      req[keys.request] = self.requests.editor_close
      req[keys.name] = uri.pseudoPath

      // Clear settings that should not be cached for closed documents.
      self.commandsByFile[uri] = nil
      self.currentDiagnostics[uri] = nil

      _ = try? self.sourcekitd.sendSync(req)
    }
  }

  public func changeDocument(_ note: DidChangeTextDocumentNotification) {
    let keys = self.keys

    self.queue.async {
      var lastResponse: SKDResponseDictionary? = nil

      let snapshot = self.documentManager.edit(note) { (before: DocumentSnapshot, edit: TextDocumentContentChangeEvent) in
        let req = SKDRequestDictionary(sourcekitd: self.sourcekitd)
        req[keys.request] = self.requests.editor_replacetext
        req[keys.name] = note.textDocument.uri.pseudoPath

        if let range = edit.range {
          guard let offset = before.utf8Offset(of: range.lowerBound), let end = before.utf8Offset(of: range.upperBound) else {
            fatalError("invalid edit \(range)")
          }

          req[keys.offset] = offset
          req[keys.length] = end - offset

        } else {
          // Full text
          req[keys.offset] = 0
          req[keys.length] = before.text.utf8.count
        }

        req[keys.sourcetext] = edit.text
        lastResponse = try? self.sourcekitd.sendSync(req)

        self.adjustDiagnosticRanges(of: note.textDocument.uri, for: edit)
      } updateDocumentTokens: { (after: DocumentSnapshot) in
        if lastResponse != nil {
          return self.updateSyntaxTree(for: after)
        } else {
          return DocumentTokens()
        }
      }

      if let dict = lastResponse, let snapshot = snapshot {
        let compileCommand = self.commandsByFile[note.textDocument.uri]
        self.publishDiagnostics(response: dict, for: snapshot, compileCommand: compileCommand)
      }
    }
  }

  public func willSaveDocument(_ note: WillSaveTextDocumentNotification) {

  }

  public func didSaveDocument(_ note: DidSaveTextDocumentNotification) {

  }

  // MARK: - Language features

  /// Returns true if the `ToolchainLanguageServer` will take ownership of the request.
  public func definition(_ request: Request<DefinitionRequest>) -> Bool {
    // We don't handle it.
    return false
  }

  public func declaration(_ request: Request<DeclarationRequest>) -> Bool {
    // We don't handle it.
    return false
  }

  public func completion(_ req: Request<CompletionRequest>) {
    queue.async {
      self._completion(req)
    }
  }
  
  public func completionResolve(_ req: Request<CompletionItem>) {
    queue.async {
      self._completionResolve(req)
    }
  }

  public func hover(_ req: Request<HoverRequest>) {
    let uri = req.params.textDocument.uri
    let position = req.params.position
    cursorInfo(uri, position..<position) { result in
      guard let cursorInfo: CursorInfo = result.success ?? nil else {
        if let error = result.failure, error != .responseError(.cancelled) {
          log("cursor info failed \(uri):\(position): \(error)", level: .warning)
        }
        return req.reply(nil)
      }

      guard let name: String = cursorInfo.symbolInfo.name else {
        // There is a cursor but we don't know how to deal with it.
        req.reply(nil)
        return
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

      req.reply(HoverResponse(contents: .markupContent(MarkupContent(kind: .markdown, value: result)), range: nil))
    }
  }

  public func symbolInfo(_ req: Request<SymbolInfoRequest>) {
    let uri = req.params.textDocument.uri
    let position = req.params.position
    cursorInfo(uri, position..<position) { result in
      guard let cursorInfo: CursorInfo = result.success ?? nil else {
        if let error = result.failure {
          log("cursor info failed \(uri):\(position): \(error)", level: .warning)
        }
        return req.reply([])
      }

      req.reply([cursorInfo.symbolInfo])
    }
  }

  // Must be called on self.queue
  private func _documentSymbols(
    _ uri: DocumentURI,
    _ completion: @escaping (Result<[DocumentSymbol], ResponseError>) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(queue))

    guard let snapshot = self.documentManager.latestSnapshot(uri) else {
      let msg = "failed to find snapshot for url \(uri)"
      log(msg)
      return completion(.failure(.unknown(msg)))
    }

    let helperDocumentName = "DocumentSymbols:" + snapshot.document.uri.pseudoPath
    let skreq = SKDRequestDictionary(sourcekitd: self.sourcekitd)
    skreq[keys.request] = self.requests.editor_open
    skreq[keys.name] = helperDocumentName
    skreq[keys.sourcetext] = snapshot.text
    skreq[keys.syntactic_only] = 1

    let handle = self.sourcekitd.send(skreq, self.queue) { [weak self] result in
      guard let self = self else { return }

      defer {
        let closeHelperReq = SKDRequestDictionary(sourcekitd: self.sourcekitd)
        closeHelperReq[self.keys.request] = self.requests.editor_close
        closeHelperReq[self.keys.name] = helperDocumentName
        _ = self.sourcekitd.send(closeHelperReq, .global(qos: .utility), reply: { _ in })
      }

      guard let dict = result.success else {
        return completion(.failure(ResponseError(result.failure!)))
      }
      guard let results: SKDResponseArray = dict[self.keys.substructure] else {
        return completion(.success([]))
      }

      func documentSymbol(value: SKDResponseDictionary) -> DocumentSymbol? {
        guard let name: String = value[self.keys.name],
              let uid: sourcekitd_uid_t = value[self.keys.kind],
              let kind: SymbolKind = uid.asSymbolKind(self.values),
              let offset: Int = value[self.keys.offset],
              let start: Position = snapshot.positionOf(utf8Offset: offset),
              let length: Int = value[self.keys.length],
              let end: Position = snapshot.positionOf(utf8Offset: offset + length) else {
          return nil
        }

        let range = start..<end
        let selectionRange: Range<Position>
        if let nameOffset: Int = value[self.keys.nameoffset],
            let nameStart: Position = snapshot.positionOf(utf8Offset: nameOffset),
            let nameLength: Int = value[self.keys.namelength],
            let nameEnd: Position = snapshot.positionOf(utf8Offset: nameOffset + nameLength) {
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
        return DocumentSymbol(name: name,
                              detail: value[self.keys.typename] as String?,
                              kind: kind,
                              deprecated: nil,
                              range: range,
                              selectionRange: selectionRange,
                              children: children)
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

      completion(.success(documentSymbols(array: results)))
    }

    // FIXME: cancellation
    _ = handle
  }

  public func documentSymbols(
    _ uri: DocumentURI,
    _ completion: @escaping (Result<[DocumentSymbol], ResponseError>) -> Void
  ) {
    queue.async {
      self._documentSymbols(uri, completion)
    }
  }

  public func documentSymbol(_ req: Request<DocumentSymbolRequest>) {
    documentSymbols(req.params.textDocument.uri) { result in
      req.reply(result.map { .documentSymbols($0) })
    }
  }

  public func documentColor(_ req: Request<DocumentColorRequest>) {
    let keys = self.keys

    queue.async {
      guard let snapshot = self.documentManager.latestSnapshot(req.params.textDocument.uri) else {
        log("failed to find snapshot for url \(req.params.textDocument.uri)")
        req.reply([])
        return
      }

      let helperDocumentName = "DocumentColor:" + snapshot.document.uri.pseudoPath
      let skreq = SKDRequestDictionary(sourcekitd: self.sourcekitd)
      skreq[keys.request] = self.requests.editor_open
      skreq[keys.name] = helperDocumentName
      skreq[keys.sourcetext] = snapshot.text
      skreq[keys.syntactic_only] = 1

      let handle = self.sourcekitd.send(skreq, self.queue) { [weak self] result in
        guard let self = self else { return }

        defer {
          let closeHelperReq = SKDRequestDictionary(sourcekitd: self.sourcekitd)
          closeHelperReq[keys.request] = self.requests.editor_close
          closeHelperReq[keys.name] = helperDocumentName
          _ = self.sourcekitd.send(closeHelperReq, .global(qos: .utility), reply: { _ in })
        }

        guard let dict = result.success else {
          req.reply(.failure(ResponseError(result.failure!)))
          return
        }

        guard let results: SKDResponseArray = dict[self.keys.substructure] else {
          return req.reply([])
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
                let substructure: SKDResponseArray = dict[self.keys.substructure] else {
            return nil
          }
          var red, green, blue, alpha: Double?
          substructure.forEach{ (i: Int, value: SKDResponseDictionary) in
            guard let name: String = value[self.keys.name],
                  let bodyoffset: Int = value[self.keys.bodyoffset],
                  let bodylength: Int = value[self.keys.bodylength] else {
              return true
            }
            let view = snapshot.text.utf8
            let bodyStart = view.index(view.startIndex, offsetBy: bodyoffset)
            let bodyEnd = view.index(view.startIndex, offsetBy: bodyoffset+bodylength)
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
             let alpha = alpha {
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

        req.reply(colorInformation(array: results))
      }
      // FIXME: cancellation
      _ = handle
    }
  }

  public func documentSemanticTokens(_ req: Request<DocumentSemanticTokensRequest>) {
    let uri = req.params.textDocument.uri

    queue.async {
      guard let snapshot = self.documentManager.latestSnapshot(uri) else {
        log("failed to find snapshot for uri \(uri)")
        req.reply(DocumentSemanticTokensResponse(data: []))
        return
      }

      let tokens = snapshot.mergedAndSortedTokens()
      let encodedTokens = tokens.lspEncoded

      req.reply(DocumentSemanticTokensResponse(data: encodedTokens))
    }
  }

  public func documentSemanticTokensDelta(_ req: Request<DocumentSemanticTokensDeltaRequest>) {
    // FIXME: implement semantic tokens delta support.
    req.reply(nil)
  }

  public func documentSemanticTokensRange(_ req: Request<DocumentSemanticTokensRangeRequest>) {
    let uri = req.params.textDocument.uri
    let range = req.params.range

    queue.async {
      guard let snapshot = self.documentManager.latestSnapshot(uri) else {
        log("failed to find snapshot for uri \(uri)")
        req.reply(DocumentSemanticTokensResponse(data: []))
        return
      }

      let tokens = snapshot.mergedAndSortedTokens(in: range)
      let encodedTokens = tokens.lspEncoded

      req.reply(DocumentSemanticTokensResponse(data: encodedTokens))
    }
  }

  public func colorPresentation(_ req: Request<ColorPresentationRequest>) {
    let color = req.params.color
    // Empty string as a label breaks VSCode color picker
    let label = "Color Literal"
    let newText = "#colorLiteral(red: \(color.red), green: \(color.green), blue: \(color.blue), alpha: \(color.alpha))"
    let textEdit = TextEdit(range: req.params.range, newText: newText)
    let presentation = ColorPresentation(label: label, textEdit: textEdit, additionalTextEdits: nil)
    req.reply([presentation])
  }

  public func documentSymbolHighlight(_ req: Request<DocumentHighlightRequest>) {
    let keys = self.keys

    queue.async {
      guard let snapshot = self.documentManager.latestSnapshot(req.params.textDocument.uri) else {
        log("failed to find snapshot for url \(req.params.textDocument.uri)")
        req.reply(nil)
        return
      }

      guard let offset = snapshot.utf8Offset(of: req.params.position) else {
        log("invalid position \(req.params.position)")
        req.reply(nil)
        return
      }

      let skreq = SKDRequestDictionary(sourcekitd: self.sourcekitd)
      skreq[keys.request] = self.requests.relatedidents
      skreq[keys.offset] = offset
      skreq[keys.sourcefile] = snapshot.document.uri.pseudoPath

      // FIXME: SourceKit should probably cache this for us.
      if let compileCommand = self.commandsByFile[snapshot.document.uri] {
        skreq[keys.compilerargs] = compileCommand.compilerArgs
      }

      let handle = self.sourcekitd.send(skreq, self.queue) { [weak self] result in
        guard let self = self else { return }
        guard let dict = result.success else {
          req.reply(.failure(ResponseError(result.failure!)))
          return
        }

        guard let results: SKDResponseArray = dict[self.keys.results] else {
          return req.reply([])
        }

        var highlights: [DocumentHighlight] = []

        results.forEach { _, value in
          if let offset: Int = value[self.keys.offset],
             let start: Position = snapshot.positionOf(utf8Offset: offset),
             let length: Int = value[self.keys.length],
             let end: Position = snapshot.positionOf(utf8Offset: offset + length)
          {
            highlights.append(DocumentHighlight(
              range: start..<end,
              kind: .read // unknown
            ))
          }
          return true
        }

        req.reply(highlights)
      }

      // FIXME: cancellation
      _ = handle
    }
  }

  public func foldingRange(_ req: Request<FoldingRangeRequest>) {
    queue.async {
      guard let snapshot = self.documentManager.latestSnapshot(req.params.textDocument.uri) else {
        log("failed to find snapshot for url \(req.params.textDocument.uri)")
        req.reply(nil)
        return
      }

      guard let sourceFile = snapshot.tokens.syntaxTree else {
        log("no lexical structure available for url \(req.params.textDocument.uri)")
        req.reply(nil)
        return
      }

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
          var start = node.position.utf8Offset
          var lineCommentStart: Int? = nil
          func flushLineComment(_ offset: Int = 0) {
            if let lineCommentStart = lineCommentStart {
              _ = self.addFoldingRange(
                start: lineCommentStart,
                end: start + offset,
                kind: .comment)
            }
            lineCommentStart = nil
          }

          for piece in node.leadingTrivia {
            defer { start += piece.sourceLength.utf8Length }
            switch piece {
            case .blockComment(_):
              flushLineComment()
              _ = self.addFoldingRange(
                start: start,
                end: start + piece.sourceLength.utf8Length,
                kind: .comment)
            case .docBlockComment(_):
              flushLineComment()
              _ = self.addFoldingRange(
                start: start,
                end: start + piece.sourceLength.utf8Length,
                kind: .comment)
            case .lineComment(_), .docLineComment(_):
              if lineCommentStart == nil {
                lineCommentStart = start
              }
            case .newlines(1), .carriageReturns(1), .spaces(_), .tabs(_):
              if lineCommentStart != nil {
                continue
              } else {
                flushLineComment()
              }
            default:
              flushLineComment()
              continue
            }
          }

          flushLineComment()
        }

        override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind {
          return self.addFoldingRange(
            start: node.statements.position.utf8Offset,
            end: node.rightBrace.positionAfterSkippingLeadingTrivia.utf8Offset)
        }

        override func visit(_ node: MemberDeclBlockSyntax) -> SyntaxVisitorContinueKind {
          return self.addFoldingRange(
            start: node.members.position.utf8Offset,
            end: node.rightBrace.positionAfterSkippingLeadingTrivia.utf8Offset)
        }

        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
          return self.addFoldingRange(
            start: node.statements.position.utf8Offset,
            end: node.rightBrace.positionAfterSkippingLeadingTrivia.utf8Offset)
        }

        override func visit(_ node: AccessorBlockSyntax) -> SyntaxVisitorContinueKind {
          return self.addFoldingRange(
            start: node.accessors.position.utf8Offset,
            end: node.rightBrace.positionAfterSkippingLeadingTrivia.utf8Offset)
        }

        override func visit(_ node: SwitchStmtSyntax) -> SyntaxVisitorContinueKind {
          return self.addFoldingRange(
            start: node.cases.position.utf8Offset,
            end: node.rightBrace.positionAfterSkippingLeadingTrivia.utf8Offset)
        }

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
          return self.addFoldingRange(
            start: node.argumentList.position.utf8Offset,
            end: node.argumentList.endPosition.utf8Offset)
        }

        override func visit(_ node: SubscriptExprSyntax) -> SyntaxVisitorContinueKind {
          return self.addFoldingRange(
            start: node.argumentList.position.utf8Offset,
            end: node.argumentList.endPosition.utf8Offset)
        }

        __consuming func finalize() -> Set<FoldingRange> {
          return self.ranges
        }

        private func addFoldingRange(start: Int, end: Int, kind: FoldingRangeKind? = nil) -> SyntaxVisitorContinueKind {
          if let limit = self.rangeLimit, self.ranges.count >= limit {
            return .skipChildren
          }

          guard let start: Position = snapshot.positionOf(utf8Offset: start),
                let end: Position = snapshot.positionOf(utf8Offset: end) else {
            log("folding range failed to retrieve position of \(snapshot.document.uri): \(start)-\(end)", level: .warning)
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
            range = FoldingRange(startLine: start.line,
                                 startUTF16Index: nil,
                                 endLine: end.line,
                                 endUTF16Index: nil,
                                 kind: kind)
          } else {
            range = FoldingRange(startLine: start.line,
                                 startUTF16Index: start.utf16index,
                                 endLine: end.line,
                                 endUTF16Index: end.utf16index,
                                 kind: kind)
          }
          ranges.insert(range)
          return .visitChildren
        }
      }

      let capabilities = self.clientCapabilities.textDocument?.foldingRange
      // If the limit is less than one, do nothing.
      if let limit = capabilities?.rangeLimit, limit <= 0 {
        req.reply([])
        return
      }

      let rangeFinder = FoldingRangeFinder(
        snapshot: snapshot,
        rangeLimit: capabilities?.rangeLimit,
        lineFoldingOnly: capabilities?.lineFoldingOnly ?? false)
      rangeFinder.walk(sourceFile)
      let ranges = rangeFinder.finalize()

      req.reply(ranges.sorted())
    }
  }

  public func codeAction(_ req: Request<CodeActionRequest>) {
    let providersAndKinds: [(provider: CodeActionProvider, kind: CodeActionKind)] = [
      (retrieveRefactorCodeActions, .refactor),
      (retrieveQuickFixCodeActions, .quickFix)
    ]
    let wantedActionKinds = req.params.context.only
    let providers = providersAndKinds.filter { wantedActionKinds?.contains($0.1) != false }
    retrieveCodeActions(req, providers: providers.map { $0.provider }) { result in
      switch result {
      case .success(let codeActions):
        let capabilities = self.clientCapabilities.textDocument?.codeAction
        let response = CodeActionRequestResponse(codeActions: codeActions,
                                                 clientCapabilities: capabilities)
        req.reply(response)
      case .failure(let error):
        req.reply(.failure(error))
      }
    }
  }

  func retrieveCodeActions(_ req: Request<CodeActionRequest>, providers: [CodeActionProvider], completion: @escaping CodeActionProviderCompletion) {
    guard providers.isEmpty == false else {
      completion(.success([]))
      return
    }
    var codeActions = [CodeAction]()
    let dispatchGroup = DispatchGroup()
    (0..<providers.count).forEach { _ in dispatchGroup.enter() }
    dispatchGroup.notify(queue: queue) {
      completion(.success(codeActions))
    }
    for i in 0..<providers.count {
      self.queue.async {
        providers[i](req.params) { result in
          defer { dispatchGroup.leave() }
          guard case .success(let actions) = result else {
            return
          }
          codeActions += actions
        }
      }
    }
  }

  func retrieveRefactorCodeActions(_ params: CodeActionRequest, completion: @escaping CodeActionProviderCompletion) {
    let additionalCursorInfoParameters: ((SKDRequestDictionary) -> Void) = { skreq in
      skreq[self.keys.retrieve_refactor_actions] = 1
    }

    _cursorInfo(
      params.textDocument.uri,
      params.range,
      additionalParameters: additionalCursorInfoParameters)
    { result in
      guard let dict: CursorInfo = result.success ?? nil else {
        if let failure = result.failure {
          let message = "failed to find refactor actions: \(failure)"
          log(message)
          completion(.failure(.unknown(message)))
        } else {
          completion(.failure(.unknown("CursorInfo failed.")))
        }
        return
      }
      guard let refactorActions = dict.refactorActions else {
        completion(.success([]))
        return
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
      completion(.success(codeActions))
    }
  }

  func retrieveQuickFixCodeActions(_ params: CodeActionRequest, completion: @escaping CodeActionProviderCompletion) {
    guard let cachedDiags = currentDiagnostics[params.textDocument.uri] else {
      completion(.success([]))
      return
    }

    let codeActions = cachedDiags.flatMap { (cachedDiag) -> [CodeAction] in
      let diag = cachedDiag.diagnostic

      let codeActions: [CodeAction] =
        (diag.codeActions ?? []) +
        (diag.relatedInformation?.flatMap{ $0.codeActions ?? [] } ?? [])

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
      guard params.context.diagnostics.contains(where: { (contextDiag) -> Bool in
        return contextDiag.range == diag.range &&
          contextDiag.severity == diag.severity &&
          contextDiag.code == diag.code &&
          contextDiag.source == diag.source &&
          contextDiag.message == diag.message
      }) else {
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

    completion(.success(codeActions))
  }

  public func inlayHint(_ req: Request<InlayHintRequest>) {
    guard req.params.only?.contains(.type) ?? true else {
      req.reply([])
      return
    }

    let uri = req.params.textDocument.uri
    variableTypeInfos(uri, req.params.range) { infosResult in
      do {
        let infos = try infosResult.get()
        let hints = infos
          .lazy
          .filter { !$0.hasExplicitType }
          .map { info -> InlayHint in
            let position = info.range.upperBound
            let label = ": \(info.printedType)"
            return InlayHint(
              position: position,
              kind: .type,
              label: .string(label),
              textEdits: [
                TextEdit(range: position..<position, newText: label)
              ]
            )
          }

        req.reply(.success(Array(hints)))
      } catch {
        let message = "variable types for inlay hints failed for \(uri): \(error)"
        log(message, level: .warning)
        req.reply(.failure(.unknown(message)))
      }
    }
  }

  public func executeCommand(_ req: Request<ExecuteCommandRequest>) {
    let params = req.params
    //TODO: If there's support for several types of commands, we might need to structure this similarly to the code actions request.
    guard let swiftCommand = params.swiftCommand(ofType: SemanticRefactorCommand.self) else {
      let message = "semantic refactoring: unknown command \(params.command)"
      log(message, level: .warning)
      return req.reply(.failure(.unknown(message)))
    }
    let uri = swiftCommand.textDocument.uri
    semanticRefactoring(swiftCommand) { result in
      switch result {
      case .success(let refactor):
        let edit = refactor.edit
        self.applyEdit(label: refactor.title, edit: edit) { editResult in
          switch editResult {
          case .success:
            req.reply(edit.encodeToLSPAny())
          case .failure(let error):
            req.reply(.failure(error))
          }
        }
      case .failure(let error):
        let message = "semantic refactoring failed \(uri): \(error)"
        log(message, level: .warning)
        return req.reply(.failure(.unknown(message)))
      }
    }
  }

  func applyEdit(label: String, edit: WorkspaceEdit, completion: @escaping (LSPResult<ApplyEditResponse>) -> Void) {
    let req = ApplyEditRequest(label: label, edit: edit)
    let handle = client.send(req, queue: queue) { reply in
      switch reply {
      case .success(let response) where response.applied == false:
        let reason: String
        if let failureReason = response.failureReason {
          reason = " reason: \(failureReason)"
        } else {
          reason = ""
        }
        log("client refused to apply edit for \(label)!\(reason)", level: .warning)
      case .failure(let error):
        log("applyEdit failed: \(error)", level: .warning)
      default:
        break
      }
      completion(reply)
    }

    // FIXME: cancellation
    _ = handle
  }
}

extension SwiftLanguageServer: SKDNotificationHandler {
  public func notification(_ notification: SKDResponse) {
    // Check if we need to update our `state` based on the contents of the notification.
    // Execute the entire code block on `queue` because we need to switch to `queue` anyway to
    // check `state` in the second `if`. Moving `queue.async` up ensures we only need to switch
    // queues once and makes the code inside easier to read.
    self.queue.async {
      if notification.value?[self.keys.notification] == self.values.notification_sema_enabled {
        self.state = .connected
      }

      if self.state == .connectionInterrupted {
        // If we get a notification while we are restoring the connection, it means that the server has restarted.
        // We still need to wait for semantic functionality to come back up.
        self.state = .semanticFunctionalityDisabled

        // Ask our parent to re-open all of our documents.
        self.reopenDocuments(self)
      }

      if case .connectionInterrupted = notification.error {
        self.state = .connectionInterrupted

        // We don't have any open documents anymore after sourcekitd crashed.
        // Reset the document manager to reflect that.
        self.documentManager = DocumentManager()
      }
    }
    
    guard let dict = notification.value else {
      log(notification.description, level: .error)
      return
    }

    logAsync(level: .debug) { _ in notification.description }

    if let kind: sourcekitd_uid_t = dict[self.keys.notification],
       kind == self.values.notification_documentupdate,
       let name: String = dict[self.keys.name] {

      self.queue.async {
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
        self.handleDocumentUpdate(uri: uri)
      }
    }
  }
}

extension DocumentSnapshot {

  func utf8Offset(of pos: Position) -> Int? {
    return lineTable.utf8OffsetOf(line: pos.line, utf16Column: pos.utf16index)
  }

  func utf8OffsetRange(of range: Range<Position>) -> Range<Int>? {
    guard let startOffset = utf8Offset(of: range.lowerBound),
          let endOffset = utf8Offset(of: range.upperBound) else
    {
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
        return .typeParameter // FIXME: is there a better choice?
      case vals.decl_generic_type_param:
        return .typeParameter
      case vals.decl_function_constructor:
        return .constructor
      case vals.decl_function_destructor:
        return .value // FIXME: is there a better choice?
      case vals.decl_function_subscript:
        return .method // FIXME: is there a better choice?
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
      default:
        return nil
    }
  }
}
