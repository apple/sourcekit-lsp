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

import BuildServerProtocol
import Dispatch
import Foundation
import IndexStoreDB
import LanguageServerProtocol
import LSPLogging
import SKCore
import SKSupport
import TSCBasic
import TSCLibc
import TSCUtility

public typealias URL = Foundation.URL

/// The SourceKit language server.
///
/// This is the client-facing language server implementation, providing indexing, multiple-toolchain
/// and cross-language support. Requests may be dispatched to language-specific services or handled
/// centrally, but this is transparent to the client.
public final class SourceKitServer: LanguageServer {

  struct LanguageServiceKey: Hashable {
    var toolchain: String
    var language: Language
  }

  var options: Options

  let toolchainRegistry: ToolchainRegistry

  var languageService: [LanguageServiceKey: ToolchainLanguageServer] = [:]

  /// Documents that are ready for requests and notifications.
  /// This generally means that the `BuildSystem` has notified of us of build settings.
  var documentsReady: Set<DocumentURI> = []

  private var documentToPendingQueue: [DocumentURI: DocumentNotificationRequestQueue] = [:]

  public var workspace: Workspace?

  let fs: FileSystem

  var onExit: () -> Void

  /// Creates a language server for the given client.
  public init(client: Connection, fileSystem: FileSystem = localFileSystem, options: Options, onExit: @escaping () -> Void = {}) {

    self.fs = fileSystem
    self.toolchainRegistry = ToolchainRegistry.shared
    self.options = options
    self.onExit = onExit

    super.init(client: client)
  }

  public override func _registerBuiltinHandlers() {
    _register(SourceKitServer.initialize)
    _register(SourceKitServer.clientInitialized)
    _register(SourceKitServer.cancelRequest)
    _register(SourceKitServer.shutdown)
    _register(SourceKitServer.exit)

    registerWorkspaceNotfication(SourceKitServer.openDocument)
    registerWorkspaceNotfication(SourceKitServer.closeDocument)
    registerWorkspaceNotfication(SourceKitServer.changeDocument)

    registerToolchainTextDocumentNotification(SourceKitServer.willSaveDocument)
    registerToolchainTextDocumentNotification(SourceKitServer.didSaveDocument)

    registerWorkspaceRequest(SourceKitServer.workspaceSymbols)
    registerWorkspaceRequest(SourceKitServer.pollIndex)
    registerWorkspaceRequest(SourceKitServer.executeCommand)

    registerToolchainTextDocumentRequest(SourceKitServer.completion,
                                         CompletionList(isIncomplete: false, items: []))
    registerToolchainTextDocumentRequest(SourceKitServer.hover, nil)
    registerToolchainTextDocumentRequest(SourceKitServer.definition, .locations([]))
    registerToolchainTextDocumentRequest(SourceKitServer.references, [])
    registerToolchainTextDocumentRequest(SourceKitServer.implementation, .locations([]))
    registerToolchainTextDocumentRequest(SourceKitServer.symbolInfo, [])
    registerToolchainTextDocumentRequest(SourceKitServer.documentSymbolHighlight, nil)
    registerToolchainTextDocumentRequest(SourceKitServer.foldingRange, nil)
    registerToolchainTextDocumentRequest(SourceKitServer.documentSymbol, nil)
    registerToolchainTextDocumentRequest(SourceKitServer.documentColor, [])
    registerToolchainTextDocumentRequest(SourceKitServer.documentSemanticTokens, nil)
    registerToolchainTextDocumentRequest(SourceKitServer.documentSemanticTokensDelta, nil)
    registerToolchainTextDocumentRequest(SourceKitServer.documentSemanticTokensRange, nil)
    registerToolchainTextDocumentRequest(SourceKitServer.colorPresentation, [])
    registerToolchainTextDocumentRequest(SourceKitServer.codeAction, nil)
    registerToolchainTextDocumentRequest(SourceKitServer.inlayHints, [])
  }

  /// Register a `TextDocumentRequest` that requires a valid `Workspace`, `ToolchainLanguageServer`,
  /// and open file with resolved (yet potentially invalid) build settings.
  func registerToolchainTextDocumentRequest<PositionRequest: TextDocumentRequest>(
    _ requestHandler: @escaping (SourceKitServer) ->
        (Request<PositionRequest>, Workspace, ToolchainLanguageServer) -> Void,
    _ fallback: PositionRequest.Response
  ) {
    _register { [unowned self] (req: Request<PositionRequest>) in
      guard let workspace = self.workspace else {
        return req.reply(.failure(.serverNotInitialized))
      }
      let doc = req.params.textDocument.uri

      // This should be created as soon as we receive an open call, even if the document
      // isn't yet ready.
      guard let languageService = workspace.documentService[doc] else {
        return req.reply(fallback)
      }

      // If the document is ready, we can handle it right now.
      guard !self.documentsReady.contains(doc) else {
        requestHandler(self)(req, workspace, languageService)
        return
      }

      // Not ready to handle it, we'll queue it and handle it later.
      self.documentToPendingQueue[doc, default: DocumentNotificationRequestQueue()].add(operation: {
          [weak self] in
        guard let self = self else { return }
        requestHandler(self)(req, workspace, languageService)
      }, cancellationHandler: {
        req.reply(fallback)
      })
    }
  }

  /// Register a `TextDocumentNotification` that requires a valid
  /// `ToolchainLanguageServer` and open file with resolved (yet
  /// potentially invalid) build settings.
  func registerToolchainTextDocumentNotification<TextNotification: TextDocumentNotification>(
    _ notificationHandler: @escaping (SourceKitServer) ->
        (Notification<TextNotification>, ToolchainLanguageServer) -> Void
  ) {
    _register { [unowned self] (note: Notification<TextNotification>) in
      guard let workspace = self.workspace else {
        return
      }
      let doc = note.params.textDocument.uri

      // This should be created as soon as we receive an open call, even if the document
      // isn't yet ready.
      guard let languageService = workspace.documentService[doc] else {
        return
      }

      // If the document is ready, we can handle it right now.
      guard !self.documentsReady.contains(doc) else {
        notificationHandler(self)(note, languageService)
        return
      }

      // Not ready to handle it, we'll queue it and handle it later.
      self.documentToPendingQueue[doc, default: DocumentNotificationRequestQueue()].add(operation: {
          [weak self] in
        guard let self = self else { return }
        notificationHandler(self)(note, languageService)
      })
    }
  }

  /// Register a request handler which requires a valid `Workspace`. If called before a valid
  /// `Workspace` exists, this will immediately fail the request.
  func registerWorkspaceRequest<R>(
    _ requestHandler: @escaping (SourceKitServer) -> (Request<R>, Workspace) -> Void)
  {
    _register { [unowned self] (req: Request<R>) in
      guard let workspace = self.workspace else {
        return req.reply(.failure(.serverNotInitialized))
      }

      requestHandler(self)(req, workspace)
    }
  }

  /// Register a notification handler which requires a valid `Workspace`. If called before a
  /// valid `Workspace` exists, the notification is ignored and an error is logged.
  func registerWorkspaceNotfication<N>(
    _ noteHandler: @escaping (SourceKitServer) -> (Notification<N>, Workspace) -> Void)
  {
    _register { [unowned self] (note: Notification<N>) in
      guard let workspace = self.workspace else {
        log("received notification before \"initialize\", ignoring...", level: .error)
        return
      }

      noteHandler(self)(note, workspace)
    }
  }

  public override func _handleUnknown<R>(_ req: Request<R>) {
    if req.clientID == ObjectIdentifier(client) {
      return super._handleUnknown(req)
    }

    // Unknown requests from a language server are passed on to the client.
    let id = client.send(req.params, queue: queue) { result in
      req.reply(result)
    }
    req.cancellationToken.addCancellationHandler {
      self.client.send(CancelRequestNotification(id: id))
    }
  }

  /// Handle an unknown notification.
  public override func _handleUnknown<N>(_ note: Notification<N>) {
    if note.clientID == ObjectIdentifier(client) {
      return super._handleUnknown(note)
    }

    // Unknown notifications from a language server are passed on to the client.
    client.send(note.params)
  }

  func toolchain(for uri: DocumentURI, _ language: Language) -> Toolchain? {
    let supportsLang = { (toolchain: Toolchain) -> Bool in
      // FIXME: the fact that we're looking at clangd/sourcekitd instead of the compiler indicates this method needs a parameter stating what kind of tool we're looking for.
      switch language {
      case .swift:
        return toolchain.sourcekitd != nil
      case .c, .cpp, .objective_c, .objective_cpp:
        return toolchain.clangd != nil
      default:
        return false
      }
    }

    if let toolchain = toolchainRegistry.default, supportsLang(toolchain) {
      return toolchain
    }

    for toolchain in toolchainRegistry.toolchains {
      if supportsLang(toolchain) {
        return toolchain
      }
    }

    return nil
  }
  
  /// After the language service has crashed, send `DidOpenTextDocumentNotification`s to a newly instantiated language service for previously open documents.
  func reopenDocuments(for languageService: ToolchainLanguageServer) {
    queue.async {
      guard let workspace = self.workspace else {
        return
      }
      
      for documentUri in workspace.documentManager.openDocuments where workspace.documentService[documentUri] === languageService {
        guard let snapshot = workspace.documentManager.latestSnapshot(documentUri) else {
          // The document has been closed since we retrieved its URI. We don't care about it anymore.
          continue
        }

        // Close the docuemnt properly in the document manager and build system manager to start with a clean sheet when re-opening it.
        let closeNotification = DidCloseTextDocumentNotification(textDocument: TextDocumentIdentifier(documentUri))
        self.closeDocument(closeNotification, workspace: workspace)

        let textDocument = TextDocumentItem(uri: documentUri,
                                            language: snapshot.document.language,
                                            version: snapshot.version,
                                            text: snapshot.text)
        self.openDocument(DidOpenTextDocumentNotification(textDocument: textDocument), workspace: workspace)

      }
    }
  }

  func languageService(
    for toolchain: Toolchain,
    _ language: Language,
    in workspace: Workspace
  ) -> ToolchainLanguageServer? {
    let key = LanguageServiceKey(toolchain: toolchain.identifier, language: language)
    if let service = languageService[key] {
      return service
    }

    // Start a new service.
    return orLog("failed to start language service", level: .error) {
      guard let service = try SourceKitLSP.languageService(
        for: toolchain, language, options: options, client: self, in: workspace, reopenDocuments: { [weak self] in self?.reopenDocuments(for: $0) })
      else {
        return nil
      }

      let pid = Int(ProcessInfo.processInfo.processIdentifier)
      let resp = try service.initializeSync(InitializeRequest(
        processId: pid,
        rootPath: nil,
        rootURI: workspace.rootUri,
        initializationOptions: nil,
        capabilities: workspace.capabilityRegistry.clientCapabilities,
        trace: .off,
        workspaceFolders: nil))
      let languages = languageClass(for: language)
      self.registerCapabilities(
        for: resp.capabilities, languages: languages, registry: workspace.capabilityRegistry)

      // FIXME: store the server capabilities.
      let syncKind = resp.capabilities.textDocumentSync?.change ?? .incremental
      guard syncKind == .incremental else {
        fatalError("non-incremental update not implemented")
      }

      service.clientInitialized(InitializedNotification())

      languageService[key] = service
      return service
    }
  }

  /// **Public for testing purposes only**
  public func _languageService(for uri: DocumentURI, _ language: Language, in workspace: Workspace) -> ToolchainLanguageServer? {
    return languageService(for: uri, language, in: workspace)
  }

  func languageService(for uri: DocumentURI, _ language: Language, in workspace: Workspace) -> ToolchainLanguageServer? {
    if let service = workspace.documentService[uri] {
      return service
    }

    guard let toolchain = toolchain(for: uri, language),
          let service = languageService(for: toolchain, language, in: workspace)
    else {
      return nil
    }

    log("Using toolchain \(toolchain.displayName) (\(toolchain.identifier)) for \(uri)")

    workspace.documentService[uri] = service
    return service
  }
}

// MARK: - Build System Delegate

extension SourceKitServer: BuildSystemDelegate {
  public func buildTargetsChanged(_ changes: [BuildTargetEvent]) {
    // TODO: do something with these changes once build target support is in place
  }

  private func affectedOpenDocumentsForChangeSet(
    _ changes: Set<DocumentURI>,
    _ documentManager: DocumentManager
  ) -> Set<DocumentURI> {
    // An empty change set is treated as if all open files have been modified.
    guard !changes.isEmpty else {
      return documentManager.openDocuments
    }
    return documentManager.openDocuments.intersection(changes)
  }

  /// Handle a build settings change notification from the `BuildSystem`.
  /// This has two primary cases:
  /// - Initial settings reported for a given file, now we can fully open it
  /// - Changed settings for an already open file
  public func fileBuildSettingsChanged(
    _ changedFiles: [DocumentURI: FileBuildSettingsChange]
  ) {
    queue.async {
      guard let workspace = self.workspace else {
        return
      }
      let documentManager = workspace.documentManager
      let openDocuments = documentManager.openDocuments
      for (uri, change) in changedFiles {
        // Non-ready documents should be considered open even though we haven't
        // opened it with the language service yet.
        guard openDocuments.contains(uri) else { continue }
        guard self.documentsReady.contains(uri) else {
          // Case 1: initial settings for a given file. Now we can process our backlog.
          log("Initial build settings received for opened file \(uri)")

          guard let service = workspace.documentService[uri] else {
            // Unexpected: we should have an existing language service if we've registered for
            // change notifications for an opened but non-ready document.
            log("No language service for build settings change to non-ready file \(uri)",
                level: .error)

            // We're in an odd state, cancel pending requests if we have any.
            self.documentToPendingQueue[uri]?.cancelAll()
            self.documentToPendingQueue[uri] = nil
            continue
          }

          // Notify the language server so it can apply the proper arguments.
          service.documentUpdatedBuildSettings(uri, change: change)

          // Catch up on any queued notifications and requests.
          self.documentToPendingQueue[uri]?.handleAll()
          self.documentToPendingQueue[uri] = nil
          self.documentsReady.insert(uri)
          continue
        }

        // Case 2: changed settings for an already open file.
        log("Build settings changed for opened file \(uri)")
        if let service = workspace.documentService[uri] {
          service.documentUpdatedBuildSettings(uri, change: change)
        }
      }
    }
  }

  /// Handle a dependencies updated notification from the `BuildSystem`.
  /// We inform the respective language services as long as the given file is open
  /// (not queued for opening).
  public func filesDependenciesUpdated(_ changedFiles: Set<DocumentURI>) {
    queue.async {
      guard let workspace = self.workspace else {
        return
      }
      for uri in self.affectedOpenDocumentsForChangeSet(changedFiles, workspace.documentManager) {
        // Make sure the document is ready - otherwise the language service won't
        // know about the document yet.
        guard self.documentsReady.contains(uri) else {
          continue
        }
        log("Dependencies updated for opened file \(uri)")
        if let service = workspace.documentService[uri] {
          service.documentDependenciesUpdated(uri)
        }
      }
    }
  }
}

// MARK: - Request and notification handling

extension SourceKitServer {

  // MARK: - General

  func initialize(_ req: Request<InitializeRequest>) {
    var indexOptions = self.options.indexOptions
    if case .dictionary(let options) = req.params.initializationOptions {
      if case .bool(let listenToUnitEvents) = options["listenToUnitEvents"] {
        indexOptions.listenToUnitEvents = listenToUnitEvents
      }
      if case .dictionary(let completionOptions) = options["completion"] {
        if case .bool(let serverSideFiltering) = completionOptions["serverSideFiltering"] {
          self.options.completionOptions.serverSideFiltering = serverSideFiltering
        }
        switch completionOptions["maxResults"] {
        case .none:
          break
        case .some(.null):
          self.options.completionOptions.maxResults = nil
        case .some(.int(let maxResults)):
          self.options.completionOptions.maxResults = maxResults
        case .some(let invalid):
          log("expected null or int for 'maxResults'; got \(invalid)", level: .warning)
        }
      }
    }

    let capabilityRegistry = CapabilityRegistry(clientCapabilities: req.params.capabilities)

    // Any messages sent before initialize returns are expected to fail, so this will run before
    // the first "supported" request. Run asynchronously to hide the latency of setting up the
    // build system and index.
    queue.async {
      if let uri = req.params.rootURI {
        self.workspace = try? Workspace(
          rootUri: uri,
          capabilityRegistry: capabilityRegistry,
          toolchainRegistry: self.toolchainRegistry,
          buildSetup: self.options.buildSetup,
          indexOptions: indexOptions)
      } else if let path = req.params.rootPath {
        self.workspace = try? Workspace(
          rootUri: DocumentURI(URL(fileURLWithPath: path)),
          capabilityRegistry: capabilityRegistry,
          toolchainRegistry: self.toolchainRegistry,
          buildSetup: self.options.buildSetup,
          indexOptions: indexOptions)
      }

      if self.workspace == nil {
        log("no workspace found", level: .warning)

        self.workspace = Workspace(
          rootUri: req.params.rootURI,
          capabilityRegistry: capabilityRegistry,
          toolchainRegistry: self.toolchainRegistry,
          buildSetup: self.options.buildSetup,
          underlyingBuildSystem: nil,
          index: nil,
          indexDelegate: nil)
      }

      assert(self.workspace != nil)
      self.workspace?.buildSystemManager.delegate = self
    }

    req.reply(InitializeResult(capabilities:
      self.serverCapabilities(for: req.params.capabilities, registry: capabilityRegistry)))
  }

  func serverCapabilities(
    for client: ClientCapabilities,
    registry: CapabilityRegistry
  ) -> ServerCapabilities {
    let completionOptions: CompletionOptions?
    if registry.clientHasDynamicCompletionRegistration {
      // We'll initialize this dynamically instead of statically.
      completionOptions = nil
    } else {
      completionOptions = LanguageServerProtocol.CompletionOptions(
        resolveProvider: false,
        triggerCharacters: ["."]
      )
    }
    return ServerCapabilities(
      textDocumentSync: TextDocumentSyncOptions(
        openClose: true,
        change: .incremental,
        willSave: true,
        willSaveWaitUntil: false,
        save: .value(TextDocumentSyncOptions.SaveOptions(includeText: false))
      ),
      hoverProvider: true,
      completionProvider: completionOptions,
      definitionProvider: true,
      implementationProvider: .bool(true),
      referencesProvider: true,
      documentHighlightProvider: true,
      documentSymbolProvider: true,
      workspaceSymbolProvider: true,
      codeActionProvider: .value(CodeActionServerCapabilities(
        clientCapabilities: client.textDocument?.codeAction,
        codeActionOptions: CodeActionOptions(codeActionKinds: nil),
        supportsCodeActions: true
      )),
      colorProvider: .bool(true),
      foldingRangeProvider: .bool(!registry.clientHasDynamicFoldingRangeRegistration),
      executeCommandProvider: ExecuteCommandOptions(
        commands: builtinSwiftCommands // FIXME: Clangd commands?
      )
    )
  }

  func registerCapabilities(
    for server: ServerCapabilities,
    languages: [Language],
    registry: CapabilityRegistry
  ) {
    if let completionOptions = server.completionProvider {
      registry.registerCompletionIfNeeded(options: completionOptions, for: languages) {
        self.dynamicallyRegisterCapability($0, registry)
      }
    }
    if server.foldingRangeProvider?.isSupported == true {
      registry.registerFoldingRangeIfNeeded(options: FoldingRangeOptions(), for: languages) {
        self.dynamicallyRegisterCapability($0, registry)
      }
    }
    if let semanticTokensOptions = server.semanticTokensProvider {
      registry.registerSemanticTokensIfNeeded(options: semanticTokensOptions, for: languages) {
        self.dynamicallyRegisterCapability($0, registry)
      }
    }
  }

  private func dynamicallyRegisterCapability(
    _ registration: CapabilityRegistration,
    _ registry: CapabilityRegistry
  ) {
    let req = RegisterCapabilityRequest(registrations: [registration])
    let _ = client.send(req, queue: queue) { result in
      if let error = result.failure {
        log("Failed to dynamically register for \(registration.method): \(error)", level: .error)
        registry.remove(registration: registration)
      }
    }
  }

  func clientInitialized(_: Notification<InitializedNotification>) {
    // Nothing to do.
  }

  func cancelRequest(_ notification: Notification<CancelRequestNotification>) {
    let key = RequestCancelKey(client: notification.clientID, request: notification.params.id)
    requestCancellation[key]?.cancel()
  }

  /// The server is about to exit, and the server should flush any buffered state.
  ///
  /// The server shall not be used to handle more requests (other than possibly
  /// `shutdown` and `exit`) and should attempt to flush any buffered state
  /// immediately, such as sending index changes to disk.
  public func prepareForExit() {
    // Note: this method should be safe to call multiple times, since we want to
    // be resilient against multiple possible shutdown sequences, including
    // pipe failure.

    // Close the index, which will flush to disk.
    self.queue.sync {
      self._prepareForExit()
    }
  }

  func _prepareForExit() {
    // Note: this method should be safe to call multiple times, since we want to
    // be resilient against multiple possible shutdown sequences, including
    // pipe failure.

    // Close the index, which will flush to disk.
    self.workspace?.buildSystemManager.mainFilesProvider = nil
    self.workspace?.index = nil

    // Break retain cycle with the BSM.
    self.workspace?.buildSystemManager.delegate = nil
  }


  func shutdown(_ request: Request<ShutdownRequest>) {
    _prepareForExit()
    for service in languageService.values {
      service.shutdown()
    }
    languageService = [:]
    request.reply(VoidResponse())
  }

  func exit(_ notification: Notification<ExitNotification>) {
    // Should have been called in shutdown, but allow misbehaving clients.
    _prepareForExit()

    // Call onExit only once, and hop off queue to allow the handler to call us back.
    let onExit = self.onExit
    self.onExit = {}
    DispatchQueue.global().async {
      onExit()
    }
  }

  // MARK: - Text synchronization

  func openDocument(_ note: Notification<DidOpenTextDocumentNotification>, workspace: Workspace) {
    openDocument(note.params, workspace: workspace)
  }
  
  private func openDocument(_ note: DidOpenTextDocumentNotification, workspace: Workspace) {
    // Immediately open the document even if the build system isn't ready. This is important since
    // we check that the document is open when we receive messages from the build system.
    workspace.documentManager.open(note)

    let textDocument = note.textDocument
    let uri = textDocument.uri
    let language = textDocument.language

    // If we can't create a service, this document is unsupported and we can bail here.
    guard let service = languageService(for: uri, language, in: workspace) else {
      return
    }

    workspace.buildSystemManager.registerForChangeNotifications(for: uri, language: language)

    // If the document is ready, we can immediately send the notification.
    guard !documentsReady.contains(uri) else {
      service.openDocument(note)
      return
    }

    // Need to queue the open call so we can handle it when ready.
    self.documentToPendingQueue[uri, default: DocumentNotificationRequestQueue()].add(operation: {
      service.openDocument(note)
    })
  }

  func closeDocument(_ note: Notification<DidCloseTextDocumentNotification>, workspace: Workspace) {
    self.closeDocument(note.params, workspace: workspace)
  }

  func closeDocument(_ note: DidCloseTextDocumentNotification, workspace: Workspace) {
    // Immediately close the document. We need to be sure to clear our pending work queue in case
    // the build system still isn't ready.
    workspace.documentManager.close(note)

    let uri = note.textDocument.uri

    workspace.buildSystemManager.unregisterForChangeNotifications(for: uri)

    // If the document is ready, we can close it now.
    guard !documentsReady.contains(uri) else {
      self.documentsReady.remove(uri)
      workspace.documentService[uri]?.closeDocument(note)
      return
    }

    // Clear any queued notifications via their cancellation handlers.
    // No need to send the notification since it was never considered opened.
    self.documentToPendingQueue[uri]?.cancelAll()
    self.documentToPendingQueue[uri] = nil
  }

  func changeDocument(_ note: Notification<DidChangeTextDocumentNotification>, workspace: Workspace) {
    let uri = note.params.textDocument.uri

    // If the document is ready, we can handle the change right now.
    guard !documentsReady.contains(uri) else {
      workspace.documentManager.edit(note.params)
      workspace.documentService[uri]?.changeDocument(note.params)
      return
    }

    // Need to queue the change call so we can handle it when ready.
    self.documentToPendingQueue[uri, default: DocumentNotificationRequestQueue()].add(operation: {
      workspace.documentManager.edit(note.params)
      workspace.documentService[uri]?.changeDocument(note.params)
    })
  }

  func willSaveDocument(
    _ note: Notification<WillSaveTextDocumentNotification>,
    languageService: ToolchainLanguageServer
  ) {
    languageService.willSaveDocument(note.params)
  }

  func didSaveDocument(
    _ note: Notification<DidSaveTextDocumentNotification>,
    languageService: ToolchainLanguageServer
  ) {
    languageService.didSaveDocument(note.params)
  }

  // MARK: - Language features

  func completion(
    _ req: Request<CompletionRequest>,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) {
    languageService.completion(req)
  }

  func hover(
    _ req: Request<HoverRequest>,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) {
    languageService.hover(req)
  }

  /// Find all symbols in the workspace that include a string in their name.
  /// - returns: An array of SymbolOccurrences that match the string.
  func findWorkspaceSymbols(matching: String) -> [SymbolOccurrence] {
    // Ignore short queries since they are:
    // - noisy and slow, since they can match many symbols
    // - normally unintentional, triggered when the user types slowly or if the editor doesn't
    //   debounce events while the user is typing
    guard matching.count >= minWorkspaceSymbolPatternLength else {
      return []
    }
    var symbolOccurenceResults: [SymbolOccurrence] = []
    workspace?.index?.forEachCanonicalSymbolOccurrence(
      containing: matching,
      anchorStart: false,
      anchorEnd: false,
      subsequence: true,
      ignoreCase: true
    ) { symbol in
      guard !symbol.location.isSystem && !symbol.roles.contains(.accessorOf) else {
        return true
      }
      symbolOccurenceResults.append(symbol)
      // FIXME: Once we have cancellation support, we should fetch all results and take the top
      // `maxWorkspaceSymbolResults` symbols but bail if cancelled.
      //
      // Until then, take the first `maxWorkspaceSymbolResults` symbols to limit the impact of
      // queries which match many symbols.
      return symbolOccurenceResults.count < maxWorkspaceSymbolResults
    }
    return symbolOccurenceResults
  }

  /// Handle a workspace/symbol request, returning the SymbolInformation.
  /// - returns: An array with SymbolInformation for each matching symbol in the workspace.
  func workspaceSymbols(_ req: Request<WorkspaceSymbolsRequest>, workspace: Workspace) {
    let symbols = findWorkspaceSymbols(
      matching: req.params.query
    ).map({symbolOccurrence -> SymbolInformation in
      let symbolPosition = Position(
        line: symbolOccurrence.location.line - 1, // 1-based -> 0-based
        // FIXME: we need to convert the utf8/utf16 column, which may require reading the file!
        utf16index: symbolOccurrence.location.utf8Column - 1)

      let symbolLocation = Location(
        uri: DocumentURI(URL(fileURLWithPath: symbolOccurrence.location.path)),
        range: Range(symbolPosition))

      return SymbolInformation(
        name: symbolOccurrence.symbol.name,
        kind: symbolOccurrence.symbol.kind.asLspSymbolKind(),
        deprecated: nil,
        location: symbolLocation,
        containerName: symbolOccurrence.getContainerName()
      )
    })
    req.reply(symbols)
  }

  /// Forwards a SymbolInfoRequest to the appropriate toolchain service for this document.
  func symbolInfo(
    _ req: Request<SymbolInfoRequest>,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) {
    languageService.symbolInfo(req)
  }

  func documentSymbolHighlight(
    _ req: Request<DocumentHighlightRequest>,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) {
    languageService.documentSymbolHighlight(req)
  }

  func foldingRange(
    _ req: Request<FoldingRangeRequest>,
    workspace: Workspace,
    languageService: ToolchainLanguageServer) {
    languageService.foldingRange(req)
  }

  func documentSymbol(
    _ req: Request<DocumentSymbolRequest>,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) {
    languageService.documentSymbol(req)
  }

  func documentColor(
    _ req: Request<DocumentColorRequest>,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) {
    languageService.documentColor(req)
  }

  private func supportsSemanticTokens(in uri: DocumentURI) -> Bool {
    guard let workspace = workspace,
          let snapshot = workspace.documentManager.latestSnapshot(uri) else {
      return false
    }
    let language = snapshot.document.language
    return workspace.capabilityRegistry.hasSemanticTokensRegistration(for: language)
  }

  func documentSemanticTokens(
    _ req: Request<DocumentSemanticTokensRequest>,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) {
    if supportsSemanticTokens(in: req.params.textDocument.uri) {
      languageService.documentSemanticTokens(req)
    } else {
      req.reply(DocumentSemanticTokensResponse(data: []))
    }
  }

  func documentSemanticTokensDelta(
    _ req: Request<DocumentSemanticTokensDeltaRequest>,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) {
    if supportsSemanticTokens(in: req.params.textDocument.uri) {
      languageService.documentSemanticTokensDelta(req)
    } else {
      req.reply(.tokens(.init(data: [])))
    }
  }

  func documentSemanticTokensRange(
    _ req: Request<DocumentSemanticTokensRangeRequest>,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) {
    if supportsSemanticTokens(in: req.params.textDocument.uri) {
      languageService.documentSemanticTokensRange(req)
    } else {
      req.reply(DocumentSemanticTokensResponse(data: []))
    }
  }

  func colorPresentation(
    _ req: Request<ColorPresentationRequest>,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) {
    languageService.colorPresentation(req)
  }

  func executeCommand(_ req: Request<ExecuteCommandRequest>, workspace: Workspace) {
    guard let uri = req.params.textDocument?.uri else {
      log("attempted to perform executeCommand request without an url!", level: .error)
      req.reply(nil)
      return
    }
    guard let languageService = workspace.documentService[uri] else {
      req.reply(nil)
      return
    }

    // If the document isn't yet ready, queue the request.
    guard self.documentsReady.contains(uri) else {
      self.documentToPendingQueue[uri, default: DocumentNotificationRequestQueue()].add(operation: {
          [weak self] in
        guard let self = self else { return }
        self.fowardExecuteCommand(req, languageService: languageService)
      }, cancellationHandler: {
        req.reply(nil)
      })
      return
    }

    self.fowardExecuteCommand(req, languageService: languageService)
  }

  func fowardExecuteCommand(
    _ req: Request<ExecuteCommandRequest>,
    languageService: ToolchainLanguageServer
  ) {
    let params = req.params
    let executeCommand = ExecuteCommandRequest(command: params.command,
                                               arguments: params.argumentsWithoutSourceKitMetadata)
    let callback = callbackOnQueue(self.queue) { (result: Result<ExecuteCommandRequest.Response, ResponseError>) in
      req.reply(result)
    }
    let request = Request(executeCommand, id: req.id, clientID: ObjectIdentifier(self),
                          cancellation: req.cancellationToken, reply: callback)
    languageService.executeCommand(request)
  }

  func codeAction(
    _ req: Request<CodeActionRequest>,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) {
    let codeAction = CodeActionRequest(range: req.params.range, context: req.params.context,
                                       textDocument: req.params.textDocument)
    let callback = callbackOnQueue(self.queue) { (result: Result<CodeActionRequest.Response, ResponseError>) in
      switch result {
      case .success(let reply):
        req.reply(req.params.injectMetadata(toResponse: reply))
      default:
        req.reply(result)
      }
    }
    let request = Request(codeAction, id: req.id, clientID: ObjectIdentifier(self),
                          cancellation: req.cancellationToken, reply: callback)
    languageService.codeAction(request)
  }

  func inlayHints(
    _ req: Request<InlayHintsRequest>,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) {
    languageService.inlayHints(req)
  }

  func definition(
    _ req: Request<DefinitionRequest>,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) {
    let symbolInfo = SymbolInfoRequest(textDocument: req.params.textDocument, position: req.params.position)
    let index = self.workspace?.index
    // If we're unable to handle the definition request using our index, see if the
    // language service can handle it (e.g. clangd can provide AST based definitions).
    let resultHandler: ([Location], ResponseError?) -> Void = { (locs, error) in
      guard locs.isEmpty else {
        req.reply(.locations(locs))
        return
      }
      let handled = languageService.definition(req)
      guard !handled else { return }
      if let error = error {
        req.reply(.failure(error))
      } else {
        req.reply(.locations([]))
      }
    }
    let callback = callbackOnQueue(self.queue) { (result: Result<SymbolInfoRequest.Response, ResponseError>) in
      guard let symbols: [SymbolDetails] = result.success ?? nil, let symbol = symbols.first else {
        resultHandler([], result.failure)
        return
      }

      let fallbackLocation = [symbol.bestLocalDeclaration].compactMap { $0 }

      guard let usr = symbol.usr, let index = index else {
        resultHandler(fallbackLocation, nil)
        return
      }

      log("performing indexed jump-to-def with usr \(usr)")

      var occurs = index.occurrences(ofUSR: usr, roles: [.definition])
      if occurs.isEmpty {
        occurs = index.occurrences(ofUSR: usr, roles: [.declaration])
      }

      // FIXME: overrided method logic

      let locations = occurs.compactMap { occur -> Location? in
        if occur.location.path.isEmpty {
          return nil
        }
        return Location(
          uri: DocumentURI(URL(fileURLWithPath: occur.location.path)),
          range: Range(Position(
            line: occur.location.line - 1, // 1-based -> 0-based
            // FIXME: we need to convert the utf8/utf16 column, which may require reading the file!
            utf16index: occur.location.utf8Column - 1
            ))
        )
      }

      resultHandler(locations.isEmpty ? fallbackLocation : locations, nil)
    }
    let request = Request(symbolInfo, id: req.id, clientID: ObjectIdentifier(self),
                          cancellation: req.cancellationToken, reply: callback)
    languageService.symbolInfo(request)
  }

  // FIXME: a lot of duplication with definition request
  func implementation(
    _ req: Request<ImplementationRequest>,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) {
    let symbolInfo = SymbolInfoRequest(textDocument: req.params.textDocument, position: req.params.position)
    let index = self.workspace?.index
    let callback = callbackOnQueue(self.queue) { (result: Result<SymbolInfoRequest.Response, ResponseError>) in
      guard let symbols: [SymbolDetails] = result.success ?? nil, let symbol = symbols.first else {
        if let error = result.failure {
          req.reply(.failure(error))
        } else {
          req.reply(.locations([]))
        }
        return
      }

      guard let usr = symbol.usr, let index = index else {
        return req.reply(.locations([]))
      }

      var occurs = index.occurrences(ofUSR: usr, roles: .baseOf)
      if occurs.isEmpty {
        occurs = index.occurrences(relatedToUSR: usr, roles: .overrideOf)
      }

      let locations = occurs.compactMap { occur -> Location? in
        if occur.location.path.isEmpty {
          return nil
        }
        return Location(
          uri: DocumentURI(URL(fileURLWithPath: occur.location.path)),
          range: Range(Position(
            line: occur.location.line - 1, // 1-based -> 0-based
            // FIXME: we need to convert the utf8/utf16 column, which may require reading the file!
            utf16index: occur.location.utf8Column - 1
            ))
        )
      }

      req.reply(.locations(locations))
    }
    let request = Request(symbolInfo, id: req.id, clientID: ObjectIdentifier(self),
                          cancellation: req.cancellationToken, reply: callback)
    languageService.symbolInfo(request)
  }

  // FIXME: a lot of duplication with definition request
  func references(
    _ req: Request<ReferencesRequest>,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) {
    let symbolInfo = SymbolInfoRequest(textDocument: req.params.textDocument, position: req.params.position)
    let callback = callbackOnQueue(self.queue) { (result: Result<SymbolInfoRequest.Response, ResponseError>) in
      guard let symbols: [SymbolDetails] = result.success ?? nil, let symbol = symbols.first else {
        if let error = result.failure {
          req.reply(.failure(error))
        } else {
          req.reply([])
        }
        return
      }

      guard let usr = symbol.usr, let index = workspace.index else {
        req.reply([])
        return
      }

      log("performing indexed jump-to-def with usr \(usr)")

      var roles: SymbolRole = [.reference]
      if req.params.context.includeDeclaration {
        roles.formUnion([.declaration, .definition])
      }

      let occurs = index.occurrences(ofUSR: usr, roles: roles)

      let locations = occurs.compactMap { occur -> Location? in
        if occur.location.path.isEmpty {
          return nil
        }
        return Location(
          uri: DocumentURI(URL(fileURLWithPath: occur.location.path)),
          range: Range(Position(
            line: occur.location.line - 1, // 1-based -> 0-based
            // FIXME: we need to convert the utf8/utf16 column, which may require reading the file!
            utf16index: occur.location.utf8Column - 1
            ))
        )
      }

      req.reply(locations)
    }
    let request = Request(symbolInfo, id: req.id, clientID: ObjectIdentifier(self),
                          cancellation: req.cancellationToken, reply: callback)
    languageService.symbolInfo(request)
  }

  func pollIndex(_ req: Request<PollIndexRequest>, workspace: Workspace) {
    workspace.index?.pollForUnitChangesAndWait()
    req.reply(VoidResponse())
  }
}

private func callbackOnQueue<R: ResponseType>(
  _ queue: DispatchQueue,
  _ callback: @escaping (LSPResult<R>) -> Void
) -> (LSPResult<R>) -> Void {
  return { (result: LSPResult<R>) in
    queue.async {
      callback(result)
    }
  }
}

/// Creates a new connection from `client` to a service for `language` if available, and launches
/// the service. Does *not* send the initialization request.
///
/// - returns: The connection, if a suitable language service is available; otherwise nil.
/// - throws: If there is a suitable service but it fails to launch, throws an error.
public func languageService(
  for toolchain: Toolchain,
  _ language: Language,
  options: SourceKitServer.Options,
  client: MessageHandler,
  in workspace: Workspace,
  reopenDocuments: @escaping (ToolchainLanguageServer) -> Void
) throws -> ToolchainLanguageServer? {
  switch language {

  case .c, .cpp, .objective_c, .objective_cpp:
    guard toolchain.clangd != nil else { return nil }
    return try makeJSONRPCClangServer(client: client, toolchain: toolchain, clangdOptions: options.clangdOptions, reopenDocuments: reopenDocuments)

  case .swift:
    guard let sourcekitd = toolchain.sourcekitd else { return nil }
    return try makeLocalSwiftServer(
      client: client,
      sourcekitd: sourcekitd,
      clientCapabilities: workspace.capabilityRegistry.clientCapabilities,
      options: options,
      reopenDocuments: reopenDocuments)

  default:
    return nil
  }
}

private func languageClass(for language: Language) -> [Language] {
  switch language {
  case .c, .cpp, .objective_c, .objective_cpp:
    return [.c, .cpp, .objective_c, .objective_cpp]
  case .swift:
    return [.swift]
  default:
    return [language]
  }
}

/// Minimum supported pattern length for a `workspace/symbol` request, smaller pattern
/// strings are not queried and instead we return no results.
private let minWorkspaceSymbolPatternLength = 3

/// The maximum number of results to return from a `workspace/symbol` request.
private let maxWorkspaceSymbolResults = 4096

public typealias Notification = LanguageServerProtocol.Notification
public typealias Diagnostic = LanguageServerProtocol.Diagnostic

extension IndexSymbolKind {
  func asLspSymbolKind() -> SymbolKind {
    switch self {
    case .class: 
      return .class
    case .classMethod, .instanceMethod, .staticMethod: 
      return .method
    case .instanceProperty, .staticProperty, .classProperty: 
      return .property
    case .enum: 
      return .enum
    case .enumConstant: 
      return .enumMember
    case .protocol: 
      return .interface
    case .function, .conversionFunction: 
      return .function
    case .variable: 
      return .variable
    case .struct: 
      return .struct
    case .parameter: 
      return .typeParameter

    default:
      return .null
    }
  }
}

extension SymbolOccurrence {
  /// Get the name of the symbol that is a parent of this symbol, if one exists
  func getContainerName() -> String? {
    return relations.first(where: { $0.roles.contains(.childOf) })?.symbol.name
  }
}

/// Simple struct for pending notifications/requests, including a cancellation handler.
/// For convenience the notifications/request handlers are type erased via wrapping.
private struct NotificationRequestOperation {
  let operation: () -> Void
  let cancellationHandler: (() -> Void)?
}

/// Used to queue up notifications and requests for documents which are blocked
/// on `BuildSystem` operations such as fetching build settings.
///
/// Note: This is not thread safe. Must be called from the `SourceKitServer.queue`.
private struct DocumentNotificationRequestQueue {
  private var queue = [NotificationRequestOperation]()

  /// Add an operation to the end of the queue.
  mutating func add(operation: @escaping () -> Void, cancellationHandler: (() -> Void)? = nil) {
    queue.append(NotificationRequestOperation(operation: operation, cancellationHandler: cancellationHandler))
  }

  /// Invoke all operations in the queue.
  mutating func handleAll() {
    for task in queue {
      task.operation()
    }
    queue = []
  }

  /// Cancel all operations in the queue. No-op for operations without a cancellation
  /// handler.
  mutating func cancelAll() {
    for task in queue {
      if let cancellationHandler = task.cancellationHandler {
        cancellationHandler()
      }
    }
    queue = []
  }
}
