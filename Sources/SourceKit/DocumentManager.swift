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

import SKSupport
import LanguageServerProtocol
import Dispatch

public struct DocumentSnapshot {
  var document: Document
  var version: Int
  var lineTable: LineTable
  var text: String { return lineTable.content }

  public init(document: Document, version: Int, lineTable: LineTable) {
    self.document = document
    self.version = version
    self.lineTable = lineTable
  }

  func index(of pos: Position) -> String.Index? {
    return lineTable.stringIndexOf(line: pos.line, utf16Column: pos.utf16index)
  }
}

public final class Document {
  public let url: URL
  public let language: Language
  var latestVersion: Int
  var latestLineTable: LineTable
  var diagnostics: [Diagnostic]?

  init(url: URL, language: Language, version: Int, text: String) {
    self.url = url
    self.language = language
    self.latestVersion = version
    self.latestLineTable = LineTable(text)
  }

  /// **Not thread safe!** Use `DocumentManager.latestSnapshot` instead.
  fileprivate var latestSnapshot: DocumentSnapshot {
    return DocumentSnapshot(document: self, version: latestVersion, lineTable: latestLineTable)
  }
}

public final class DocumentManager {

  public enum Error: Swift.Error {
    case alreadyOpen(URL)
    case missingDocument(URL)
  }

  let queue: DispatchQueue = DispatchQueue(label: "document-manager-queue")

  var documents: [URL: Document] = [:]

  /// Opens a new document with the given content and metadata.
  ///
  /// - returns: The initial contents of the file.
  /// - throws: Error.alreadyOpen if the document is already open.
  @discardableResult
  public func open(_ url: URL, language: Language, version: Int, text: String) throws -> DocumentSnapshot {
    return try queue.sync {
      let document = Document(url: url, language: language, version: version, text: text)
      if nil != documents.updateValue(document, forKey: url) {
        throw Error.alreadyOpen(url)
      }
      return document.latestSnapshot
    }
  }

  /// Closes the given document.
  ///
  /// - returns: The initial contents of the file.
  /// - throws: Error.missingDocument if the document is not open.
  public func close(_ url: URL) throws {
    try queue.sync {
      if nil == documents.removeValue(forKey: url) {
        throw Error.missingDocument(url)
      }
    }
  }

  /// Applies the given edits to the document.
  ///
  /// - parameter editCallback: Optional closure to call for each edit.
  /// - parameter before: The document contents *before* the edit is applied.
  /// - returns: The contents of the file after all the edits are applied.
  /// - throws: Error.missingDocument if the document is not open.
  @discardableResult
  public func edit(_ url: URL, newVersion: Int, edits: [TextDocumentContentChangeEvent], editCallback: ((_ before: DocumentSnapshot, TextDocumentContentChangeEvent) -> Void)? = nil) throws -> DocumentSnapshot {
    return try queue.sync {
      guard let document = documents[url] else {
        throw Error.missingDocument(url)
      }

      for edit in edits {
        if let f = editCallback {
          f(document.latestSnapshot, edit)
        }

        if let range = edit.range  {

          document.latestLineTable.replace(
            fromLine: range.lowerBound.line,
            utf16Offset: range.lowerBound.utf16index,
            toLine: range.upperBound.line,
            utf16Offset: range.upperBound.utf16index,
            with: edit.text)

        } else {
          // Full text replacement.
          document.latestLineTable = LineTable(edit.text)
        }

      }

      document.latestVersion = newVersion
      return document.latestSnapshot
    }
  }

  public func latestSnapshot(_ url: URL) -> DocumentSnapshot? {
    return queue.sync {
      guard let document = documents[url] else {
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
  func open(_ note: Notification<DidOpenTextDocument>) -> DocumentSnapshot? {
    let doc = note.params.textDocument
    return orLog("failed to open document", level: .error) {
      try open(doc.url, language: doc.language, version: doc.version, text: doc.text)
    }
  }

  /// Convenience wrapper for `close(_:)` that logs on failure.
  func close(_ note: Notification<DidCloseTextDocument>) {
    orLog("failed to close document", level: .error) {
      try close(note.params.textDocument.url)
    }
  }

  /// Convenience wrapper for `edit(_:newVersion:edits:editCallback:)` that logs on failure.
  @discardableResult
  func edit(_ note: Notification<DidChangeTextDocument>, editCallback: ((_ before: DocumentSnapshot, TextDocumentContentChangeEvent) -> Void)? = nil) -> DocumentSnapshot? {
    return orLog("failed to edit document", level: .error) {
      try edit(note.params.textDocument.url, newVersion: note.params.textDocument.version ?? -1, edits: note.params.contentChanges, editCallback: editCallback)
    }
  }
}
