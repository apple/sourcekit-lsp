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
import LSPLogging
import LanguageServerProtocol
import SKSupport

/// An immutable snapshot of a document at a given time.
///
/// ``DocumentSnapshot`` is always derived from a ``Document``. That is, the
/// data structure that is stored internally by the ``DocumentManager`` is a
/// ``Document``. The purpose of a ``DocumentSnapshot`` is to be able to work
/// with one version of a document without having to think about it changing.
public struct DocumentSnapshot: Identifiable {
  /// An ID that uniquely identifies the version of the document stored in this
  /// snapshot.
  public struct ID: Hashable, Comparable {
    public let uri: DocumentURI
    public let version: Int

    /// Returns `true` if the snapshots reference the same document but rhs has a
    /// later version than `lhs`.
    ///
    /// Snapshot IDs of different documents are not comparable to each other and
    /// will always return `false`.
    public static func < (lhs: DocumentSnapshot.ID, rhs: DocumentSnapshot.ID) -> Bool {
      return lhs.uri == rhs.uri && lhs.version < rhs.version
    }
  }

  public let id: ID
  public let language: Language
  public let lineTable: LineTable

  public var uri: DocumentURI { id.uri }
  public var version: Int { id.version }
  public var text: String { lineTable.content }

  public init(
    uri: DocumentURI,
    language: Language,
    version: Int,
    lineTable: LineTable
  ) {
    self.id = ID(uri: uri, version: version)
    self.language = language
    self.lineTable = lineTable
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

  init(uri: DocumentURI, language: Language, version: Int, text: String) {
    self.uri = uri
    self.language = language
    self.latestVersion = version
    self.latestLineTable = LineTable(text)
  }

  /// **Not thread safe!** Use `DocumentManager.latestSnapshot` instead.
  fileprivate var latestSnapshot: DocumentSnapshot {
    DocumentSnapshot(
      uri: self.uri,
      language: self.language,
      version: latestVersion,
      lineTable: latestLineTable
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

  public init() {}

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
  /// - Parameters:
  ///   - uri: The URI of the document to update
  ///   - newVersion: The new version of the document. Must be greater than the
  ///     latest version of the document.
  ///   - edits: The edits to apply to the document
  ///   - willEditDocument: Optional closure to call before each edit. Will be
  ///     called multiple times if there are multiple edits.
  /// - Returns: The snapshot of the document before the edit and the snapshot
  ///   of the document after the edit.
  @discardableResult
  public func edit(
    _ uri: DocumentURI,
    newVersion: Int,
    edits: [TextDocumentContentChangeEvent],
    willEditDocument: ((_ before: LineTable, TextDocumentContentChangeEvent) -> Void)? = nil
  ) throws -> (preEditSnapshot: DocumentSnapshot, postEditSnapshot: DocumentSnapshot) {
    return try queue.sync {
      guard let document = documents[uri] else {
        throw Error.missingDocument(uri)
      }
      let preEditSnapshot = document.latestSnapshot

      for edit in edits {
        if let willEditDocument {
          willEditDocument(document.latestLineTable, edit)
        }

        if let range = edit.range {
          document.latestLineTable.replace(
            fromLine: range.lowerBound.line,
            utf16Offset: range.lowerBound.utf16index,
            toLine: range.upperBound.line,
            utf16Offset: range.upperBound.utf16index,
            with: edit.text
          )
        } else {
          // Full text replacement.
          document.latestLineTable = LineTable(edit.text)
        }
      }

      if newVersion <= document.latestVersion {
        log("Document version did not increase on edit from \(document.latestVersion) to \(newVersion)", level: .error)
      }
      document.latestVersion = newVersion
      return (preEditSnapshot, document.latestSnapshot)
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
  func open(_ notification: DidOpenTextDocumentNotification) -> DocumentSnapshot? {
    let doc = notification.textDocument
    return orLog("failed to open document", level: .error) {
      try open(doc.uri, language: doc.language, version: doc.version, text: doc.text)
    }
  }

  /// Convenience wrapper for `close(_:)` that logs on failure.
  func close(_ notification: DidCloseTextDocumentNotification) {
    orLog("failed to close document", level: .error) {
      try close(notification.textDocument.uri)
    }
  }

  /// Convenience wrapper for `edit(_:newVersion:edits:willEditDocument:updateDocumentTokens:)`
  /// that logs on failure.
  @discardableResult
  func edit(
    _ notification: DidChangeTextDocumentNotification,
    willEditDocument: ((_ before: LineTable, TextDocumentContentChangeEvent) -> Void)? = nil
  ) -> (preEditSnapshot: DocumentSnapshot, postEditSnapshot: DocumentSnapshot)? {
    return orLog("failed to edit document", level: .error) {
      return try edit(
        notification.textDocument.uri,
        newVersion: notification.textDocument.version,
        edits: notification.contentChanges,
        willEditDocument: willEditDocument
      )
    }
  }
}
