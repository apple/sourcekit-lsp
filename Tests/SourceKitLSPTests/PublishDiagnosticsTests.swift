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

import LSPTestSupport
import LanguageServerProtocol
import SKTestSupport
import XCTest

final class PublishDiagnosticsTests: XCTestCase {
  /// Connection and lifetime management for the service.
  var connection: TestSourceKitServer! = nil

  /// The primary interface to make requests to the SourceKitServer.
  var sk: TestClient! = nil

  private var uri: DocumentURI!
  private var textDocument: TextDocumentIdentifier { TextDocumentIdentifier(uri) }
  private var version: Int!

  override func setUp() {
    version = 0
    uri = DocumentURI(URL(fileURLWithPath: "/PublishDiagnosticsTests/\(UUID()).swift"))
    connection = TestSourceKitServer()
    sk = connection.client
    let documentCapabilities = TextDocumentClientCapabilities()
    _ = try! sk.sendSync(
      InitializeRequest(
        processId: nil,
        rootPath: nil,
        rootURI: nil,
        initializationOptions: nil,
        capabilities: ClientCapabilities(workspace: nil, textDocument: documentCapabilities),
        trace: .off,
        workspaceFolders: nil
      )
    )
  }

  override func tearDown() {
    sk = nil
    connection = nil
  }

  private func openDocument(text: String) {
    sk.send(
      DidOpenTextDocumentNote(
        textDocument: TextDocumentItem(
          uri: uri,
          language: .swift,
          version: version,
          text: text
        )
      )
    )
    version += 1
  }

  private func editDocument(changes: [TextDocumentContentChangeEvent]) {
    sk.send(
      DidChangeTextDocumentNote(
        textDocument: VersionedTextDocumentIdentifier(
          uri,
          version: version
        ),
        contentChanges: changes
      )
    )
  }

  func testUnknownIdentifierDiagnostic() {
    let syntacticDiagnosticsReceived = self.expectation(description: "Syntactic diagnotistics received")
    let semanticDiagnosticsReceived = self.expectation(description: "Semantic diagnotistics received")

    sk.appendOneShotNoteHandler { (note: Note<PublishDiagnosticsNote>) in
      // Unresolved identifier is not a syntactic diagnostic.
      XCTAssertEqual(note.params.diagnostics, [])
      syntacticDiagnosticsReceived.fulfill()
    }

    sk.appendOneShotNoteHandler { (note: Note<PublishDiagnosticsNote>) in
      XCTAssertEqual(note.params.diagnostics.count, 1)
      XCTAssertEqual(
        note.params.diagnostics.first?.range,
        Position(line: 1, utf16index: 2)..<Position(line: 1, utf16index: 9)
      )
      semanticDiagnosticsReceived.fulfill()
    }

    openDocument(
      text: """
        func foo() {
          invalid
        }
        """
    )

    self.wait(for: [syntacticDiagnosticsReceived, semanticDiagnosticsReceived], timeout: defaultTimeout)
  }

  func testRangeShiftAfterNewlineAdded() {
    let initialSyntacticDiagnosticsReceived = self.expectation(
      description: "Syntactic diagnotistics after open received"
    )
    let initialSemanticDiagnosticsReceived = self.expectation(description: "Semantic diagnotistics after open received")

    sk.appendOneShotNoteHandler { (note: Note<PublishDiagnosticsNote>) in
      // Unresolved identifier is not a syntactic diagnostic.
      XCTAssertEqual(note.params.diagnostics, [])
      initialSyntacticDiagnosticsReceived.fulfill()
    }

    sk.appendOneShotNoteHandler { (note: Note<PublishDiagnosticsNote>) in
      XCTAssertEqual(note.params.diagnostics.count, 1)
      XCTAssertEqual(
        note.params.diagnostics.first?.range,
        Position(line: 1, utf16index: 2)..<Position(line: 1, utf16index: 9)
      )
      initialSemanticDiagnosticsReceived.fulfill()
    }

    openDocument(
      text: """
        func foo() {
          invalid
        }
        """
    )

    self.wait(for: [initialSyntacticDiagnosticsReceived, initialSemanticDiagnosticsReceived], timeout: defaultTimeout)

    let editedSyntacticDiagnosticsReceived = self.expectation(
      description: "Syntactic diagnotistics after edit received"
    )
    let editedSemanticDiagnosticsReceived = self.expectation(description: "Semantic diagnotistics after edit received")

    sk.appendOneShotNoteHandler { (note: Note<PublishDiagnosticsNote>) in
      // We should report the semantic diagnostic reported by the edit range-shifted
      XCTAssertEqual(note.params.diagnostics.count, 1)
      XCTAssertEqual(
        note.params.diagnostics.first?.range,
        Position(line: 2, utf16index: 2)..<Position(line: 2, utf16index: 9)
      )
      editedSyntacticDiagnosticsReceived.fulfill()
    }

    sk.appendOneShotNoteHandler { (note: Note<PublishDiagnosticsNote>) in
      XCTAssertEqual(note.params.diagnostics.count, 1)
      XCTAssertEqual(
        note.params.diagnostics.first?.range,
        Position(line: 2, utf16index: 2)..<Position(line: 2, utf16index: 9)
      )
      editedSemanticDiagnosticsReceived.fulfill()
    }

    editDocument(changes: [
      TextDocumentContentChangeEvent(
        range: Position(line: 0, utf16index: 0)..<Position(line: 0, utf16index: 0),
        rangeLength: 0,
        text: "\n"
      )
    ])

    self.wait(for: [editedSyntacticDiagnosticsReceived, editedSemanticDiagnosticsReceived], timeout: defaultTimeout)
  }

  func testRangeShiftAfterNewlineRemoved() {
    let initialSyntacticDiagnosticsReceived = self.expectation(
      description: "Syntactic diagnotistics after open received"
    )
    let initialSemanticDiagnosticsReceived = self.expectation(description: "Semantic diagnotistics after open received")

    sk.appendOneShotNoteHandler { (note: Note<PublishDiagnosticsNote>) in
      // Unresolved identifier is not a syntactic diagnostic.
      XCTAssertEqual(note.params.diagnostics, [])
      initialSyntacticDiagnosticsReceived.fulfill()
    }

    sk.appendOneShotNoteHandler { (note: Note<PublishDiagnosticsNote>) in
      XCTAssertEqual(note.params.diagnostics.count, 1)
      XCTAssertEqual(
        note.params.diagnostics.first?.range,
        Position(line: 2, utf16index: 2)..<Position(line: 2, utf16index: 9)
      )
      initialSemanticDiagnosticsReceived.fulfill()
    }

    openDocument(
      text: """

        func foo() {
          invalid
        }
        """
    )

    self.wait(for: [initialSyntacticDiagnosticsReceived, initialSemanticDiagnosticsReceived], timeout: defaultTimeout)

    let editedSyntacticDiagnosticsReceived = self.expectation(
      description: "Syntactic diagnotistics after edit received"
    )
    let editedSemanticDiagnosticsReceived = self.expectation(description: "Semantic diagnotistics after edit received")

    sk.appendOneShotNoteHandler { (note: Note<PublishDiagnosticsNote>) in
      // We should report the semantic diagnostic reported by the edit range-shifted
      XCTAssertEqual(note.params.diagnostics.count, 1)
      XCTAssertEqual(
        note.params.diagnostics.first?.range,
        Position(line: 1, utf16index: 2)..<Position(line: 1, utf16index: 9)
      )
      editedSyntacticDiagnosticsReceived.fulfill()
    }

    sk.appendOneShotNoteHandler { (note: Note<PublishDiagnosticsNote>) in
      XCTAssertEqual(note.params.diagnostics.count, 1)
      XCTAssertEqual(
        note.params.diagnostics.first?.range,
        Position(line: 1, utf16index: 2)..<Position(line: 1, utf16index: 9)
      )
      editedSemanticDiagnosticsReceived.fulfill()
    }

    editDocument(changes: [
      TextDocumentContentChangeEvent(
        range: Position(line: 0, utf16index: 0)..<Position(line: 1, utf16index: 0),
        rangeLength: 1,
        text: ""
      )
    ])

    self.wait(for: [editedSyntacticDiagnosticsReceived, editedSemanticDiagnosticsReceived], timeout: defaultTimeout)
  }
}
