//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

public struct TestTag: Codable, Equatable, Sendable {
  /// ID of the test tag. `TestTag` instances with the same ID are considered to be identical.
  public let id: String

  public init(id: String) {
    self.id = id
  }
}

/// A test item that can be shown an a client's test explorer or used to identify tests alongside a source file.
///
/// A `TestItem` can represent either a test suite or a test itself, since they both have similar capabilities.
public struct TestItem: ResponseType, Equatable {
  /// Identifier for the `TestItem`.
  ///
  /// This identifier uniquely identifies the test case or test suite. It can be used to run an individual test (suite).
  public let id: String

  /// Display name describing the test.
  public let label: String

  /// Optional description that appears next to the label.
  public let description: String?

  /// A string that should be used when comparing this item with other items.
  /// When `nil` the `label` is used.
  public let sortText: String?

  /// The location of the test item in the source code.
  public let location: Location

  /// The children of this test item. For a test suite, this may contain the individual test cases or nested suites.
  public let children: [TestItem]

  /// Tags associated with this test item.
  public let tags: [TestTag]

  public init(
    id: String,
    label: String,
    description: String? = nil,
    sortText: String? = nil,
    location: Location,
    children: [TestItem],
    tags: [TestTag]
  ) {
    self.id = id
    self.label = label
    self.description = description
    self.sortText = sortText
    self.location = location
    self.children = children
    self.tags = tags
  }
}
