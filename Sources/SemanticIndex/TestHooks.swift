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

/// Callbacks that allow inspection of internal state modifications during testing.
public struct IndexTestHooks: Sendable {
  public var buildGraphGenerationDidStart: (@Sendable () async -> Void)?

  public var buildGraphGenerationDidFinish: (@Sendable () async -> Void)?

  public var preparationTaskDidStart: (@Sendable (PreparationTaskDescription) async -> Void)?

  public var preparationTaskDidFinish: (@Sendable (PreparationTaskDescription) async -> Void)?

  public var updateIndexStoreTaskDidStart: (@Sendable (UpdateIndexStoreTaskDescription) async -> Void)?

  /// A callback that is called when an index task finishes.
  public var updateIndexStoreTaskDidFinish: (@Sendable (UpdateIndexStoreTaskDescription) async -> Void)?

  public init(
    buildGraphGenerationDidStart: (@Sendable () async -> Void)? = nil,
    buildGraphGenerationDidFinish: (@Sendable () async -> Void)? = nil,
    preparationTaskDidStart: (@Sendable (PreparationTaskDescription) async -> Void)? = nil,
    preparationTaskDidFinish: (@Sendable (PreparationTaskDescription) async -> Void)? = nil,
    updateIndexStoreTaskDidStart: (@Sendable (UpdateIndexStoreTaskDescription) async -> Void)? = nil,
    updateIndexStoreTaskDidFinish: (@Sendable (UpdateIndexStoreTaskDescription) async -> Void)? = nil
  ) {
    self.buildGraphGenerationDidStart = buildGraphGenerationDidStart
    self.buildGraphGenerationDidFinish = buildGraphGenerationDidFinish
    self.preparationTaskDidStart = preparationTaskDidStart
    self.preparationTaskDidFinish = preparationTaskDidFinish
    self.updateIndexStoreTaskDidStart = updateIndexStoreTaskDidStart
    self.updateIndexStoreTaskDidFinish = updateIndexStoreTaskDidFinish
  }
}
