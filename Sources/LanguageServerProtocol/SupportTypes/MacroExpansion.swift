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

/// The expansion of a macro in a source file.
public struct MacroExpansion: ResponseType, Hashable {
  /// The position in the source file where the expansion would be inserted.
  public let position: Position

  /// The Swift code that the macro expands to.
  public let sourceText: String

  public init(position: Position, sourceText: String) {
    self.position = position
    self.sourceText = sourceText
  }
}
