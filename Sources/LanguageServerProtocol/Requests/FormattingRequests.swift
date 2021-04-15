//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

/// Request to format an entire document.
///
/// Servers that provide formatting should set the`documentFormattingProvider` server capability.
///
/// - Parameters:
///   - textDocument: The document to format.
///   - options: Options to customize the formatting.
///
/// - Returns: An array of of text edits describing the formatting changes to the document, if any.
public struct DocumentFormattingRequest: TextDocumentRequest, Hashable {
  public static let method: String = "textDocument/formatting"
  public typealias Response = [TextEdit]?

  /// The document to format.
  public var textDocument: TextDocumentIdentifier

  /// Options to customize the formatting.
  public var options: FormattingOptions

  public init(textDocument: TextDocumentIdentifier, options: FormattingOptions) {
    self.textDocument = textDocument
    self.options = options
  }
}

/// Request to format a specified range within a document.
///
/// Servers that provide range formatting should set the`documentRangeFormattingProvider` server
/// capability.
///
/// - Parameters:
///   - textDocument: he document in which to perform formatting.
///   - range: The range to format within `textDocument`.
///   - options: Options to customize the formatting.
///
/// - Returns: An array of of text edits describing the formatting changes to the document, if any.
public struct DocumentRangeFormattingRequest: TextDocumentRequest, Hashable {
  public static let method: String = "textDocument/rangeFormatting"
  public typealias Response = [TextEdit]?

  /// The document in which to perform formatting.
  public var textDocument: TextDocumentIdentifier

  /// The range to format within `textDocument`.
  @CustomCodable<PositionRange>
  public var range: Range<Position>

  /// Options to customize the formatting.
  public var options: FormattingOptions
}

/// Request to format part of a document during typing.
///
/// While `Document[Range]Formatting` requests are appropriate for performing bulk formatting of a
/// document, on-type formatting is meant for providing lightweight formatting during typing. It
/// is triggered in response to trigger characters being typed.
///
/// Servers that provide range formatting should set the`documentOnTypeFormattingProvider` server
/// capability.
///
/// - Parameters:
///   - textDocument: he document in which to perform formatting.
///   - position: The position at which the request was sent.
///   - ch: The character that triggered the formatting.
///   - options: Options to customize the formatting.
///
/// - Returns: An array of of text edits describing the formatting changes to the document, if any.
public struct DocumentOnTypeFormattingRequest: TextDocumentRequest, Hashable {
  public static let method: String = "textDocument/onTypeFormatting"
  public typealias Response = [TextEdit]?

  /// The document in which to perform formatting.
  public var textDocument: TextDocumentIdentifier

  /// The position at which the request was sent, which is immediately after the trigger character.
  public var position: Position

  /// The character that triggered the formatting.
  public var ch: String

  /// Options to customize the formatting.
  public var options: FormattingOptions
}

/// Options to customize how document formatting requests are performed.
public struct FormattingOptions: Codable, Hashable {

  /// The number of space characters in a tab.
  public var tabSize: Int

  /// Whether to use spaces instead of tabs.
  public var insertSpaces: Bool

  public init(tabSize: Int, insertSpaces: Bool) {
    self.tabSize = tabSize
    self.insertSpaces = insertSpaces
  }
}
