//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

public enum TextDocumentSaveReason: Int, Codable, Hashable, Sendable {

  case manual = 1

  /// Automatic save after a delay.
  case afterDelay = 2

  /// Automatic save after the editor loses focus.
  case focusOut = 3
}
