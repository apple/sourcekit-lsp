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

import LSPLogging
import LanguageServerProtocol
import SourceKitD

/// A wrapper around an array of syntax highlighting tokens.
public struct SyntaxHighlightingTokens: Sendable {
  public var tokens: [SyntaxHighlightingToken]

  public init(tokens: [SyntaxHighlightingToken]) {
    self.tokens = tokens
  }

  /// The LSP representation of syntax highlighting tokens. Note that this
  /// requires the tokens in this array to be sorted.
  public var lspEncoded: [UInt32] {
    var previous = Position(line: 0, utf16index: 0)
    var rawTokens: [UInt32] = []
    rawTokens.reserveCapacity(tokens.count * 5)

    for token in self.tokens {
      let lineDelta = token.start.line - previous.line
      let charDelta =
        token.start.utf16index - (
          // The character delta is relative to the previous token's start
          // only if the token is on the previous token's line.
          previous.line == token.start.line ? previous.utf16index : 0)

      // We assert that the tokens are actually sorted
      assert(lineDelta >= 0)
      assert(charDelta >= 0)

      previous = token.start
      rawTokens += [
        UInt32(lineDelta),
        UInt32(charDelta),
        UInt32(token.utf16length),
        token.kind.tokenType,
        token.modifiers.rawValue,
      ]
    }

    return rawTokens
  }

  /// Merges the tokens in this array into a new token array,
  /// preferring the given array's tokens if duplicate ranges are
  /// found.
  public func mergingTokens(with other: SyntaxHighlightingTokens) -> SyntaxHighlightingTokens {
    let otherRanges = Set(other.tokens.map(\.range))
    return SyntaxHighlightingTokens(tokens: tokens.filter { !otherRanges.contains($0.range) } + other.tokens)
  }

  public func mergingTokens(with other: [SyntaxHighlightingToken]) -> SyntaxHighlightingTokens {
    let otherRanges = Set(other.map(\.range))
    return SyntaxHighlightingTokens(tokens: tokens.filter { !otherRanges.contains($0.range) } + other)
  }

  /// Sorts the tokens in this array by their start position.
  public func sorted(
    _ areInIncreasingOrder: (SyntaxHighlightingToken, SyntaxHighlightingToken) -> Bool
  ) -> SyntaxHighlightingTokens {
    SyntaxHighlightingTokens(tokens: tokens.sorted(by: areInIncreasingOrder))
  }
}

extension SyntaxHighlightingTokens {
  /// Decodes the LSP representation of syntax highlighting tokens
  public init(lspEncodedTokens rawTokens: [UInt32]) {
    self.init(tokens: [])
    assert(rawTokens.count.isMultiple(of: 5))
    self.tokens.reserveCapacity(rawTokens.count / 5)

    var current = Position(line: 0, utf16index: 0)

    for i in stride(from: 0, to: rawTokens.count, by: 5) {
      let lineDelta = Int(rawTokens[i])
      let charDelta = Int(rawTokens[i + 1])
      let length = Int(rawTokens[i + 2])
      let rawKind = rawTokens[i + 3]
      let rawModifiers = rawTokens[i + 4]

      current.line += lineDelta

      if lineDelta == 0 {
        current.utf16index += charDelta
      } else {
        current.utf16index = charDelta
      }

      let kind = SemanticTokenTypes.all[Int(rawKind)]
      let modifiers = SemanticTokenModifiers(rawValue: rawModifiers)

      self.tokens.append(
        SyntaxHighlightingToken(
          start: current,
          utf16length: length,
          kind: kind,
          modifiers: modifiers
        )
      )
    }
  }
}
