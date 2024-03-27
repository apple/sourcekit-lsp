//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import LSPLogging
import LanguageServerProtocol
import SourceKitD

/// A ranged token in the document used for syntax highlighting.
public struct SyntaxHighlightingToken: Hashable {
  /// The range of the token in the document. Must be on a single line.
  public var range: Range<Position> {
    didSet {
      assert(range.lowerBound.line == range.upperBound.line)
    }
  }
  /// The token type.
  public var kind: SemanticTokenTypes
  /// Additional metadata about the token.
  public var modifiers: SemanticTokenModifiers

  /// The (inclusive) start position of the token.
  public var start: Position { range.lowerBound }
  /// The (exclusive) end position of the token.
  public var end: Position { range.upperBound }
  /// The length of the token in UTF-16 code units.
  public var utf16length: Int { end.utf16index - start.utf16index }

  public init(range: Range<Position>, kind: SemanticTokenTypes, modifiers: SemanticTokenModifiers = []) {
    assert(range.lowerBound.line == range.upperBound.line)

    self.range = range
    self.kind = kind
    self.modifiers = modifiers
  }

  public init(start: Position, utf16length: Int, kind: SemanticTokenTypes, modifiers: SemanticTokenModifiers = []) {
    let range = start..<Position(line: start.line, utf16index: start.utf16index + utf16length)
    self.init(range: range, kind: kind, modifiers: modifiers)
  }
}

extension SemanticTokenTypes {
  /// **(LSP Extension)**
  public static let identifier = Self("identifier")

  // LSP doesn’t know about actors. Display actors as classes.
  public static let actor = Self("class")

  /// All tokens supported by sourcekit-lsp
  public static let all: [Self] = predefined + [.identifier, .actor]

  /// Token types are looked up by index
  public var tokenType: UInt32 {
    UInt32(Self.all.firstIndex(of: self)!)
  }
}

extension SemanticTokenModifiers {
  /// All tokens supported by sourcekit-lsp
  public static let all: [Self] = predefined
}
