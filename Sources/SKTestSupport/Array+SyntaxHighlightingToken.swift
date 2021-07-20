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

import SourceKitLSP
import LanguageServerProtocol

extension Array where Element == SyntaxHighlightingToken {
  /// Decodes the LSP representation of syntax highlighting tokens
  public init(lspEncodedTokens rawTokens: [UInt32]) {
    self.init()
    assert(rawTokens.count.isMultiple(of: 5))
    reserveCapacity(rawTokens.count / 5)

    var current = Position(line: 0, utf16index: 0)

    for i in stride(from: 0, to: rawTokens.count, by: 5) {
      let lineDelta = Int(rawTokens[i])
      let charDelta = Int(rawTokens[i + 1])
      let length = Int(rawTokens[i + 2])
      let rawKind = rawTokens[i + 3]
      let rawModifiers = rawTokens[i + 4]

      guard let kind = SyntaxHighlightingToken.Kind(rawValue: rawKind) else { continue }
      let modifiers = SyntaxHighlightingToken.Modifiers(rawValue: rawModifiers)

      current.line += lineDelta

      if lineDelta == 0 {
        current.utf16index += charDelta
      } else {
        current.utf16index = charDelta
      }

      append(SyntaxHighlightingToken(
        start: current,
        utf16length: length,
        kind: kind,
        modifiers: modifiers
      ))
    }
  }
}
