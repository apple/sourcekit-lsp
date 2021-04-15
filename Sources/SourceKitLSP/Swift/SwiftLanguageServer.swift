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
import TSCBasic
import SwiftFormat
import SwiftFormatConfiguration

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
      if #available(OSX 10.12, *) {
        // `state` must only be set from `queue`.
        dispatchPrecondition(condition: .onQueue(queue))
      }
      for handler in stateChangeHandlers {
        handler(oldValue, state)
      }
    }
  }
  
  private var stateChangeHandlers: [(_ oldState: LanguageServerState, _ newState: LanguageServerState) -> Void] = []
  
  /// A callback with which `SwiftLanguageServer` can request its owner to reopen all documents in case it has crashed.
  private let reopenDocuments: (ToolchainLanguageServer) -> Void

  /// Creates a language server for the given client using the sourcekitd dylib at the specified
  /// path.
  /// `reopenDocuments` is a closure that will be called if sourcekitd crashes and the
  /// `SwiftLanguageServer` asks its parent server to reopen all of its documents.
  public init(
    client: LocalConnection,
    sourcekitd: AbsolutePath,
    clientCapabilities: ClientCapabilities,
    serverOptions: SourceKitServer.Options,
    reopenDocuments: @escaping (ToolchainLanguageServer) -> Void
  ) throws {
    self.client = client
    self.sourcekitd = try SourceKitDImpl.getOrCreate(dylibPath: sourcekitd)
    self.clientCapabilities = clientCapabilities
    self.serverOptions = serverOptions
    self.documentManager = DocumentManager()
    self.state = .connected
    self.reopenDocuments = reopenDocuments
  }

  public func addStateChangeHandler(handler: @escaping (_ oldState: LanguageServerState, _ newState: LanguageServerState) -> Void) {
    queue.async {
      self.stateChangeHandlers.append(handler)
    }
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
    guard let snapshot = documentManager.latestSnapshot(uri) else {
      return
    }
    let compileCommand = self.commandsByFile[uri]

    // Make the magic 0,0 replacetext request to update diagnostics.

    let req = SKDRequestDictionary(sourcekitd: sourcekitd)
    req[keys.request] = requests.editor_replacetext
    req[keys.name] = uri.pseudoPath
    req[keys.offset] = 0
    req[keys.length] = 0
    req[keys.sourcetext] = ""

    if let dict = try? self.sourcekitd.sendSync(req) {
      publishDiagnostics(response: dict, for: snapshot, compileCommand: compileCommand)
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
        resolveProvider: false,
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
      documentFormattingProvider: true,
      colorProvider: .bool(true),
      foldingRangeProvider: .bool(true),
      executeCommandProvider: ExecuteCommandOptions(
        commands: builtinSwiftCommands)
    ))
  }

  public func clientInitialized(_: InitializedNotification) {
    // Nothing to do.
  }

  public func shutdown() {
    queue.async {
      if let session = self.currentCompletionSession {
        session.close()
        self.currentCompletionSession = nil
      }
      self.sourcekitd.removeNotificationHandler(self)
      self.client.close()
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
    let path = snapshot.document.uri.pseudoPath

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

  public func completion(_ req: Request<CompletionRequest>) {
    queue.async {
      self._completion(req)
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

  public func documentSymbol(_ req: Request<DocumentSymbolRequest>) {
    let keys = self.keys

    queue.async {
      guard let snapshot = self.documentManager.latestSnapshot(req.params.textDocument.uri) else {
        log("failed to find snapshot for url \(req.params.textDocument.uri)")
        req.reply(nil)
        return
      }

      let skreq = SKDRequestDictionary(sourcekitd: self.sourcekitd)
      skreq[keys.request] = self.requests.editor_open
      skreq[keys.name] = "DocumentSymbols:" + snapshot.document.uri.pseudoPath
      skreq[keys.sourcetext] = snapshot.text
      skreq[keys.syntactic_only] = 1

      let handle = self.sourcekitd.send(skreq, self.queue) { [weak self] result in
        guard let self = self else { return }
        guard let dict = result.success else {
          req.reply(.failure(ResponseError(result.failure!)))
          return
        }
        guard let results: SKDResponseArray = dict[self.keys.substructure] else {
          return req.reply(.documentSymbols([]))
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

          let children: [DocumentSymbol]?
          if let substructure: SKDResponseArray = value[self.keys.substructure] {
            children = documentSymbols(array: substructure)
          } else {
            children = nil
          }
          return DocumentSymbol(name: name,
                                detail: nil,
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

        req.reply(.documentSymbols(documentSymbols(array: results)))
      }
      // FIXME: cancellation
      _ = handle
    }
  }

  public func documentFormatting(_ req: Request<DocumentFormattingRequest>) {
    self.queue.async {
      guard let file = req.params.textDocument.uri.fileURL else {
        req.reply(nil)
        return
      }
      guard let snapshot = self.documentManager.latestSnapshot(req.params.textDocument.uri) else {
        log("failed to find snapshot for url \(req.params.textDocument.uri)")
        req.reply(nil)
        return
      }
      let configuration: SwiftFormatConfiguration.Configuration
      // try to load swift-format configuration from a ".swift-format" file
      // if it fails, use values provided by the lsp
      if let configUrl = Configuration.url(forConfigurationFileApplyingTo: file),
         let config = try? Configuration(contentsOf: configUrl) {
          configuration = config
      } else {
        var config = SwiftFormatConfiguration.Configuration()
        let options = req.params.options
        config.indentation = options.insertSpaces ? .spaces(options.tabSize) : .tabs(1)
        config.tabWidth = options.tabSize
        configuration = config
      }

      let formatter = SwiftFormat.SwiftFormatter(configuration: configuration)
      do {
        guard let lastLine = snapshot.lineTable.last else {
          req.reply(nil)
          return
        }
        let lastPosition = Position(line: snapshot.lineTable.count-1, utf16index: lastLine.utf16.count)
        var edit = TextEdit(range: Position(line: 0, utf16index: 0)..<lastPosition, newText: "")
        try formatter.format(source: snapshot.text, assumingFileURL: file, to: &edit.newText)
        req.reply([edit])
      } catch {
        log("failed to format document: \(error)", level: .error)
        req.reply(nil)
      }
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

      let skreq = SKDRequestDictionary(sourcekitd: self.sourcekitd)
      skreq[keys.request] = self.requests.editor_open
      skreq[keys.name] = "DocumentColor:" + snapshot.document.uri.pseudoPath
      skreq[keys.sourcetext] = snapshot.text
      skreq[keys.syntactic_only] = 1

      let handle = self.sourcekitd.send(skreq, self.queue) { [weak self] result in
        guard let self = self else { return }
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
    // FIXME: implement semantic tokens support.
    req.reply(nil)
  }

  public func documentSemanticTokensDelta(_ req: Request<DocumentSemanticTokensDeltaRequest>) {
    // FIXME: implement semantic tokens support.
    req.reply(nil)
  }

  public func documentSemanticTokensRange(_ req: Request<DocumentSemanticTokensRangeRequest>) {
    // FIXME: implement semantic tokens support.
    req.reply(nil)
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
    let keys = self.keys

    queue.async {
      guard let snapshot = self.documentManager.latestSnapshot(req.params.textDocument.uri) else {
        log("failed to find snapshot for url \(req.params.textDocument.uri)")
        req.reply(nil)
        return
      }

      let skreq = SKDRequestDictionary(sourcekitd: self.sourcekitd)
      skreq[keys.request] = self.requests.editor_open
      skreq[keys.name] = "FoldingRanges:" + snapshot.document.uri.pseudoPath
      skreq[keys.sourcetext] = snapshot.text
      skreq[keys.syntactic_only] = 1

      let handle = self.sourcekitd.send(skreq, self.queue) { [weak self] result in
        guard let self = self else { return }
        guard let dict = result.success else {
          req.reply(.failure(ResponseError(result.failure!)))
          return
        }

        guard let syntaxMap: SKDResponseArray = dict[self.keys.syntaxmap],
              let substructure: SKDResponseArray = dict[self.keys.substructure] else {
          return req.reply([])
        }

        var ranges: [FoldingRange] = []

        var hasReachedLimit: Bool {
          let capabilities = self.clientCapabilities.textDocument?.foldingRange
          guard let rangeLimit = capabilities?.rangeLimit else {
            return false
          }
          return ranges.count >= rangeLimit
        }

        // If the limit is less than one, do nothing.
        guard hasReachedLimit == false else {
          req.reply([])
          return
        }

        // Merge successive comments into one big comment by adding their lengths.
        var currentComment: (offset: Int, length: Int)? = nil

        syntaxMap.forEach { _, value in
          if let kind: sourcekitd_uid_t = value[self.keys.kind],
             kind.isCommentKind(self.values),
             let offset: Int = value[self.keys.offset],
             let length: Int = value[self.keys.length]
          {
            if let comment = currentComment, comment.offset + comment.length == offset {
              currentComment!.length += length
              return true
            }
            if let comment = currentComment {
              self.addFoldingRange(offset: comment.offset, length: comment.length, kind: .comment, in: snapshot, toArray: &ranges)
            }
            currentComment = (offset: offset, length: length)
          }
          return hasReachedLimit == false
        }

        // Add the last stored comment.
        if let comment = currentComment, hasReachedLimit == false {
          self.addFoldingRange(offset: comment.offset, length: comment.length, kind: .comment, in: snapshot, toArray: &ranges)
          currentComment = nil
        }

        var structureStack: [SKDResponseArray] = [substructure]
        while !hasReachedLimit, let substructure = structureStack.popLast() {
          substructure.forEach { _, value in
            if let offset: Int = value[self.keys.bodyoffset],
               let length: Int = value[self.keys.bodylength],
               length > 0
            {
              self.addFoldingRange(offset: offset, length: length, in: snapshot, toArray: &ranges)
              if hasReachedLimit {
                return false
              }
            }
            if let substructure: SKDResponseArray = value[self.keys.substructure] {
              structureStack.append(substructure)
            }
            return true
          }
        }

        ranges.sort()
        req.reply(ranges)
      }

      // FIXME: cancellation
      _ = handle
    }
  }

  func addFoldingRange(offset: Int, length: Int, kind: FoldingRangeKind? = nil, in snapshot: DocumentSnapshot, toArray ranges: inout [FoldingRange]) {
    guard let start: Position = snapshot.positionOf(utf8Offset: offset),
          let end: Position = snapshot.positionOf(utf8Offset: offset + length) else {
      log("folding range failed to retrieve position of \(snapshot.document.uri): \(offset)-\(offset + length)", level: .warning)
      return
    }
    let capabilities = clientCapabilities.textDocument?.foldingRange
    let range: FoldingRange
    // If the client only supports folding full lines, ignore the end character's line.
    if capabilities?.lineFoldingOnly == true {
      let lastLineToFold = end.line - 1
      if lastLineToFold <= start.line {
        return
      } else {
        range = FoldingRange(startLine: start.line,
                             startUTF16Index: nil,
                             endLine: lastLineToFold,
                             endUTF16Index: nil,
                             kind: kind)
      }
    } else {
      range = FoldingRange(startLine: start.line,
                           startUTF16Index: start.utf16index,
                           endLine: end.line,
                           endUTF16Index: end.utf16index,
                           kind: kind)
    }
    ranges.append(range)
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
        if name.starts(with: "/") {
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

func makeLocalSwiftServer(
  client: MessageHandler,
  sourcekitd: AbsolutePath,
  clientCapabilities: ClientCapabilities?,
  options: SourceKitServer.Options,
  reopenDocuments: @escaping (ToolchainLanguageServer) -> Void
) throws -> ToolchainLanguageServer {
  let connectionToClient = LocalConnection()

  let server = try SwiftLanguageServer(
    client: connectionToClient,
    sourcekitd: sourcekitd,
    clientCapabilities: clientCapabilities ?? ClientCapabilities(workspace: nil, textDocument: nil),
    serverOptions: options,
    reopenDocuments: reopenDocuments)
  connectionToClient.start(handler: client)
  return server
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
