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
import LanguageServerProtocol
import SKCore
import SKSupport
import SKSwiftPMWorkspace
import SemanticIndex

import struct TSCBasic.AbsolutePath
import struct TSCBasic.RelativePath

/// Closures can be used to inspect or modify internal behavior in SourceKit-LSP.
public struct TestHooks: Sendable {
  public var indexTestHooks: IndexTestHooks

  public var swiftpmTestHooks: SwiftPMTestHooks

  public init(
    indexTestHooks: IndexTestHooks = IndexTestHooks(),
    swiftpmTestHooks: SwiftPMTestHooks = SwiftPMTestHooks()
  ) {
    self.indexTestHooks = indexTestHooks
    self.swiftpmTestHooks = swiftpmTestHooks
  }
}
