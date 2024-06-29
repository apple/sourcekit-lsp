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

import Foundation
import LSPLogging
import LanguageServerProtocol
import SKSupport
import SwiftExtensions

/// Represents a single `WorkDoneProgress` task that gets communicated with the client.
///
/// The work done progress is started when the object is created and ended when the object is destroyed.
/// In between, updates can be sent to the client.
actor WorkDoneProgressManager {
  private enum Status: Equatable {
    case inProgress(message: String?, percentage: Int?)
    case done
  }

  /// The token with which the work done progress has been created. `nil` if no work done progress has been created yet,
  /// either because we didn't send the `WorkDoneProgress` request yet, because the work done progress creation failed,
  /// or because the work done progress has been ended.
  private var token: ProgressToken?

  /// The queue on which progress updates are sent to the client.
  private let progressUpdateQueue = AsyncQueue<Serial>()

  private weak var server: SourceKitLSPServer?

  /// A string with which the `token` of the generated `WorkDoneProgress` sent to the client starts.
  ///
  /// A UUID will be appended to this prefix to make the token unique. The token prefix can be used to classify the work
  /// done progress into a category, which makes debugging easier because the tokens have semantic meaning and also
  /// allows clients to interpret what the `WorkDoneProgress` represents (for example Swift for VS Code explicitly
  /// recognizes work done progress that indicates that sourcekitd has crashed to offer a diagnostic bundle to be
  /// generated).
  private let tokenPrefix: String

  private let title: String

  /// The next status that should be sent to the client by `sendProgressUpdateImpl`.
  ///
  /// While progress updates are being queued in `progressUpdateQueue` this status can evolve. The next
  /// `sendProgressUpdateImpl` call will pick up the latest status.
  ///
  /// For example, if we receive two update calls to 25% and 50% in quick succession the `sendProgressUpdateImpl`
  /// scheduled from the 25% update will already pick up the new 50% status. The `sendProgressUpdateImpl` call scheduled
  /// from the 50% update will then realize that the `lastStatus` is already up-to-date and be a no-op.
  private var pendingStatus: Status

  /// The last status that was sent to the client. Used so we don't send no-op updates to the client.
  private var lastStatus: Status? = nil

  /// Needed to work around rdar://116221716
  private static func getServerCapabilityRegistry(_ server: SourceKitLSPServer) async -> CapabilityRegistry? {
    return await server.capabilityRegistry
  }

  init?(
    server: SourceKitLSPServer,
    tokenPrefix: String,
    initialDebounce: Duration? = nil,
    title: String,
    message: String? = nil,
    percentage: Int? = nil
  ) async {
    guard let capabilityRegistry = await Self.getServerCapabilityRegistry(server) else {
      return nil
    }
    self.init(
      server: server,
      capabilityRegistry: capabilityRegistry,
      tokenPrefix: tokenPrefix,
      initialDebounce: initialDebounce,
      title: title,
      message: message,
      percentage: percentage
    )
  }

  init?(
    server: SourceKitLSPServer,
    capabilityRegistry: CapabilityRegistry,
    tokenPrefix: String,
    initialDebounce: Duration? = nil,
    title: String,
    message: String? = nil,
    percentage: Int? = nil
  ) {
    guard capabilityRegistry.clientCapabilities.window?.workDoneProgress ?? false else {
      return nil
    }
    self.tokenPrefix = tokenPrefix
    self.server = server
    self.title = title
    self.pendingStatus = .inProgress(message: message, percentage: percentage)
    progressUpdateQueue.async {
      if let initialDebounce {
        try? await Task.sleep(for: initialDebounce)
      }
      await self.sendProgressUpdateAssumingOnProgressUpdateQueue()
    }
  }

  /// Send the necessary messages to the client to update the work done progress to `status`.
  ///
  /// Must be called on `progressUpdateQueue`
  private func sendProgressUpdateAssumingOnProgressUpdateQueue() async {
    let statusToSend = pendingStatus
    guard statusToSend != lastStatus else {
      return
    }
    guard let server else {
      // SourceKitLSPServer has been destroyed, we don't have a way to send notifications to the client anymore.
      return
    }
    await server.waitUntilInitialized()
    switch statusToSend {
    case .inProgress(message: let message, percentage: let percentage):
      if let token {
        server.sendNotificationToClient(
          WorkDoneProgress(
            token: token,
            value: .report(WorkDoneProgressReport(cancellable: false, message: message, percentage: percentage))
          )
        )
      } else {
        let token = ProgressToken.string("\(tokenPrefix).\(UUID().uuidString)")
        do {
          _ = try await server.client.send(CreateWorkDoneProgressRequest(token: token))
        } catch {
          return
        }
        server.sendNotificationToClient(
          WorkDoneProgress(
            token: token,
            value: .begin(WorkDoneProgressBegin(title: title, message: message, percentage: percentage))
          )
        )
        self.token = token
      }
    case .done:
      if let token {
        server.sendNotificationToClient(WorkDoneProgress(token: token, value: .end(WorkDoneProgressEnd())))
        self.token = nil
      }
    }
    lastStatus = statusToSend
  }

  func update(message: String? = nil, percentage: Int? = nil) {
    pendingStatus = .inProgress(message: message, percentage: percentage)
    progressUpdateQueue.async {
      await self.sendProgressUpdateAssumingOnProgressUpdateQueue()
    }
  }

  /// Ends the work done progress. Any further update calls are no-ops.
  ///
  /// `end` must be should be called before the `WorkDoneProgressManager` is deallocated.
  func end() {
    pendingStatus = .done
    progressUpdateQueue.async {
      await self.sendProgressUpdateAssumingOnProgressUpdateQueue()
    }
  }

  deinit {
    if pendingStatus != .done {
      // If there is still a pending work done progress, end it. We know that we don't have any pending updates on
      // `progressUpdateQueue` because they would capture `self` strongly and thus we wouldn't be deallocating this
      // object.
      // This is a fallback logic to ensure we don't leave pending work done progresses in the editor if the
      // `WorkDoneProgressManager` is destroyed without a call to `end` (eg. because its owning object is destroyed).
      // Calling `end()` is preferred because it ends the work done progress even if there are pending status updates
      // in `progressUpdateQueue`, which keep the `WorkDoneProgressManager` alive and thus prevent the work done
      // progress to be implicitly ended by the deinitializer.
      if let token {
        server?.sendNotificationToClient(WorkDoneProgress(token: token, value: .end(WorkDoneProgressEnd())))
      }
    }
  }
}

/// A `WorkDoneProgressManager` that essentially has two states. If any operation tracked by this type is currently
/// running, it displays a work done progress in the client. If multiple operations are running at the same time, it
/// doesn't show multiple work done progress in the client. For example, we only want to show one progress indicator
/// when sourcekitd has crashed, not one per `SwiftLanguageService`.
actor SharedWorkDoneProgressManager {
  private weak var sourceKitLSPServer: SourceKitLSPServer?

  /// The number of in-progress operations. When greater than 0 `workDoneProgress` non-nil and a work done progress is
  /// displayed to the user.
  private var inProgressOperations = 0
  private var workDoneProgress: WorkDoneProgressManager?

  private let tokenPrefix: String
  private let title: String
  private let message: String?

  public init(
    sourceKitLSPServer: SourceKitLSPServer,
    tokenPrefix: String,
    title: String,
    message: String? = nil
  ) {
    self.sourceKitLSPServer = sourceKitLSPServer
    self.tokenPrefix = tokenPrefix
    self.title = title
    self.message = message
  }

  func start() async {
    guard let sourceKitLSPServer else {
      return
    }
    // Do all asynchronous operations up-front so that incrementing `inProgressOperations` and setting `workDoneProgress`
    // cannot be interrupted by an `await` call
    let initialDebounceDuration = await sourceKitLSPServer.options.workDoneProgressDebounceDurationOrDefault
    let capabilityRegistry = await sourceKitLSPServer.capabilityRegistry

    inProgressOperations += 1
    if let capabilityRegistry, workDoneProgress == nil {
      workDoneProgress = WorkDoneProgressManager(
        server: sourceKitLSPServer,
        capabilityRegistry: capabilityRegistry,
        tokenPrefix: tokenPrefix,
        initialDebounce: initialDebounceDuration,
        title: title,
        message: message
      )
    }
  }

  func end() async {
    if inProgressOperations > 0 {
      inProgressOperations -= 1
    } else {
      logger.fault(
        "Unbalanced calls to SharedWorkDoneProgressManager.start and end for \(self.tokenPrefix, privacy: .public)"
      )
    }
    if inProgressOperations == 0, let workDoneProgress {
      self.workDoneProgress = nil
      await workDoneProgress.end()
    }
  }
}
