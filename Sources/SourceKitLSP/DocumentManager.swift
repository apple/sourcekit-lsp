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

import Dispatch
import LanguageServerProtocol
import LSPLogging
import SKSupport

public struct DocumentTokens {
  /// Lexical tokens, e.g. keywords, raw identifiers, ...
  public var lexical: [SyntaxHighlightingToken] = []
  /// Syntactic tokens, e.g. declarations, etc.
  public var syntactic: [SyntaxHighlightingToken] = []
  /// Semantic tokens, e.g. variable references, type references, ...
  public var semantic: [SyntaxHighlightingToken] = []

  private var merged: [SyntaxHighlightingToken] {
    [lexical, syntactic, semantic].reduce([]) { $0.mergingTokens(with: $1) }
  }
  public var mergedAndSorted: [SyntaxHighlightingToken] {
    merged.sorted { $0.start < $1.start }
  }

  /// Modifies the syntax highlighting tokens of each kind
  /// (lexical, syntactic, semantic) according to `action`.
  public mutating func withMutableTokensOfEachKind(_ action: (inout [SyntaxHighlightingToken]) -> Void) {
    action(&lexical)
    action(&syntactic)
    action(&semantic)
  }

  // Replace all lexical tokens in `range`.
  public mutating func replaceLexical(in range: Range<Position>, with newTokens: [SyntaxHighlightingToken]) {
    lexical.removeAll { $0.range.overlaps(range) }
    lexical += newTokens
  }
}

public struct DocumentSnapshot {
  public var document: Document
  public var version: Int
  public var lineTable: LineTable
  /// Syntax highlighting tokens for the document. Note that
  /// `uri` + `latestVersion` only uniquely identifies a snapshot's content,
  /// the tokens are updated independently and only used internally.
  public var tokens: DocumentTokens

  public var text: String { lineTable.content }

  public init(
    document: Document,
    version: Int,
    lineTable: LineTable,
    tokens: DocumentTokens
  ) {
    self.document = document
    self.version = version
    self.lineTable = lineTable
    self.tokens = tokens
  }

  func index(of pos: Position) -> String.Index? {
    return lineTable.stringIndexOf(line: pos.line, utf16Column: pos.utf16index)
  }
}

public final class Document {
  public let uri: DocumentURI
  public let language: Language
  var latestVersion: Int
  var latestLineTable: LineTable
  var latestTokens: DocumentTokens

  init(uri: DocumentURI, language: Language, version: Int, text: String) {
    self.uri = uri
    self.language = language
    self.latestVersion = version
    self.latestLineTable = LineTable(text)
    self.latestTokens = DocumentTokens()
  }

  /// **Not thread safe!** Use `DocumentManager.latestSnapshot` instead.
  fileprivate var latestSnapshot: DocumentSnapshot {
    DocumentSnapshot(
      document: self,
      version: latestVersion,
      lineTable: latestLineTable,
      tokens: latestTokens
    )
  }
}

public final class DocumentManager {

  public enum Error: Swift.Error {
    case alreadyOpen(DocumentURI)
    case missingDocument(DocumentURI)
  }

  let queue: DispatchQueue = DispatchQueue(label: "document-manager-queue")

  var documents: [DocumentURI: Document] = [:]

  /// All currently opened documents.
  public var openDocuments: Set<DocumentURI> {
    return queue.sync {
      return Set(documents.keys)
    }
  }

  /// Opens a new document with the given content and metadata.
  ///
  /// - returns: The initial contents of the file.
  /// - throws: Error.alreadyOpen if the document is already open.
  @discardableResult
  public func open(_ uri: DocumentURI, language: Language, version: Int, text: String) throws -> DocumentSnapshot {
    return try queue.sync {
      let document = Document(uri: uri, language: language, version: version, text: text)
      if nil != documents.updateValue(document, forKey: uri) {
        throw Error.alreadyOpen(uri)
      }
      return document.latestSnapshot
    }
  }

  /// Closes the given document.
  ///
  /// - returns: The initial contents of the file.
  /// - throws: Error.missingDocument if the document is not open.
  public func close(_ uri: DocumentURI) throws {
    try queue.sync {
      if nil == documents.removeValue(forKey: uri) {
        throw Error.missingDocument(uri)
      }
    }
  }

  /// Applies the given edits to the document.
  ///
  /// - parameter beforeCallback: Optional closure to call before each edit.
  /// - parameter afterCallback: Optional closure to call after each edit.
  /// - parameter before: The document contents *before* the edit is applied.
  /// - parameter after: The document contents *after* the edit is applied.
  /// - returns: The contents of the file after all the edits are applied.
  /// - throws: Error.missingDocument if the document is not open.
  @discardableResult
  public func edit(
    _ uri: DocumentURI,
    newVersion: Int,
    edits: [TextDocumentContentChangeEvent],
    beforeCallback: ((_ before: DocumentSnapshot, TextDocumentContentChangeEvent) -> Void)? = nil,
    afterCallback: ((_ after: DocumentSnapshot) -> DocumentTokens?)? = nil
  ) throws -> DocumentSnapshot {
    return try queue.sync {
      guard let document = documents[uri] else {
        throw Error.missingDocument(uri)
      }

      for edit in edits {
        if let f = beforeCallback {
          f(document.latestSnapshot, edit)
        }

        if let range = edit.range  {
          document.latestLineTable.replace(
            fromLine: range.lowerBound.line,
            utf16Offset: range.lowerBound.utf16index,
            toLine: range.upperBound.line,
            utf16Offset: range.upperBound.utf16index,
            with: edit.text)
          
          // Remove all tokens in the updated range and shift later ones.

          let previousLineCount = 1 + range.upperBound.line - range.lowerBound.line
          let newLines = edit.text.split(separator: "\n", omittingEmptySubsequences: false)
          let lastLineReplaceLength = (
            range.lowerBound.line == range.upperBound.line ? range.upperBound.utf16index : 0
          ) - range.lowerBound.utf16index
          let lastLineLengthDelta = newLines.last!.count - lastLineReplaceLength
          let lineDelta = newLines.count - previousLineCount

          document.latestTokens.withMutableTokensOfEachKind { tokens in
            tokens = Array(tokens.lazy
              .filter {
                // Only keep tokens that don't overlap with the edit range
                !$0.range.overlaps(range)
              }
              .map {
                // Shift tokens after the edit range
                var token = $0
                if token.start.line == range.upperBound.line
                  && token.start.utf16index >= range.upperBound.utf16index {
                  token.start.utf16index += lastLineLengthDelta
                  token.start.line += lineDelta
                } else if token.start.line > range.upperBound.line {
                  token.start.line += lineDelta
                }
                return token
              })
          }
        } else {
          // Full text replacement.
          document.latestLineTable = LineTable(edit.text)
          document.latestTokens = DocumentTokens()
        }

        if let f = afterCallback, let tokens = f(document.latestSnapshot) {
          document.latestTokens = tokens
        }
      }

      document.latestVersion = newVersion
      return document.latestSnapshot
    }
  }

  /// Updates the tokens in a document.
  ///
  /// - parameter uri: The URI of the document to be updated
  /// - parameter tokens: The new tokens for the document
  @discardableResult
  public func updateTokens(_ uri: DocumentURI, tokens: DocumentTokens) throws -> DocumentSnapshot {
    return try queue.sync {
      guard let document = documents[uri] else {
        throw Error.missingDocument(uri)
      }

      document.latestTokens = tokens

      return document.latestSnapshot
    }
  }

  public func latestSnapshot(_ uri: DocumentURI) -> DocumentSnapshot? {
    return queue.sync {
      guard let document = documents[uri] else {
        return nil
      }
      return document.latestSnapshot
    }
  }
}

extension DocumentManager {

  // MARK: - LSP notification handling

  /// Convenience wrapper for `open(_:language:version:text:)` that logs on failure.
  @discardableResult
  func open(_ note: DidOpenTextDocumentNotification) -> DocumentSnapshot? {
    let doc = note.textDocument
    return orLog("failed to open document", level: .error) {
      try open(doc.uri, language: doc.language, version: doc.version, text: doc.text)
    }
  }

  /// Convenience wrapper for `close(_:)` that logs on failure.
  func close(_ note: DidCloseTextDocumentNotification) {
    orLog("failed to close document", level: .error) {
      try close(note.textDocument.uri)
    }
  }

  /// Convenience wrapper for `edit(_:newVersion:edits:beforeCallback:)` that logs on failure.
  @discardableResult
  func edit(
    _ note: DidChangeTextDocumentNotification,
    beforeCallback: ((_ before: DocumentSnapshot, TextDocumentContentChangeEvent) -> Void)? = nil,
    afterCallback: ((_ after: DocumentSnapshot) -> DocumentTokens?)? = nil
  ) -> DocumentSnapshot? {
    return orLog("failed to edit document", level: .error) {
      try edit(
        note.textDocument.uri,
        newVersion: note.textDocument.version ?? -1,
        edits: note.contentChanges,
        beforeCallback: beforeCallback,
        afterCallback: afterCallback
      )
    }
  }
}
