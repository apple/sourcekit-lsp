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

/// An experimental feature that can be enabled by passing `--experimental-feature` to `sourcekit-lsp` on the command
/// line. The raw value of this feature is how it is named on the command line.
public enum ExperimentalFeature: String, Codable, Sendable, CaseIterable {
  /// Add `--experimental-prepare-for-indexing` to the `swift build` command run to prepare a target for indexing.
  case swiftpmPrepareForIndexing = "swiftpm-prepare-for-indexing"
}
