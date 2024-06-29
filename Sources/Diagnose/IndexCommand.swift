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

import ArgumentParser
import Foundation
import InProcessClient
import LanguageServerProtocol
import SKCore
import SKSupport
import SourceKitLSP
import SwiftExtensions

import struct TSCBasic.AbsolutePath
import class TSCBasic.Process
import class TSCUtility.PercentProgressAnimation

private actor IndexLogMessageHandler: MessageHandler {
  var hasSeenError: Bool = false

  /// Queue to ensure that we don't have two interleaving `print` calls.
  let queue = AsyncQueue<Serial>()

  nonisolated func handle(_ notification: some NotificationType) {
    if let notification = notification as? LogMessageNotification {
      queue.async {
        await self.handle(notification)
      }
    }
  }

  func handle(_ notification: LogMessageNotification) {
    self.hasSeenError = notification.type == .warning
    print(notification.message)
  }

  nonisolated func handle<Request: RequestType>(
    _ request: Request,
    id: RequestID,
    reply: @escaping @Sendable (LSPResult<Request.Response>) -> Void
  ) {
    reply(.failure(.methodNotFound(Request.method)))
  }

}

public struct IndexCommand: AsyncParsableCommand {
  public static let configuration: CommandConfiguration = CommandConfiguration(
    commandName: "index",
    abstract: "Index a project and print all the processes executed for it as well as their outputs"
  )

  @Option(
    name: .customLong("toolchain"),
    help: """
      The toolchain used to reduce the sourcekitd issue. \
      If not specified, the toolchain is found in the same way that sourcekit-lsp finds it
      """
  )
  var toolchainOverride: String?

  @Option(
    name: .customLong("experimental-index-feature"),
    help: """
      Enable an experimental sourcekit-lsp feature.
      Available features are: \(ExperimentalFeature.allCases.map(\.rawValue).joined(separator: ", "))
      """
  )
  var experimentalFeatures: [ExperimentalFeature] = []

  @Option(help: "The path to the project that should be indexed")
  var project: String

  public init() {}

  public func run() async throws {
    let options = SourceKitLSPOptions(
      backgroundIndexing: true,
      experimentalFeatures: Set(experimentalFeatures)
    )

    let installPath =
      if let toolchainOverride, let toolchain = Toolchain(try AbsolutePath(validating: toolchainOverride)) {
        toolchain.path
      } else {
        try AbsolutePath(validating: Bundle.main.bundlePath)
      }

    let messageHandler = IndexLogMessageHandler()
    let inProcessClient = try await InProcessSourceKitLSPClient(
      toolchainRegistry: ToolchainRegistry(installPath: installPath),
      options: options,
      workspaceFolders: [WorkspaceFolder(uri: DocumentURI(URL(fileURLWithPath: project)))],
      messageHandler: messageHandler
    )
    let start = ContinuousClock.now
    _ = try await inProcessClient.send(PollIndexRequest())
    print("Indexing finished in \(start.duration(to: .now))")
    if await messageHandler.hasSeenError {
      throw ExitCode(1)
    }
  }
}

fileprivate extension SourceKitLSPServer {
  func handle<R: RequestType>(_ request: R, requestID: RequestID) async throws -> R.Response {
    return try await withCheckedThrowingContinuation { continuation in
      self.handle(request, id: requestID) { result in
        continuation.resume(with: result)
      }
    }
  }
}

#if compiler(>=6)
extension ExperimentalFeature: @retroactive ExpressibleByArgument {}
#else
extension ExperimentalFeature: ExpressibleByArgument {}
#endif
