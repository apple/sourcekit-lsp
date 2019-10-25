//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SKSupport
import SKCore
import TSCBasic
import LanguageServerProtocol
import LanguageServerProtocolJSONRPC
import Foundation

/// A thin wrapper over a connection to a clangd server providing build setting handling.
final class ClangLanguageServerShim: ToolchainLanguageServer {

  /// The server's request queue, used to serialize requests and responses to `clangd`.
  public let queue: DispatchQueue = DispatchQueue(label: "clangd-language-server-queue", qos: .userInitiated)

  let clangd: Connection

  var capabilities: ServerCapabilities? = nil

  let clang: AbsolutePath?

  /// Creates a language server for the given client using the sourcekitd dylib at the specified path.
  public init(client: Connection, clangd: Connection, clang: AbsolutePath?) throws {
    self.clangd = clangd
    self.clang = clang
  }

  /// Forwards a request to the given connection, taking care of replying to the original request
  /// and cancellation, while providing a callback with the response for additional processing.
  ///
  /// Immediately after `handler` returns, this passes the result to the original reply handler by
  /// calling `request.reply(result)`.
  ///
  /// The cancellation token from the original request is automatically linked to the forwarded
  /// request such that cancelling the original request will cancel the forwarded request.
  ///
  /// - Parameters:
  ///   - request: The request to forward.
  ///   - to: Where to forward the request (e.g. self.clangd).
  ///   - handler: An optional closure that will be called with the result of the request.
  func forwardRequest<R>(
    _ request: Request<R>,
    to: Connection,
    _ handler: ((LSPResult<R.Response>) -> Void)? = nil)
  {
    let id = to.send(request.params, queue: queue) { result in
      handler?(result)
      request.reply(result)
    }
    request.cancellationToken.addCancellationHandler {
      to.send(CancelRequest(id: id))
    }
  }
}

// MARK: - Request and notification handling

extension ClangLanguageServerShim {

  // MARK: - Lifetime

  func initializeSync(_ initialize: InitializeRequest) throws -> InitializeResult {
    let result = try clangd.sendSync(initialize)
    self.capabilities = result.capabilities
    return result
  }

  public func clientInitialized(_ initialized: InitializedNotification) {
    clangd.send(initialized)
  }

  // MARK: - Build System Interactions

  public func documentChangedBuildSettings(_ url: URL, _ change: FileBuildSettingsChange) {
    let buildSettings = change.newFileBuildSettings

    logAsync(level: buildSettings == nil ? .warning : .debug) { _ in
      let settingsStr = buildSettings == nil ? "nil" : buildSettings!.compilerArguments.description
      return "settings for \(url): \(settingsStr)"
    }

    if let settings = buildSettings {
      clangd.send(DidChangeConfiguration(settings: .clangd(
        ClangWorkspaceSettings(
          compilationDatabaseChanges: [url.path: ClangCompileCommand(settings, clang: clang)]))))
    }
  }

  // MARK: - Text synchronization

  public func openDocument(_ note: DidOpenTextDocument) {
    clangd.send(note)
  }

  public func closeDocument(_ note: DidCloseTextDocument) {
    clangd.send(note)
  }

  public func changeDocument(_ note: DidChangeTextDocument) {
    clangd.send(note)
  }

  public func willSaveDocument(_ note: WillSaveTextDocument) {

  }

  public func didSaveDocument(_ note: DidSaveTextDocument) {

  }

  // MARK: - Text Document

  func completion(_ req: Request<CompletionRequest>) {
    forwardRequest(req, to: clangd)
  }

  func hover(_ req: Request<HoverRequest>) {
    forwardRequest(req, to: clangd)
  }

  func symbolInfo(_ req: Request<SymbolInfoRequest>) {
    forwardRequest(req, to: clangd)
  }

  func documentSymbolHighlight(_ req: Request<DocumentHighlightRequest>) {
    forwardRequest(req, to: clangd)
  }

  func documentSymbol(_ req: Request<DocumentSymbolRequest>) {
    forwardRequest(req, to: clangd)
  }

  func documentColor(_ req: Request<DocumentColorRequest>) {
    forwardRequest(req, to: clangd)
  }

  func colorPresentation(_ req: Request<ColorPresentationRequest>) {
    forwardRequest(req, to: clangd)
  }

  func codeAction(_ req: Request<CodeActionRequest>) {
    forwardRequest(req, to: clangd)
  }

  func foldingRange(_ req: Request<FoldingRangeRequest>) {
    if capabilities?.foldingRangeProvider == true {
      forwardRequest(req, to: clangd)
    } else {
      req.reply(.success(nil))
    }
  }

  // MARK: - Other

  func executeCommand(_ req: Request<ExecuteCommandRequest>) {
    //TODO: Implement commands.
    return req.reply(nil)
  }
}

func makeJSONRPCClangServer(
  client: MessageHandler,
  toolchain: Toolchain,
  clangdOptions: [String]
) throws -> ToolchainLanguageServer {
  guard let clangd = toolchain.clangd else {
    preconditionFailure("missing clang from toolchain \(toolchain.identifier)")
  }

  let clientToServer: Pipe = Pipe()
  let serverToClient: Pipe = Pipe()

  let connection = JSONRPCConection(
    protocol: MessageRegistry.lspProtocol,
    inFD: serverToClient.fileHandleForReading.fileDescriptor,
    outFD: clientToServer.fileHandleForWriting.fileDescriptor
  )

  let connectionToClient = LocalConnection()

  let shim = try ClangLanguageServerShim(
    client: connectionToClient,
    clangd: connection,
    clang: toolchain.clang)

  connectionToClient.start(handler: client)
  connection.start(receiveHandler: client)

  let process = Foundation.Process()

  if #available(OSX 10.13, *) {
    process.executableURL = clangd.asURL
  } else {
    process.launchPath = clangd.pathString
  }

  process.arguments = [
    "-compile_args_from=lsp", // Provide compiler args programmatically.
  ] + clangdOptions

  process.standardOutput = serverToClient
  process.standardInput = clientToServer
  process.terminationHandler = { process in
    log("clangd exited: \(process.terminationReason) \(process.terminationStatus)")
    connection.close()
  }

  if #available(OSX 10.13, *) {
    try process.run()
  } else {
    process.launch()
  }

  return shim
}

extension ClangCompileCommand {
  init(_ settings: FileBuildSettings, clang: AbsolutePath?) {
    // Clang expects the first argument to be the program name, like argv.
    self.init(
      compilationCommand: [clang?.pathString ?? "clang"] + settings.compilerArguments,
      workingDirectory: settings.workingDirectory ?? "")
  }
}
