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

/// Request the expansion of the macro at a given use site.
/// **LSP Extension**.
///
/// - Parameters:
///   - textDocument: The document in which the macro is used.
///   - range: The range at which the macro is used.
///
/// - Returns: The macro expansion.
public struct MacroExpansionRequest: TextDocumentRequest, Hashable {
  public static let method: String = "sourcekit-lsp/macroExpansion"
  public typealias Response = [MacroExpansion]

  /// The document in which the macro is used.
  public var textDocument: TextDocumentIdentifier

  /// The position at which the macro is used.
  @CustomCodable<PositionRange>
  public var range: Range<Position>

  public init(
    textDocument: TextDocumentIdentifier,
    range: Range<Position>
  ) {
    self.textDocument = textDocument
    self._range = CustomCodable(wrappedValue: range)
  }
}
