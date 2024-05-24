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

import LanguageServerProtocol
import SKCore
import SKSupport
import SemanticIndex

/// Listens for index status updates from `SemanticIndexManagers`. From that information, it manages a
/// `WorkDoneProgress` that communicates the index progress to the editor.
actor IndexProgressManager {
  /// A queue on which `indexTaskWasQueued` and `indexStatusDidChange` are handled.
  ///
  /// This allows the two functions two be `nonisolated` (and eg. the caller of `indexStatusDidChange` doesn't have to
  /// wait for the work done progress to be updated) while still guaranteeing that there is only one
  /// `indexStatusDidChangeImpl` running at a time, preventing race conditions that would cause two
  /// `WorkDoneProgressManager`s to be created.
  private let queue = AsyncQueue<Serial>()

  /// The `SourceKitLSPServer` for which this manages the index progress. It gathers all `SemanticIndexManagers` from
  /// the workspaces in the `SourceKitLSPServer`.
  private weak var sourceKitLSPServer: SourceKitLSPServer?

  /// This is the target number of index tasks (eg. the `3` in `1/3 done`).
  ///
  /// Every time a new index task is scheduled, this number gets incremented, so that it only ever increases.
  /// When indexing of one session is done (ie. when there are no more `scheduled` or `executing` tasks in any
  /// `SemanticIndexManager`), `queuedIndexTasks` gets reset to 0 and the work done progress gets ended.
  /// This way, when the next work done progress is started, it starts at zero again.
  ///
  /// The number of outstanding tasks is determined from the `scheduled` and `executing` tasks in all the
  /// `SemanticIndexManager`s.
  ///
  /// Note that the `queuedIndexTasks` might exceed the number of files in the project, eg. in the following scenario:
  /// - Schedule indexing of A.swift and B.swift -> 0 / 2
  /// - Indexing of A.swift finishes -> 1 / 2
  /// - A.swift is modified and should be indexed again -> 1 / 3
  /// - B.swift finishes indexing -> 2 / 3
  /// - A.swift finishes indexing for the second time -> 3 / 3 -> Status disappears
  private var queuedIndexTasks = 0

  /// While there are ongoing index tasks, a `WorkDoneProgressManager` that displays the work done progress.
  private var workDoneProgress: WorkDoneProgressManager?

  init(sourceKitLSPServer: SourceKitLSPServer) {
    self.sourceKitLSPServer = sourceKitLSPServer
  }

  /// Called when a new file is scheduled to be indexed. Increments the target index count, eg. the 3 in `1/3`.
  nonisolated func indexTasksWereScheduled(count: Int) {
    queue.async {
      await self.indexTasksWereScheduledImpl(count: count)
    }
  }

  private func indexTasksWereScheduledImpl(count: Int) async {
    queuedIndexTasks += count
    await indexStatusDidChangeImpl()
  }

  /// Called when a `SemanticIndexManager` finishes indexing a file. Adjusts the done index count, eg. the 1 in `1/3`.
  nonisolated func indexStatusDidChange() {
    queue.async {
      await self.indexStatusDidChangeImpl()
    }
  }

  private func indexStatusDidChangeImpl() async {
    guard let sourceKitLSPServer else {
      workDoneProgress = nil
      return
    }
    var isGeneratingBuildGraph = false
    var indexTasks: [DocumentURI: IndexTaskStatus] = [:]
    var preparationTasks: [ConfiguredTarget: IndexTaskStatus] = [:]
    for indexManager in await sourceKitLSPServer.workspaces.compactMap({ $0.semanticIndexManager }) {
      let inProgress = await indexManager.inProgressTasks
      isGeneratingBuildGraph = isGeneratingBuildGraph || inProgress.isGeneratingBuildGraph
      indexTasks.merge(inProgress.indexTasks) { lhs, rhs in
        return max(lhs, rhs)
      }
      preparationTasks.merge(inProgress.preparationTasks) { lhs, rhs in
        return max(lhs, rhs)
      }
    }

    if indexTasks.isEmpty && !isGeneratingBuildGraph {
      // Nothing left to index. Reset the target count and dismiss the work done progress.
      queuedIndexTasks = 0
      workDoneProgress = nil
      return
    }

    // We can get into a situation where queuedIndexTasks < indexTasks.count if we haven't processed all
    // `indexTasksWereScheduled` calls yet but the semantic index managers already track them in their in-progress tasks.
    // Clip the finished tasks to 0 because showing a negative number there looks stupid.
    let finishedTasks = max(queuedIndexTasks - indexTasks.count, 0)
    var message: String
    if isGeneratingBuildGraph {
      message = "Generating build graph"
    } else {
      message = "\(finishedTasks) / \(queuedIndexTasks)"
    }

    if await sourceKitLSPServer.options.indexOptions.showActivePreparationTasksInProgress {
      var inProgressTasks: [String] = []
      if isGeneratingBuildGraph {
        inProgressTasks.append("- Generating build graph")
      }
      inProgressTasks += preparationTasks.filter { $0.value == .executing }
        .map { "- Preparing \($0.key.targetID)" }
        .sorted()
      inProgressTasks += indexTasks.filter { $0.value == .executing }
        .map { "- Indexing \($0.key.fileURL?.lastPathComponent ?? $0.key.pseudoPath)" }
        .sorted()

      message += "\n\n" + inProgressTasks.joined(separator: "\n")
    }

    let percentage: Int
    if queuedIndexTasks != 0 {
      percentage = Int(Double(finishedTasks) / Double(queuedIndexTasks) * 100)
    } else {
      percentage = 0
    }
    if let workDoneProgress {
      workDoneProgress.update(message: message, percentage: percentage)
    } else {
      workDoneProgress = await WorkDoneProgressManager(
        server: sourceKitLSPServer,
        title: "Indexing",
        message: message,
        percentage: percentage
      )
    }
  }
}
