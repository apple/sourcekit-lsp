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

import PackageLoading

import protocol TSCBasic.FileSystem
import struct TSCBasic.AbsolutePath
import var TSCBasic.localFileSystem

public typealias URL = Foundation.URL

private struct WeakWorkspace {
  weak var value: Workspace?
}

/// Exhaustive enumeration of all toolchain language servers known to SourceKit-LSP.
enum LanguageServerType: Hashable {
  case clangd
  case swift

  init?(language: Language) {
    switch language {
    case .c, .cpp, .objective_c, .objective_cpp:
      self = .clangd
    case .swift:
      self = .swift
    default:
      return nil
    }
  }

  /// The `ToolchainLanguageServer` class used to provide functionality for this language class.
  var serverType: ToolchainLanguageServer.Type {
    switch self {
    case .clangd:
      return ClangLanguageServerShim.self
    case .swift:
      return SwiftLanguageServer.self
    }
  }
}

/// The SourceKit language server.
///
/// This is the client-facing language server implementation, providing indexing, multiple-toolchain
/// and cross-language support. Requests may be dispatched to language-specific services or handled
/// centrally, but this is transparent to the client.
public final class SourceKitServer: LanguageServer {
  var options: Options

  let toolchainRegistry: ToolchainRegistry

  var capabilityRegistry: CapabilityRegistry?

  var languageServices: [LanguageServerType: [ToolchainLanguageServer]] = [:]

  /// Documents that are ready for requests and notifications.
  /// This generally means that the `BuildSystem` has notified of us of build settings.
  var documentsReady: Set<DocumentURI> = []

  private var documentToPendingQueue: [DocumentURI: DocumentNotificationRequestQueue] = [:]

  private let documentManager = DocumentManager()

  /// **Public for testing**
  public var _documentManager: DocumentManager {
    return documentManager
  }

  /// Caches which workspace a document with the given URI should be opened in.
  /// Must only be accessed from `queue`.
  private var uriToWorkspaceCache: [DocumentURI: WeakWorkspace] = [:] {
    didSet {
      dispatchPrecondition(condition: .onQueue(queue))
    }
  }

  /// Must only be accessed from `queue`.
  private var workspaces: [Workspace] = [] {
    didSet {
      dispatchPrecondition(condition: .onQueue(queue))
      uriToWorkspaceCache = [:]
    }
  }

  /// **Public for testing**
  public var _workspaces: [Workspace] {
    get {
      return queue.sync {
        return self.workspaces
      }
    }
    set {
      queue.sync {
        self.workspaces = newValue
      }
    }
  }

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

  public func workspaceForDocument(uri: DocumentURI) -> Workspace? {
    dispatchPrecondition(condition: .onQueue(queue))
    if workspaces.count == 1 {
      // Special handling: If there is only one workspace, open all files in it.
      // This retains the behavior of SourceKit-LSP before it supported multiple workspaces.
      return workspaces.first
    }

    if let cachedWorkspace = uriToWorkspaceCache[uri]?.value {
      return cachedWorkspace
    }

    // Pick the workspace with the best FileHandlingCapability for this file.
    // If there is a tie, use the workspace that occurred first in the list.
    var bestWorkspace: (workspace: Workspace?, fileHandlingCapability: FileHandlingCapability) = (nil, .unhandled)
    for workspace in workspaces {
      let fileHandlingCapability = workspace.buildSystemManager.fileHandlingCapability(for: uri)
      if fileHandlingCapability > bestWorkspace.fileHandlingCapability {
        bestWorkspace = (workspace, fileHandlingCapability)
      }
    }
    uriToWorkspaceCache[uri] = WeakWorkspace(value: bestWorkspace.workspace)
    return bestWorkspace.workspace
  }

  public override func _registerBuiltinHandlers() {
    _register(SourceKitServer.initialize)
    _register(SourceKitServer.clientInitialized)
    _register(SourceKitServer.cancelRequest)
    _register(SourceKitServer.shutdown)
    _register(SourceKitServer.exit)

    _register(SourceKitServer.openDocument)
    _register(SourceKitServer.closeDocument)
    _register(SourceKitServer.changeDocument)
    _register(SourceKitServer.didChangeWorkspaceFolders)
    _register(SourceKitServer.didChangeWatchedFiles)

    registerToolchainTextDocumentNotification(SourceKitServer.willSaveDocument)
    registerToolchainTextDocumentNotification(SourceKitServer.didSaveDocument)

    _register(SourceKitServer.workspaceSymbols)
    _register(SourceKitServer.pollIndex)
    _register(SourceKitServer.executeCommand)

    _register(SourceKitServer.incomingCalls)
    _register(SourceKitServer.outgoingCalls)

    _register(SourceKitServer.supertypes)
    _register(SourceKitServer.subtypes)

    registerToolchainTextDocumentRequest(SourceKitServer.completion,
                                         CompletionList(isIncomplete: false, items: []))
    registerToolchainTextDocumentRequest(SourceKitServer.completionResolve, CompletionItem(label: "", kind: .class))
    registerToolchainTextDocumentRequest(SourceKitServer.hover, nil)
    registerToolchainTextDocumentRequest(SourceKitServer.declaration, .locations([]))
    registerToolchainTextDocumentRequest(SourceKitServer.definition, .locations([]))
    registerToolchainTextDocumentRequest(SourceKitServer.references, [])
    registerToolchainTextDocumentRequest(SourceKitServer.implementation, .locations([]))
    registerToolchainTextDocumentRequest(SourceKitServer.prepareCallHierarchy, [])
    registerToolchainTextDocumentRequest(SourceKitServer.prepareTypeHierarchy, [])
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
    registerToolchainTextDocumentRequest(SourceKitServer.inlayHint, [])
  }

  /// Register a `TextDocumentRequest` that requires a valid `Workspace`, `ToolchainLanguageServer`,
  /// and open file with resolved (yet potentially invalid) build settings.
  func registerToolchainTextDocumentRequest<PositionRequest: TextDocumentRequest>(
    _ requestHandler: @escaping (SourceKitServer) ->
        (Request<PositionRequest>, Workspace, ToolchainLanguageServer) -> Void,
    _ fallback: PositionRequest.Response
  ) {
    _register { [unowned self] (req: Request<PositionRequest>) in
      let doc = req.params.textDocument.uri
      guard let workspace = self.workspaceForDocument(uri: doc) else {
        return req.reply(.failure(.workspaceNotOpen(doc)))
      }

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
      let doc = note.params.textDocument.uri
      guard let workspace = self.workspaceForDocument(uri: doc) else {
        return
      }

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
      for documentUri in self.documentManager.openDocuments {
        guard let workspace = self.workspaceForDocument(uri: documentUri) else {
          continue
        }
        guard workspace.documentService[documentUri] === languageService else {
          continue
        }
        guard let snapshot = self.documentManager.latestSnapshot(documentUri) else {
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
    guard let serverType = LanguageServerType(language: language) else {
      return nil
    }
    // Pick the first language service that can handle this workspace.
    for languageService in languageServices[serverType, default: []] {
      if languageService.canHandle(workspace: workspace) {
        return languageService
      }
    }

    // Start a new service.
    return orLog("failed to start language service", level: .error) {
      guard let service = try SourceKitLSP.languageService(
        for: toolchain, serverType, options: options, client: self, in: workspace, reopenDocuments: { [weak self] in self?.reopenDocuments(for: $0) })
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

      languageServices[serverType, default: []].append(service)
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
      for (uri, change) in changedFiles {
        // Non-ready documents should be considered open even though we haven't
        // opened it with the language service yet.
        guard self.documentManager.openDocuments.contains(uri) else { continue }

        guard let workspace = self.workspaceForDocument(uri: uri) else {
          continue
        }
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
      // Split the changedFiles into the workspaces they belong to.
      // Then invoke affectedOpenDocumentsForChangeSet for each workspace with its affected files.
      let changedFilesAndWorkspace = changedFiles.map({
        return (uri: $0, workspace: self.workspaceForDocument(uri: $0))
      })
      for workspace in self.workspaces {
        let changedFilesForWorkspace = Set(changedFilesAndWorkspace.filter({ $0.workspace === workspace }).map(\.uri))
        if changedFilesForWorkspace.isEmpty {
          continue
        }
        for uri in self.affectedOpenDocumentsForChangeSet(changedFilesForWorkspace, self.documentManager) {
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

  public func fileHandlingCapabilityChanged() {
    queue.async {
      self.uriToWorkspaceCache = [:]
    }
  }
}

// MARK: - Request and notification handling

extension SourceKitServer {

  // MARK: - General

  /// Creates a workspace at the given `uri`.
  private func workspace(uri: DocumentURI) -> Workspace? {
    guard let capabilityRegistry = capabilityRegistry else {
      log("Cannot open workspace before server is initialized")
      return nil
    }
    return try? Workspace(
      documentManager: self.documentManager,
      rootUri: uri,
      capabilityRegistry: capabilityRegistry,
      toolchainRegistry: self.toolchainRegistry,
      buildSetup: self.options.buildSetup,
      indexOptions: self.options.indexOptions)
  }

  func initialize(_ req: Request<InitializeRequest>) {
    if case .dictionary(let options) = req.params.initializationOptions {
      if case .bool(let listenToUnitEvents) = options["listenToUnitEvents"] {
        self.options.indexOptions.listenToUnitEvents = listenToUnitEvents
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

    capabilityRegistry = CapabilityRegistry(clientCapabilities: req.params.capabilities)

    // Any messages sent before initialize returns are expected to fail, so this will run before
    // the first "supported" request. Run asynchronously to hide the latency of setting up the
    // build system and index.
    queue.async {
      if let workspaceFolders = req.params.workspaceFolders {
        self.workspaces.append(contentsOf: workspaceFolders.compactMap({ self.workspace(uri: $0.uri) }))
      } else if let uri = req.params.rootURI {
        if let workspace = self.workspace(uri: uri) {
          self.workspaces.append(workspace)
        }
      } else if let path = req.params.rootPath {
        if let workspace = self.workspace(uri: DocumentURI(URL(fileURLWithPath: path))) {
          self.workspaces.append(workspace)
        }
      }

      if self.workspaces.isEmpty {
        log("no workspace found", level: .warning)

        let workspace = Workspace(
          documentManager: self.documentManager,
          rootUri: req.params.rootURI,
          capabilityRegistry: self.capabilityRegistry!,
          toolchainRegistry: self.toolchainRegistry,
          buildSetup: self.options.buildSetup,
          underlyingBuildSystem: nil,
          index: nil,
          indexDelegate: nil)
        self.workspaces.append(workspace)
      }

      assert(!self.workspaces.isEmpty)
      for workspace in self.workspaces {
        workspace.buildSystemManager.delegate = self
      }
    }

    req.reply(InitializeResult(capabilities:
      self.serverCapabilities(for: req.params.capabilities, registry: self.capabilityRegistry!)))
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
    let executeCommandOptions: ExecuteCommandOptions?
    if registry.clientHasDynamicExecuteCommandRegistration {
      executeCommandOptions = nil
    } else {
      executeCommandOptions = ExecuteCommandOptions(commands: builtinSwiftCommands)
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
      declarationProvider: .bool(true),
      executeCommandProvider: executeCommandOptions,
      workspace: WorkspaceServerCapabilities(workspaceFolders: .init(
        supported: true,
        changeNotifications: .bool(true)
      )),
      callHierarchyProvider: .bool(true),
      typeHierarchyProvider: .bool(true)
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
    if let inlayHintOptions = server.inlayHintProvider {
      registry.registerInlayHintIfNeeded(options: inlayHintOptions, for: languages) {
        self.dynamicallyRegisterCapability($0, registry)
      }
    }
    if let commandOptions = server.executeCommandProvider {
      registry.registerExecuteCommandIfNeeded(commands: commandOptions.commands) {
        self.dynamicallyRegisterCapability($0, registry)
      }
    }

    /// This must be a superset of the files that return true for SwiftPM's `Workspace.fileAffectsSwiftOrClangBuildSettings`.
    var watchers = FileRuleDescription.builtinRules.flatMap({ $0.fileTypes }).map { fileExtension in
      return FileSystemWatcher(globPattern: "**/*.\(fileExtension)", kind: [.create, .delete])
    }
    watchers.append(FileSystemWatcher(globPattern: "**/Package.swift", kind: [.change]))
    watchers.append(FileSystemWatcher(globPattern: "**/compile_commands.json", kind: [.create, .change, .delete]))
    watchers.append(FileSystemWatcher(globPattern: "**/compile_flags.txt", kind: [.create, .change, .delete]))
    registry.registerDidChangeWatchedFiles(watchers: watchers) {
      self.dynamicallyRegisterCapability($0, registry)
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
    dispatchPrecondition(condition: .onQueue(queue))
    // Note: this method should be safe to call multiple times, since we want to
    // be resilient against multiple possible shutdown sequences, including
    // pipe failure.

    // Close the index, which will flush to disk.
    for workspace in self.workspaces {
      workspace.buildSystemManager.mainFilesProvider = nil
      workspace.index = nil

      // Break retain cycle with the BSM.
      workspace.buildSystemManager.delegate = nil
    }
  }


  func shutdown(_ request: Request<ShutdownRequest>) {
    _prepareForExit()
    let shutdownGroup = DispatchGroup()
    for service in languageServices.values.flatMap({ $0 }) {
      shutdownGroup.enter()
      service.shutdown() {
        shutdownGroup.leave()
      }
    }
    languageServices = [:]
    // Wait for all services to shut down before sending the shutdown response.
    // Otherwise we might terminate sourcekit-lsp while it still has open
    // connections to the toolchain servers, which could send messages to
    // sourcekit-lsp while it is being deallocated, causing crashes.
    shutdownGroup.notify(queue: self.queue) {
      request.reply(VoidResponse())
    }
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

  func openDocument(_ note: Notification<DidOpenTextDocumentNotification>) {
    let uri = note.params.textDocument.uri
    guard let workspace = workspaceForDocument(uri: uri) else {
      log("received open notification for file '\(uri)' without a corresponding workspace, ignoring...", level: .error)
      return
    }
    openDocument(note.params, workspace: workspace)
  }

  private func openDocument(_ note: DidOpenTextDocumentNotification, workspace: Workspace) {
    // Immediately open the document even if the build system isn't ready. This is important since
    // we check that the document is open when we receive messages from the build system.
    documentManager.open(note)

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

  func closeDocument(_ note: Notification<DidCloseTextDocumentNotification>) {
    let uri = note.params.textDocument.uri
    guard let workspace = workspaceForDocument(uri: uri) else {
      log("received close notification for file '\(uri)' without a corresponding workspace, ignoring...", level: .error)
      return
    }
    self.closeDocument(note.params, workspace: workspace)
  }

  func closeDocument(_ note: DidCloseTextDocumentNotification, workspace: Workspace) {
    // Immediately close the document. We need to be sure to clear our pending work queue in case
    // the build system still isn't ready.
    documentManager.close(note)

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

  func changeDocument(_ note: Notification<DidChangeTextDocumentNotification>) {
    let uri = note.params.textDocument.uri

    guard let workspace = workspaceForDocument(uri: uri) else {
      log("received change notification for file '\(uri)' without a corresponding workspace, ignoring...", level: .error)
      return
    }

    // If the document is ready, we can handle the change right now.
    guard !documentsReady.contains(uri) else {
      documentManager.edit(note.params)
      workspace.documentService[uri]?.changeDocument(note.params)
      return
    }

    // Need to queue the change call so we can handle it when ready.
    self.documentToPendingQueue[uri, default: DocumentNotificationRequestQueue()].add(operation: {
      self.documentManager.edit(note.params)
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

  func didChangeWorkspaceFolders(_ note: Notification<DidChangeWorkspaceFoldersNotification>) {
    var preChangeWorkspaces: [DocumentURI: Workspace] = [:]
    for docUri in self.documentManager.openDocuments {
      preChangeWorkspaces[docUri] = self.workspaceForDocument(uri: docUri)
    }
    if let removed = note.params.event.removed {
      self.workspaces.removeAll { workspace in
        return removed.contains(where: { workspaceFolder in
          workspace.rootUri == workspaceFolder.uri
        })
      }
    }
    if let added = note.params.event.added {
      let newWorkspaces = added.compactMap({ self.workspace(uri: $0.uri) })
      for workspace in newWorkspaces {
        workspace.buildSystemManager.delegate = self
      }
      self.workspaces.append(contentsOf: newWorkspaces)
    }

    // For each document that has moved to a different workspace, close it in
    // the old workspace and open it in the new workspace.
    for docUri in self.documentManager.openDocuments {
      let oldWorkspace = preChangeWorkspaces[docUri]
      let newWorkspace = self.workspaceForDocument(uri: docUri)
      if newWorkspace !== oldWorkspace {
        guard let snapshot = documentManager.latestSnapshot(docUri) else {
          continue
        }
        if let oldWorkspace = oldWorkspace {
          self.closeDocument(DidCloseTextDocumentNotification(
            textDocument: TextDocumentIdentifier(docUri)
          ), workspace: oldWorkspace)
        }
        if let newWorkspace = newWorkspace {
          self.openDocument(DidOpenTextDocumentNotification(textDocument: TextDocumentItem(
            uri: docUri,
            language: snapshot.document.language,
            version: snapshot.version,
            text: snapshot.text
          )), workspace: newWorkspace)
        }
      }
    }
  }

  func didChangeWatchedFiles(_ note: Notification<DidChangeWatchedFilesNotification>) {
    dispatchPrecondition(condition: .onQueue(queue))
    // We can't make any assumptions about which file changes a particular build
    // system is interested in. Just because it doesn't have build settings for
    // a file doesn't mean a file can't affect the build system's build settings
    // (e.g. Package.swift doesn't have build settings but affects build
    // settings). Inform the build system about all file changes.
    for workspace in workspaces {
      workspace.buildSystemManager.filesDidChange(note.params.changes)
    }
  }

  // MARK: - Language features

  func completion(
    _ req: Request<CompletionRequest>,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) {
    languageService.completion(req)
  }
  
  func completionResolve(
    _ req: Request<CompletionItem>,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) {
    languageService.completionResolve(req)
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
    dispatchPrecondition(condition: .onQueue(queue))
    // Ignore short queries since they are:
    // - noisy and slow, since they can match many symbols
    // - normally unintentional, triggered when the user types slowly or if the editor doesn't
    //   debounce events while the user is typing
    guard matching.count >= minWorkspaceSymbolPatternLength else {
      return []
    }
    var symbolOccurenceResults: [SymbolOccurrence] = []
    for workspace in workspaces {
      workspace.index?.forEachCanonicalSymbolOccurrence(
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
    }
    return symbolOccurenceResults
  }

  /// Handle a workspace/symbol request, returning the SymbolInformation.
  /// - returns: An array with SymbolInformation for each matching symbol in the workspace.
  func workspaceSymbols(_ req: Request<WorkspaceSymbolsRequest>) {
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

  func documentSemanticTokens(
    _ req: Request<DocumentSemanticTokensRequest>,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) {
    languageService.documentSemanticTokens(req)
  }

  func documentSemanticTokensDelta(
    _ req: Request<DocumentSemanticTokensDeltaRequest>,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) {
    languageService.documentSemanticTokensDelta(req)
  }

  func documentSemanticTokensRange(
    _ req: Request<DocumentSemanticTokensRangeRequest>,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) {
    languageService.documentSemanticTokensRange(req)
  }

  func colorPresentation(
    _ req: Request<ColorPresentationRequest>,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) {
    languageService.colorPresentation(req)
  }

  func executeCommand(_ req: Request<ExecuteCommandRequest>) {
    guard let uri = req.params.textDocument?.uri else {
      log("attempted to perform executeCommand request without an url!", level: .error)
      req.reply(nil)
      return
    }
    guard let workspace = workspaceForDocument(uri: uri) else {
      req.reply(.failure(.workspaceNotOpen(uri)))
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

  func inlayHint(
    _ req: Request<InlayHintRequest>,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) {
    languageService.inlayHint(req)
  }

  /// Converts a location from the symbol index to an LSP location.
  /// 
  /// - Parameter location: The symbol index location
  /// - Returns: The LSP location
  private func indexToLSPLocation(_ location: SymbolLocation) -> Location? {
    guard !location.path.isEmpty else { return nil }
    return Location(
      uri: DocumentURI(URL(fileURLWithPath: location.path)),
      range: Range(Position(
        // 1-based -> 0-based
        // Note that we still use max(0, ...) as a fallback if the location is zero.
        line: max(0, location.line - 1),
        // FIXME: we need to convert the utf8/utf16 column, which may require reading the file!
        utf16index: max(0, location.utf8Column - 1)
      ))
    )
  }

  /// Extracts the locations of an indexed symbol's occurrences,
  /// e.g. for definition or reference lookups.
  /// 
  /// - Parameters:
  ///   - result: The symbol to look up
  ///   - index: The index in which the occurrences will be looked up
  ///   - useLocalFallback: Whether to consider the best known local declaration if no other locations are found
  ///   - extractOccurrences: A function fetching the occurrences by the desired roles given a usr from the index
  /// - Returns: The resolved symbol locations
  private func extractIndexedOccurrences(
    result: LSPResult<SymbolInfoRequest.Response>,
    index: IndexStoreDB?,
    useLocalFallback: Bool = false,
    extractOccurrences: (String, IndexStoreDB) -> [SymbolOccurrence]
  ) -> LSPResult<[(occurrence: SymbolOccurrence?, location: Location)]> {
    guard case .success(let symbols) = result else {
      return .failure(result.failure!)
    }

    guard let symbol = symbols.first else {
      return .success([])
    }

    let fallback: [(occurrence: SymbolOccurrence?, location: Location)]
    if useLocalFallback, let bestLocalDeclaration = symbol.bestLocalDeclaration {
      fallback = [(occurrence: nil, location: bestLocalDeclaration)]
    } else {
      fallback = []
    }

    guard let usr = symbol.usr, let index = index else {
      return .success(fallback)
    }

    let occurs = extractOccurrences(usr, index)
    let resolved = occurs.compactMap { occur in
      indexToLSPLocation(occur.location).map {
        (occurrence: occur, location: $0)
      }
    }

    return .success(resolved.isEmpty ? fallback : resolved)
  }

  func declaration(
    _ req: Request<DeclarationRequest>,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) {
    guard languageService.declaration(req) else {
      return req.reply(.locations([]))
    }
  }

  func definition(
    _ req: Request<DefinitionRequest>,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) {
    let symbolInfo = SymbolInfoRequest(textDocument: req.params.textDocument, position: req.params.position)
    let index = self.workspaceForDocument(uri: req.params.textDocument.uri)?.index
    let callback = callbackOnQueue(self.queue) { (result: LSPResult<SymbolInfoRequest.Response>) in
      let extractedResult = self.extractIndexedOccurrences(result: result, index: index, useLocalFallback: true) { (usr, index) in
        log("performing indexed jump-to-def with usr \(usr)")
        var occurs = index.occurrences(ofUSR: usr, roles: [.definition])
        if occurs.isEmpty {
          occurs = index.occurrences(ofUSR: usr, roles: [.declaration])
        }
        return occurs
      }

      switch extractedResult {
      case .success(let resolved):
        let locs = resolved.map(\.location)
        // If we're unable to handle the definition request using our index, see if the
        // language service can handle it (e.g. clangd can provide AST based definitions).
        guard locs.isEmpty else {
          req.reply(.locations(locs))
          return
        }
        let handled = languageService.definition(req)
        guard !handled else { return }
        req.reply(.locations([]))
      case .failure(let error):
        req.reply(.failure(error))
      }
    }
    let request = Request(symbolInfo, id: req.id, clientID: ObjectIdentifier(self),
                          cancellation: req.cancellationToken, reply: callback)
    languageService.symbolInfo(request)
  }

  func implementation(
    _ req: Request<ImplementationRequest>,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) {
    let symbolInfo = SymbolInfoRequest(textDocument: req.params.textDocument, position: req.params.position)
    let index = self.workspaceForDocument(uri: req.params.textDocument.uri)?.index
    let callback = callbackOnQueue(self.queue) { (result: LSPResult<SymbolInfoRequest.Response>) in
      let extractedResult = self.extractIndexedOccurrences(result: result, index: index) { (usr, index) in
        var occurs = index.occurrences(ofUSR: usr, roles: .baseOf)
        if occurs.isEmpty {
          occurs = index.occurrences(relatedToUSR: usr, roles: .overrideOf)
        }
        return occurs
      }

      req.reply(extractedResult.map { .locations($0.map(\.location)) })
    }
    let request = Request(symbolInfo, id: req.id, clientID: ObjectIdentifier(self),
                          cancellation: req.cancellationToken, reply: callback)
    languageService.symbolInfo(request)
  }

  func references(
    _ req: Request<ReferencesRequest>,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) {
    let symbolInfo = SymbolInfoRequest(textDocument: req.params.textDocument, position: req.params.position)
    let index = self.workspaceForDocument(uri: req.params.textDocument.uri)?.index
    let callback = callbackOnQueue(self.queue) { (result: LSPResult<SymbolInfoRequest.Response>) in
      let extractedResult = self.extractIndexedOccurrences(result: result, index: index) { (usr, index) in
        log("performing indexed jump-to-def with usr \(usr)")
        var roles: SymbolRole = [.reference]
        if req.params.context.includeDeclaration {
          roles.formUnion([.declaration, .definition])
        }
        return index.occurrences(ofUSR: usr, roles: roles)
      }

      req.reply(extractedResult.map { $0.map(\.location) })
    }
    let request = Request(symbolInfo, id: req.id, clientID: ObjectIdentifier(self),
                          cancellation: req.cancellationToken, reply: callback)
    languageService.symbolInfo(request)
  }

  private func indexToLSPCallHierarchyItem(
    symbol: Symbol,
    moduleName: String?,
    location: Location
  ) -> CallHierarchyItem {
    CallHierarchyItem(
      name: symbol.name,
      kind: symbol.kind.asLspSymbolKind(),
      tags: nil,
      detail: moduleName,
      uri: location.uri,
      range: location.range,
      selectionRange: location.range,
      // We encode usr and uri for incoming/outgoing call lookups in the implementation-specific data field
      data: .dictionary([
        "usr": .string(symbol.usr),
        "uri": .string(location.uri.stringValue),
      ])
    )
  }

  func prepareCallHierarchy(
    _ req: Request<CallHierarchyPrepareRequest>,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) {
    let symbolInfo = SymbolInfoRequest(textDocument: req.params.textDocument, position: req.params.position)
    let index = self.workspaceForDocument(uri: req.params.textDocument.uri)?.index
    let callback = callbackOnQueue(self.queue) { (result: LSPResult<SymbolInfoRequest.Response>) in
      // For call hierarchy preparation we only locate the definition
      let extractedResult = self.extractIndexedOccurrences(result: result, index: index) { (usr, index) in
        index.occurrences(ofUSR: usr, roles: [.definition, .declaration])
      }
      let items = extractedResult.map { resolved -> [CallHierarchyItem]? in
        resolved.compactMap { info -> CallHierarchyItem? in
          guard let occurrence = info.occurrence else {
            return nil
          }
          let symbol = occurrence.symbol
          return self.indexToLSPCallHierarchyItem(
            symbol: symbol,
            moduleName: occurrence.location.moduleName,
            location: info.location
          )
        }
      }
      req.reply(items)
    }
    let request = Request(symbolInfo, id: req.id, clientID: ObjectIdentifier(self),
                          cancellation: req.cancellationToken, reply: callback)
    languageService.symbolInfo(request)
  }

  /// Extracts our implementation-specific data about a call hierarchy
  /// item as encoded in `indexToLSPCallHierarchyItem`.
  /// 
  /// - Parameter data: The opaque data structure to extract
  /// - Returns: The extracted data if successful or nil otherwise
  private func extractCallHierarchyItemData(_ rawData: LSPAny?) -> (uri: DocumentURI, usr: String)? {
    guard case let .dictionary(data) = rawData,
          case let .string(uriString) = data["uri"],
          case let .string(usr) = data["usr"] else {
      return nil
    }
    return (
      uri: DocumentURI(string: uriString),
      usr: usr
    )
  }

  func incomingCalls(_ req: Request<CallHierarchyIncomingCallsRequest>) {
    guard let data = extractCallHierarchyItemData(req.params.item.data),
          let index = self.workspaceForDocument(uri: data.uri)?.index else {
      req.reply([])
      return
    }
    let occurs = index.occurrences(ofUSR: data.usr, roles: .calledBy)
    let calls = occurs.compactMap { occurrence -> CallHierarchyIncomingCall? in
      guard let location = indexToLSPLocation(occurrence.location),
            let related = occurrence.relations.first else {
        return nil
      }

      // Resolve the caller's definition to find its location
      let definition = index.occurrences(ofUSR: related.symbol.usr, roles: [.definition, .declaration]).first
      let definitionSymbolLocation = definition?.location
      let definitionLocation = definitionSymbolLocation.flatMap(indexToLSPLocation)

      return CallHierarchyIncomingCall(
        from: indexToLSPCallHierarchyItem(
          symbol: related.symbol,
          moduleName: definitionSymbolLocation?.moduleName,
          location: definitionLocation ?? location // Use occurrence location as fallback
        ),
        fromRanges: [location.range]
      )
    }
    req.reply(calls)
  }

  func outgoingCalls(_ req: Request<CallHierarchyOutgoingCallsRequest>) {
    guard let data = extractCallHierarchyItemData(req.params.item.data),
          let index = self.workspaceForDocument(uri: data.uri)?.index else {
      req.reply([])
      return
    }
    let occurs = index.occurrences(relatedToUSR: data.usr, roles: .calledBy)
    let calls = occurs.compactMap { occurrence -> CallHierarchyOutgoingCall? in
      guard let location = indexToLSPLocation(occurrence.location) else {
        return nil
      }

      // Resolve the callee's definition to find its location
      let definition = index.occurrences(ofUSR: occurrence.symbol.usr, roles: [.definition, .declaration]).first
      let definitionSymbolLocation = definition?.location
      let definitionLocation = definitionSymbolLocation.flatMap(indexToLSPLocation)

      return CallHierarchyOutgoingCall(
        to: indexToLSPCallHierarchyItem(
          symbol: occurrence.symbol,
          moduleName: definitionSymbolLocation?.moduleName,
          location: definitionLocation ?? location // Use occurrence location as fallback
        ),
        fromRanges: [location.range]
      )
    }
    req.reply(calls)
  }

  private func indexToLSPTypeHierarchyItem(
    symbol: Symbol,
    moduleName: String?,
    location: Location,
    index: IndexStoreDB
  ) -> TypeHierarchyItem {
    let name: String
    let detail: String?

    switch symbol.kind {
    case .extension:
      // Query the conformance added by this extension
      let conformances = index.occurrences(relatedToUSR: symbol.usr, roles: .baseOf)
      if conformances.isEmpty {
        name = symbol.name
      } else {
        name = "\(symbol.name): \(conformances.map(\.symbol.name).joined(separator: ", "))"
      }
      // Add the file name and line to the detail string
      if let url = location.uri.fileURL {
        detail = "Extension at \(AbsolutePath(url.path).basename):\(location.range.lowerBound.line + 1)"
      } else if let moduleName = moduleName {
        detail = "Extension in \(moduleName)"
      } else {
        detail = "Extension"
      }
    default:
      name = symbol.name
      detail = moduleName
    }

    return TypeHierarchyItem(
      name: name,
      kind: symbol.kind.asLspSymbolKind(),
      tags: nil,
      detail: detail,
      uri: location.uri,
      range: location.range,
      selectionRange: location.range,
      // We encode usr and uri for incoming/outgoing type lookups in the implementation-specific data field
      data: .dictionary([
        "usr": .string(symbol.usr),
        "uri": .string(location.uri.stringValue),
      ])
    )
  }

  func prepareTypeHierarchy(
    _ req: Request<TypeHierarchyPrepareRequest>,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) {
    let symbolInfo = SymbolInfoRequest(textDocument: req.params.textDocument, position: req.params.position)
    guard let index = self.workspaceForDocument(uri: req.params.textDocument.uri)?.index else {
      req.reply([])
      return
    }
    let callback = callbackOnQueue(self.queue) { (result: LSPResult<SymbolInfoRequest.Response>) in
      // For type hierarchy preparation we only locate the definition
      let extractedResult = self.extractIndexedOccurrences(result: result, index: index) { (usr, index) in
        index.occurrences(ofUSR: usr, roles: [.definition, .declaration])
      }
      let items = extractedResult.map { resolved -> [TypeHierarchyItem]? in
        resolved.compactMap { info -> TypeHierarchyItem? in
          guard let occurrence = info.occurrence else {
            return nil
          }
          let symbol = occurrence.symbol
          return self.indexToLSPTypeHierarchyItem(
            symbol: symbol,
            moduleName: occurrence.location.moduleName,
            location: info.location,
            index: index
          )
        }
      }
      req.reply(items)
    }
    let request = Request(symbolInfo, id: req.id, clientID: ObjectIdentifier(self),
                          cancellation: req.cancellationToken, reply: callback)
    languageService.symbolInfo(request)
  }

  /// Extracts our implementation-specific data about a type hierarchy
  /// item as encoded in `indexToLSPTypeHierarchyItem`.
  /// 
  /// - Parameter data: The opaque data structure to extract
  /// - Returns: The extracted data if successful or nil otherwise
  private func extractTypeHierarchyItemData(_ rawData: LSPAny?) -> (uri: DocumentURI, usr: String)? {
    guard case let .dictionary(data) = rawData,
          case let .string(uriString) = data["uri"],
          case let .string(usr) = data["usr"] else {
      return nil
    }
    return (
      uri: DocumentURI(string: uriString),
      usr: usr
    )
  }

  func supertypes(_ req: Request<TypeHierarchySupertypesRequest>) {
    guard let data = extractTypeHierarchyItemData(req.params.item.data),
          let index = self.workspaceForDocument(uri: data.uri)?.index else {
      req.reply([])
      return
    }

    // Resolve base types
    let baseOccurs = index.occurrences(relatedToUSR: data.usr, roles: .baseOf)

    // Resolve retroactive conformances via the extensions
    let extensions = index.occurrences(ofUSR: data.usr, roles: .extendedBy)
    let retroactiveConformanceOccurs = extensions.flatMap { occurrence -> [SymbolOccurrence] in
      guard let related = occurrence.relations.first else {
        return []
      }
      return index.occurrences(relatedToUSR: related.symbol.usr, roles: .baseOf)
    }

    // Convert occurrences to type hierarchy items
    let occurs = baseOccurs + retroactiveConformanceOccurs
    let types = occurs.compactMap { occurrence -> TypeHierarchyItem? in
      guard let location = indexToLSPLocation(occurrence.location) else {
        return nil
      }

      // Resolve the supertype's definition to find its location
      let definition = index.occurrences(ofUSR: occurrence.symbol.usr, roles: [.definition, .declaration]).first
      let definitionSymbolLocation = definition?.location
      let definitionLocation = definitionSymbolLocation.flatMap(indexToLSPLocation)

      return indexToLSPTypeHierarchyItem(
        symbol: occurrence.symbol,
        moduleName: definitionSymbolLocation?.moduleName,
        location: definitionLocation ?? location, // Use occurrence location as fallback
        index: index
      )
    }
    req.reply(types)
  }

  func subtypes(_ req: Request<TypeHierarchySubtypesRequest>) {
    guard let data = extractTypeHierarchyItemData(req.params.item.data),
          let index = self.workspaceForDocument(uri: data.uri)?.index else {
      req.reply([])
      return
    }

    // Resolve child types and extensions
    let occurs = index.occurrences(ofUSR: data.usr, roles: [.baseOf, .extendedBy])

    // Convert occurrences to type hierarchy items
    let types = occurs.compactMap { occurrence -> TypeHierarchyItem? in
      guard let location = indexToLSPLocation(occurrence.location),
            let related = occurrence.relations.first else {
        return nil
      }

      // Resolve the subtype's definition to find its location
      let definition = index.occurrences(ofUSR: related.symbol.usr, roles: [.definition, .declaration]).first
      let definitionSymbolLocation = definition.map(\.location)
      let definitionLocation = definitionSymbolLocation.flatMap(indexToLSPLocation)

      return indexToLSPTypeHierarchyItem(
        symbol: related.symbol,
        moduleName: definitionSymbolLocation?.moduleName,
        location: definitionLocation ?? location, // Use occurrence location as fallback
        index: index
      )
    }
    req.reply(types)
  }

  func pollIndex(_ req: Request<PollIndexRequest>) {
    for workspace in workspaces {
      workspace.index?.pollForUnitChangesAndWait()
    }
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
func languageService(
  for toolchain: Toolchain,
  _ languageServerType: LanguageServerType,
  options: SourceKitServer.Options,
  client: MessageHandler,
  in workspace: Workspace,
  reopenDocuments: @escaping (ToolchainLanguageServer) -> Void
) throws -> ToolchainLanguageServer? {
  let connectionToClient = LocalConnection()

  let server = try languageServerType.serverType.init(
    client: connectionToClient,
    toolchain: toolchain,
    clientCapabilities: workspace.capabilityRegistry.clientCapabilities,
    options: options,
    workspace: workspace,
    reopenDocuments: reopenDocuments
  )
  connectionToClient.start(handler: client)
  return server
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
