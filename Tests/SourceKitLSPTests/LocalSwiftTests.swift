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

import LSPLogging
import LSPTestSupport
import LanguageServerProtocol
import SKCore
import SKTestSupport
import SourceKitD
@_spi(Testing) import SourceKitLSP
import SwiftExtensions
import SwiftParser
import SwiftSyntax
import XCTest

final class LocalSwiftTests: XCTestCase {
  private let quickFixCapabilities = ClientCapabilities(
    textDocument: TextDocumentClientCapabilities(
      codeAction: .init(
        codeActionLiteralSupport: .init(
          codeActionKind: .init(valueSet: [.quickFix])
        )
      )
    )
  )

  // MARK: - Tests

  func testEditing() async throws {
    let testClient = try await TestSourceKitLSPClient(usePullDiagnostics: false)
    let uri = DocumentURI(for: .swift)

    let documentManager = await testClient.server.documentManager

    testClient.openDocument("func", uri: uri, version: 12)

    let openDiags = try await testClient.nextDiagnosticsNotification()
    XCTAssertEqual(openDiags.diagnostics.count, 1)
    XCTAssertEqual(
      openDiags.diagnostics.first?.range.lowerBound,
      Position(line: 0, utf16index: 4)
    )
    XCTAssertEqual("func", try documentManager.latestSnapshot(uri).text)

    testClient.send(
      DidChangeTextDocumentNotification(
        textDocument: .init(uri, version: 13),
        contentChanges: [
          .init(range: Range(Position(line: 0, utf16index: 4)), text: " foo() {}\n")
        ]
      )
    )
    let edit1Diags = try await testClient.nextDiagnosticsNotification()
    XCTAssertEqual(edit1Diags.diagnostics.count, 0)
    XCTAssertEqual("func foo() {}\n", try documentManager.latestSnapshot(uri).text)

    testClient.send(
      DidChangeTextDocumentNotification(
        textDocument: .init(uri, version: 14),
        contentChanges: [
          .init(range: Range(Position(line: 1, utf16index: 0)), text: "bar()")
        ]
      )
    )
    let edit2Diags = try await testClient.nextDiagnosticsNotification()
    // 1 = semantic update finished already
    XCTAssertEqual(edit2Diags.diagnostics.count, 1)
    XCTAssertEqual(
      edit2Diags.diagnostics.first?.range.lowerBound,
      Position(line: 1, utf16index: 0)
    )
    XCTAssertEqual(
      """
      func foo() {}
      bar()
      """,
      try documentManager.latestSnapshot(uri).text
    )

    testClient.send(
      DidChangeTextDocumentNotification(
        textDocument: .init(uri, version: 15),
        contentChanges: [
          .init(range: Position(line: 1, utf16index: 0)..<Position(line: 1, utf16index: 3), text: "foo")
        ]
      )
    )

    let edit3Diags = try await testClient.nextDiagnosticsNotification()
    XCTAssertEqual(edit3Diags.diagnostics.count, 0)
    XCTAssertEqual(
      """
      func foo() {}
      foo()
      """,
      try documentManager.latestSnapshot(uri).text
    )

    testClient.send(
      DidChangeTextDocumentNotification(
        textDocument: .init(uri, version: 16),
        contentChanges: [
          .init(range: Position(line: 1, utf16index: 0)..<Position(line: 1, utf16index: 3), text: "fooTypo")
        ]
      )
    )
    let edit4Diags = try await testClient.nextDiagnosticsNotification()
    // 0 = only syntactic
    XCTAssertEqual(edit4Diags.diagnostics.count, 1)
    XCTAssertEqual(
      edit4Diags.diagnostics.first?.range.lowerBound,
      Position(line: 1, utf16index: 0)
    )
    XCTAssertEqual(
      """
      func foo() {}
      fooTypo()
      """,
      try documentManager.latestSnapshot(uri).text
    )

    testClient.send(
      DidChangeTextDocumentNotification(
        textDocument: .init(uri, version: 17),
        contentChanges: [
          .init(
            range: nil,
            text: """
              func bar() {}
              foo()
              """
          )
        ]
      )
    )

    let edit5Diags = try await testClient.nextDiagnosticsNotification()
    XCTAssertEqual(edit5Diags.diagnostics.count, 1)
    XCTAssertEqual(
      edit5Diags.diagnostics.first?.range.lowerBound,
      Position(line: 1, utf16index: 0)
    )
    XCTAssertEqual(
      """
      func bar() {}
      foo()
      """,
      try documentManager.latestSnapshot(uri).text
    )
  }

  func testEditingNonURL() async throws {
    let testClient = try await TestSourceKitLSPClient(usePullDiagnostics: false)
    let uri = try DocumentURI(string: "urn:uuid:A1B08909-E791-469E-BF0F-F5790977E051")

    let documentManager = await testClient.server.documentManager

    testClient.openDocument("func", uri: uri, language: .swift)

    let openDiags = try await testClient.nextDiagnosticsNotification()
    XCTAssertEqual(openDiags.diagnostics.count, 1)
    XCTAssertEqual(
      openDiags.diagnostics.first?.range.lowerBound,
      Position(line: 0, utf16index: 4)
    )
    try XCTAssertEqual("func", documentManager.latestSnapshot(uri).text)

    testClient.send(
      DidChangeTextDocumentNotification(
        textDocument: .init(uri, version: 13),
        contentChanges: [
          .init(range: Range(Position(line: 0, utf16index: 4)), text: " foo() {}\n")
        ]
      )
    )

    let edit1Diags = try await testClient.nextDiagnosticsNotification()
    XCTAssertEqual(edit1Diags.diagnostics.count, 0)
    try XCTAssertEqual("func foo() {}\n", documentManager.latestSnapshot(uri).text)

    testClient.send(
      DidChangeTextDocumentNotification(
        textDocument: .init(uri, version: 14),
        contentChanges: [
          .init(range: Range(Position(line: 1, utf16index: 0)), text: "bar()")
        ]
      )
    )

    let edit2Diags = try await testClient.nextDiagnosticsNotification()
    XCTAssertEqual(edit2Diags.diagnostics.count, 1)
    XCTAssertEqual(
      edit2Diags.diagnostics.first?.range.lowerBound,
      Position(line: 1, utf16index: 0)
    )
    XCTAssertEqual(
      """
      func foo() {}
      bar()
      """,
      try documentManager.latestSnapshot(uri).text
    )

    testClient.send(
      DidChangeTextDocumentNotification(
        textDocument: .init(uri, version: 15),
        contentChanges: [
          .init(range: Position(line: 1, utf16index: 0)..<Position(line: 1, utf16index: 3), text: "foo")
        ]
      )
    )

    let edit3Diags = try await testClient.nextDiagnosticsNotification()
    XCTAssertEqual(edit3Diags.diagnostics.count, 0)
    XCTAssertEqual(
      """
      func foo() {}
      foo()
      """,
      try documentManager.latestSnapshot(uri).text
    )

    testClient.send(
      DidChangeTextDocumentNotification(
        textDocument: .init(uri, version: 16),
        contentChanges: [
          .init(range: Position(line: 1, utf16index: 0)..<Position(line: 1, utf16index: 3), text: "fooTypo")
        ]
      )
    )
    let edit4Diags = try await testClient.nextDiagnosticsNotification()
    XCTAssertEqual(edit4Diags.diagnostics.count, 1)
    XCTAssertEqual(
      edit4Diags.diagnostics.first?.range.lowerBound,
      Position(line: 1, utf16index: 0)
    )
    XCTAssertEqual(
      """
      func foo() {}
      fooTypo()
      """,
      try documentManager.latestSnapshot(uri).text
    )

    testClient.send(
      DidChangeTextDocumentNotification(
        textDocument: .init(uri, version: 17),
        contentChanges: [
          .init(
            range: nil,
            text: """
              func bar() {}
              foo()
              """
          )
        ]
      )
    )

    let edit5Diags = try await testClient.nextDiagnosticsNotification()
    XCTAssertEqual(edit5Diags.diagnostics.count, 1)
    XCTAssertEqual(
      edit5Diags.diagnostics.first?.range.lowerBound,
      Position(line: 1, utf16index: 0)
    )
    XCTAssertEqual(
      """
      func bar() {}
      foo()
      """,
      try documentManager.latestSnapshot(uri).text
    )

  }

  func testExcludedDocumentSchemeDiagnostics() async throws {
    let testClient = try await TestSourceKitLSPClient(usePullDiagnostics: false)
    let includedURL = URL(fileURLWithPath: "/a.swift")
    let includedURI = DocumentURI(includedURL)

    let excludedURI = try DocumentURI(string: "git:/a.swift")

    // Open the excluded URI first so our later notification handlers can confirm
    // that no diagnostics were emitted for this excluded URI.
    testClient.openDocument("func", uri: excludedURI, language: .swift)

    testClient.openDocument("func", uri: includedURI, language: .swift)
    let diags = try await testClient.nextDiagnosticsNotification()
    XCTAssertEqual(diags.uri, includedURI)
  }

  func testCrossFileDiagnostics() async throws {
    let testClient = try await TestSourceKitLSPClient(usePullDiagnostics: false)
    let urlA = URL(fileURLWithPath: "/\(UUID())/a.swift")
    let urlB = URL(fileURLWithPath: "/\(UUID())/b.swift")
    let uriA = DocumentURI(urlA)
    let uriB = DocumentURI(urlB)

    testClient.openDocument("foo()", uri: uriA)

    let openADiags = try await testClient.nextDiagnosticsNotification()
    XCTAssertEqual(openADiags.diagnostics.count, 1)
    XCTAssertEqual(
      openADiags.diagnostics.first?.range.lowerBound,
      Position(line: 0, utf16index: 0)
    )

    testClient.openDocument("bar()", uri: uriB)

    let openBDiags = try await testClient.nextDiagnosticsNotification()
    XCTAssertEqual(openBDiags.diagnostics.count, 1)
    XCTAssertEqual(
      openBDiags.diagnostics.first?.range.lowerBound,
      Position(line: 0, utf16index: 0)
    )

    testClient.send(
      DidChangeTextDocumentNotification(
        textDocument: .init(uriA, version: 13),
        contentChanges: [
          .init(range: nil, text: "foo()\n")
        ]
      )
    )

    let editADiags = try await testClient.nextDiagnosticsNotification()
    XCTAssertEqual(editADiags.diagnostics.count, 1)
  }

  func testDiagnosticsReopen() async throws {
    let testClient = try await TestSourceKitLSPClient(usePullDiagnostics: false)
    let urlA = URL(fileURLWithPath: "/\(UUID())/a.swift")
    let uriA = DocumentURI(urlA)

    testClient.openDocument("foo()", uri: uriA)

    let open1Diags = try await testClient.nextDiagnosticsNotification()
    XCTAssertEqual(open1Diags.diagnostics.count, 1)
    XCTAssertEqual(
      open1Diags.diagnostics.first?.range.lowerBound,
      Position(line: 0, utf16index: 0)
    )

    testClient.send(DidCloseTextDocumentNotification(textDocument: .init(urlA)))

    testClient.openDocument("var", uri: uriA)

    let open2Diags = try await testClient.nextDiagnosticsNotification()
    XCTAssertEqual(open2Diags.diagnostics.count, 1)
    XCTAssertEqual(
      open2Diags.diagnostics.first?.range.lowerBound,
      Position(line: 0, utf16index: 3)
    )
  }

  func testEducationalNotesAreUsedAsDiagnosticCodes() async throws {
    let testClient = try await TestSourceKitLSPClient(
      capabilities: ClientCapabilities(
        textDocument: TextDocumentClientCapabilities(
          publishDiagnostics: .init(codeDescriptionSupport: true)
        )
      ),
      usePullDiagnostics: false
    )
    let url = URL(fileURLWithPath: "/\(UUID())/a.swift")
    let uri = DocumentURI(url)

    testClient.openDocument("@propertyWrapper struct Bar {}", uri: uri)

    let diags = try await testClient.nextDiagnosticsNotification()
    XCTAssertEqual(diags.diagnostics.count, 1)
    let diag = diags.diagnostics.first!
    XCTAssertEqual(diag.code, .string("property-wrapper-requirements"))
    XCTAssertEqual(diag.codeDescription?.href.fileURL?.lastPathComponent, "property-wrapper-requirements.md")
  }

  func testFixitsAreIncludedInPublishDiagnostics() async throws {
    let testClient = try await TestSourceKitLSPClient(usePullDiagnostics: false)
    let url = URL(fileURLWithPath: "/\(UUID())/a.swift")
    let uri = DocumentURI(url)

    testClient.openDocument(
      """
      func foo() {
        let a = 2
      }
      """,
      uri: uri
    )

    let diags = try await testClient.nextDiagnosticsNotification()
    XCTAssertEqual(diags.diagnostics.count, 1)
    let diag = diags.diagnostics.first!
    XCTAssertNotNil(diag.codeActions)
    XCTAssertEqual(diag.codeActions!.count, 1)
    let fixit = diag.codeActions!.first!

    // Expected Fix-it: Replace `let a` with `_` because it's never used
    let expectedTextEdit = TextEdit(
      range: Position(line: 1, utf16index: 2)..<Position(line: 1, utf16index: 7),
      newText: "_"
    )
    XCTAssertEqual(
      fixit,
      CodeAction(
        title: "Replace 'let a' with '_'",
        kind: .quickFix,
        diagnostics: nil,
        edit: WorkspaceEdit(changes: [uri: [expectedTextEdit]], documentChanges: nil),
        command: nil
      )
    )
  }

  func testFixitsAreIncludedInPublishDiagnosticsNotifications() async throws {
    let testClient = try await TestSourceKitLSPClient(usePullDiagnostics: false)
    let url = URL(fileURLWithPath: "/\(UUID())/a.swift")
    let uri = DocumentURI(url)

    testClient.openDocument(
      """
      func foo(a: Int?) {
        _ = a.bigEndian
      }
      """,
      uri: uri
    )

    let diags = try await testClient.nextDiagnosticsNotification()
    XCTAssertEqual(diags.diagnostics.count, 1)
    let diag = diags.diagnostics.first!
    XCTAssertEqual(diag.relatedInformation?.count, 2)
    if let note1 = diag.relatedInformation?.first(where: { $0.message.contains("'?'") }) {
      XCTAssertEqual(note1.codeActions?.count, 1)
      if let fixit = note1.codeActions?.first {
        // Expected Fix-it: Replace `let a` with `_` because it's never used
        let expectedTextEdit = TextEdit(
          range: Position(line: 1, utf16index: 7)..<Position(line: 1, utf16index: 7),
          newText: "?"
        )
        XCTAssertEqual(
          fixit,
          CodeAction(
            title: "Chain the optional using '?' to access member 'bigEndian' only for non-'nil' base values",
            kind: .quickFix,
            diagnostics: nil,
            edit: WorkspaceEdit(changes: [uri: [expectedTextEdit]], documentChanges: nil),
            command: nil
          )
        )
      }
    } else {
      XCTFail("missing '?' note")
    }
    if let note2 = diag.relatedInformation?.first(where: { $0.message.contains("'!'") }) {
      XCTAssertEqual(note2.codeActions?.count, 1)
      if let fixit = note2.codeActions?.first {
        // Expected Fix-it: Replace `let a` with `_` because it's never used
        let expectedTextEdit = TextEdit(
          range: Position(line: 1, utf16index: 7)..<Position(line: 1, utf16index: 7),
          newText: "!"
        )
        XCTAssertEqual(
          fixit,
          CodeAction(
            title: "Force-unwrap using '!' to abort execution if the optional value contains 'nil'",
            kind: .quickFix,
            diagnostics: nil,
            edit: WorkspaceEdit(changes: [uri: [expectedTextEdit]], documentChanges: nil),
            command: nil
          )
        )
      }
    } else {
      XCTFail("missing '!' note")
    }
  }

  func testFixitInsert() async throws {
    let testClient = try await TestSourceKitLSPClient(usePullDiagnostics: false)
    let url = URL(fileURLWithPath: "/\(UUID())/a.swift")
    let uri = DocumentURI(url)

    testClient.openDocument(
      """
      func foo() {
        print("")print("")
      }
      """,
      uri: uri
    )

    let diags = try await testClient.nextDiagnosticsNotification()
    XCTAssertEqual(diags.diagnostics.count, 1)
    let diag = diags.diagnostics.first!
    XCTAssertNotNil(diag.codeActions)
    XCTAssertEqual(diag.codeActions!.count, 1)
    let fixit = diag.codeActions!.first!

    // Expected Fix-it: Insert `;`
    let expectedTextEdit = TextEdit(
      range: Position(line: 1, utf16index: 11)..<Position(line: 1, utf16index: 11),
      newText: ";"
    )
    XCTAssertEqual(
      fixit,
      CodeAction(
        title: "Insert ';'",
        kind: .quickFix,
        diagnostics: nil,
        edit: WorkspaceEdit(changes: [uri: [expectedTextEdit]], documentChanges: nil),
        command: nil
      )
    )
  }

  func testFixitTitle() {
    XCTAssertEqual("Insert ';'", CodeAction.fixitTitle(replace: "", with: ";"))
    XCTAssertEqual("Replace 'let a' with '_'", CodeAction.fixitTitle(replace: "let a", with: "_"))
    XCTAssertEqual("Remove 'foo ='", CodeAction.fixitTitle(replace: "foo =", with: ""))
  }

  func testFixitsAreReturnedFromCodeActions() async throws {
    let testClient = try await TestSourceKitLSPClient(capabilities: quickFixCapabilities, usePullDiagnostics: false)
    let url = URL(fileURLWithPath: "/\(UUID())/a.swift")
    let uri = DocumentURI(url)

    testClient.openDocument(
      """
      func foo() {
        let a = 2
      }
      """,
      uri: uri
    )

    let diags = try await testClient.nextDiagnosticsNotification()
    XCTAssertEqual(diags.diagnostics.count, 1)
    let diagnostic = diags.diagnostics.first

    let request = CodeActionRequest(
      range: Position(line: 1, utf16index: 0)..<Position(line: 1, utf16index: 11),
      context: CodeActionContext(
        diagnostics: [try XCTUnwrap(diagnostic, "expected diagnostic to be available")],
        only: nil
      ),
      textDocument: TextDocumentIdentifier(uri)
    )
    let response = try await testClient.send(request)

    XCTAssertNotNil(response)
    guard case .codeActions(let codeActions) = response else {
      XCTFail("Expected code actions as response")
      return
    }
    let quickFixes = codeActions.filter { $0.kind == .quickFix }
    XCTAssertEqual(quickFixes.count, 1)
    let fixit = quickFixes.first!

    // Diagnostic returned by code actions cannot be recursive
    var expectedDiagnostic = try XCTUnwrap(diagnostic, "expected diagnostic to be available")
    expectedDiagnostic.codeActions = nil

    // Expected Fix-it: Replace `let a` with `_` because it's never used
    let expectedTextEdit = TextEdit(
      range: Position(line: 1, utf16index: 2)..<Position(line: 1, utf16index: 7),
      newText: "_"
    )
    XCTAssertEqual(
      fixit,
      CodeAction(
        title: "Replace 'let a' with '_'",
        kind: .quickFix,
        diagnostics: [expectedDiagnostic],
        edit: WorkspaceEdit(changes: [uri: [expectedTextEdit]], documentChanges: nil),
        command: nil
      )
    )
  }

  func testFixitsAreReturnedFromCodeActionsNotifications() async throws {
    let testClient = try await TestSourceKitLSPClient(capabilities: quickFixCapabilities, usePullDiagnostics: false)
    let url = URL(fileURLWithPath: "/\(UUID())/a.swift")
    let uri = DocumentURI(url)

    testClient.openDocument(
      """
      func foo(a: Int?) {
        _ = a.bigEndian
      }
      """,
      uri: uri
    )

    let diags = try await testClient.nextDiagnosticsNotification()
    XCTAssertEqual(diags.diagnostics.count, 1)
    let diagnostic = diags.diagnostics.first

    let request = CodeActionRequest(
      range: Position(line: 1, utf16index: 0)..<Position(line: 1, utf16index: 11),
      context: CodeActionContext(
        diagnostics: [try XCTUnwrap(diagnostic, "expected diagnostic to be available")],
        only: nil
      ),
      textDocument: TextDocumentIdentifier(uri)
    )
    let response = try await testClient.send(request)

    XCTAssertNotNil(response)
    guard case .codeActions(let codeActions) = response else {
      XCTFail("Expected code actions as response")
      return
    }
    let quickFixes = codeActions.filter { $0.kind == .quickFix }
    XCTAssertEqual(quickFixes.count, 2)

    var expectedTextEdit = TextEdit(
      range: Position(line: 1, utf16index: 7)..<Position(line: 1, utf16index: 7),
      newText: "_"
    )

    for fixit in quickFixes {
      if fixit.title.contains("!") {
        XCTAssert(fixit.title.starts(with: "Force-unwrap using '!'"))
        expectedTextEdit.newText = "!"
        XCTAssertEqual(fixit.edit, WorkspaceEdit(changes: [uri: [expectedTextEdit]], documentChanges: nil))
      } else {
        XCTAssert(fixit.title.starts(with: "Chain the optional using '?'"))
        expectedTextEdit.newText = "?"
        XCTAssertEqual(fixit.edit, WorkspaceEdit(changes: [uri: [expectedTextEdit]], documentChanges: nil))
      }
      XCTAssertEqual(fixit.kind, .quickFix)
      XCTAssertEqual(fixit.diagnostics?.count, 1)
      XCTAssertEqual(fixit.diagnostics?.first?.severity, .error)
      XCTAssertEqual(fixit.diagnostics?.first?.range, Range(Position(line: 1, utf16index: 6)))
      XCTAssert(fixit.diagnostics?.first?.message.starts(with: "Value of optional type") == true)
    }
  }

  func testMuliEditFixitCodeActionPrimary() async throws {
    let testClient = try await TestSourceKitLSPClient(capabilities: quickFixCapabilities, usePullDiagnostics: false)
    let url = URL(fileURLWithPath: "/\(UUID())/a.swift")
    let uri = DocumentURI(url)

    testClient.openDocument(
      """
      @available(*, introduced: 10, deprecated: 11)
      func foo() {}
      """,
      uri: uri
    )

    let diags = try await testClient.nextDiagnosticsNotification()
    XCTAssertEqual(diags.diagnostics.count, 1)
    let diagnostic = diags.diagnostics.first

    let request = CodeActionRequest(
      range: Position(line: 0, utf16index: 1)..<Position(line: 0, utf16index: 10),
      context: CodeActionContext(
        diagnostics: [try XCTUnwrap(diagnostic, "expected diagnostic to be available")],
        only: nil
      ),
      textDocument: TextDocumentIdentifier(uri)
    )
    let response = try await testClient.send(request)

    XCTAssertNotNil(response)
    guard case .codeActions(let codeActions) = response else {
      XCTFail("Expected code actions as response")
      return
    }
    let quickFixes = codeActions.filter { $0.kind == .quickFix }
    XCTAssertEqual(quickFixes.count, 1)
    guard let fixit = quickFixes.first else { return }

    XCTAssertEqual(fixit.title, "Remove ': 10'...")
    XCTAssertEqual(fixit.diagnostics?.count, 1)
    XCTAssertEqual(
      fixit.edit?.changes?[uri],
      [
        TextEdit(range: Position(line: 0, utf16index: 24)..<Position(line: 0, utf16index: 28), newText: ""),
        TextEdit(range: Position(line: 0, utf16index: 40)..<Position(line: 0, utf16index: 44), newText: ""),
      ]
    )
  }

  func testMuliEditFixitCodeActionNotifications() async throws {
    let testClient = try await TestSourceKitLSPClient(capabilities: quickFixCapabilities, usePullDiagnostics: false)
    let url = URL(fileURLWithPath: "/\(UUID())/a.swift")
    let uri = DocumentURI(url)

    testClient.openDocument(
      """
      @available(*, deprecated, renamed: "new(_:hotness:)")
      func old(and: Int, busted: Int) {}
      func test() {
        old(and: 1, busted: 2)
      }
      """,
      uri: uri
    )

    let diags = try await testClient.nextDiagnosticsNotification()
    XCTAssertEqual(diags.diagnostics.count, 1)
    let diagnostic = diags.diagnostics.first!

    let request = CodeActionRequest(
      range: Position(line: 3, utf16index: 2)..<Position(line: 3, utf16index: 2),
      context: CodeActionContext(
        diagnostics: [try XCTUnwrap(diagnostic, "expected diagnostic to be available")],
        only: nil
      ),
      textDocument: TextDocumentIdentifier(uri)
    )
    let response = try await testClient.send(request)

    XCTAssertNotNil(response)
    guard case .codeActions(let codeActions) = response else {
      XCTFail("Expected code actions as response")
      return
    }
    let quickFixes = codeActions.filter { $0.kind == .quickFix }
    XCTAssertEqual(quickFixes.count, 1)
    guard let fixit = quickFixes.first else { return }

    XCTAssertEqual(fixit.title, "Use 'new(_:hotness:)' instead")
    XCTAssertEqual(fixit.diagnostics?.count, 1)
    XCTAssert(fixit.diagnostics?.first?.message.contains("is deprecated") == true)
    XCTAssertEqual(
      fixit.edit?.changes?[uri],
      [
        TextEdit(range: Position(line: 3, utf16index: 2)..<Position(line: 3, utf16index: 5), newText: "new"),
        TextEdit(range: Position(line: 3, utf16index: 6)..<Position(line: 3, utf16index: 11), newText: ""),
        TextEdit(range: Position(line: 3, utf16index: 14)..<Position(line: 3, utf16index: 20), newText: "hotness"),
      ]
    )
  }

  func testXMLToMarkdownDeclaration() {
    XCTAssertEqual(
      try xmlDocumentationToMarkdown(
        """
        <Declaration>func foo(_ bar: <Type usr="fake">Baz</Type>)</Declaration>
        """
      ),
      """
      ```swift
      func foo(_ bar: Baz)
      ```

      """
    )
    XCTAssertEqual(
      try xmlDocumentationToMarkdown(
        """
        <Declaration>func foo() -&gt; <Type>Bar</Type></Declaration>
        """
      ),
      """
      ```swift
      func foo() -> Bar
      ```

      """
    )
    XCTAssertEqual(
      try xmlDocumentationToMarkdown(
        """
        <Link href="https://example.com">My Link</Link>
        """
      ),
      """
      [My Link](https://example.com)
      """
    )
    XCTAssertEqual(
      try xmlDocumentationToMarkdown(
        """
        <Link>My Invalid Link</Link>
        """
      ),
      """
      My Invalid Link
      """
    )
    XCTAssertEqual(
      try xmlDocumentationToMarkdown(
        """
        <Declaration>func replacingOccurrences&lt;Target, Replacement&gt;(of target: Target, with replacement: Replacement, options: <Type usr="s:SS">String</Type>.<Type usr="s:SS10FoundationE14CompareOptionsa">CompareOptions</Type> = default, range searchRange: <Type usr="s:Sn">Range</Type>&lt;<Type usr="s:SS">String</Type>.<Type usr="s:SS5IndexV">Index</Type>&gt;? = default) -&gt; <Type usr="s:SS">String</Type> where Target : <Type usr="s:Sy">StringProtocol</Type>, Replacement : <Type usr="s:Sy">StringProtocol</Type></Declaration>
        """
      ),
      """
      ```swift
      func replacingOccurrences<Target, Replacement>(of target: Target, with replacement: Replacement, options: String.CompareOptions = default, range searchRange: Range<String.Index>? = default) -> String where Target : StringProtocol, Replacement : StringProtocol
      ```

      """
    )
  }

  func testXMLToMarkdownComment() {
    XCTAssertEqual(
      try xmlDocumentationToMarkdown(
        """
        <Class><Declaration>var foo</Declaration></Class>
        """
      ),
      """
      ```swift
      var foo
      ```

      """
    )

    XCTAssertEqual(
      try xmlDocumentationToMarkdown(
        """
        <Class><Name>foo</Name><Declaration>var foo</Declaration></Class>
        """
      ),
      """
      ```swift
      var foo
      ```

      """
    )
    XCTAssertEqual(
      try xmlDocumentationToMarkdown(
        """
        <Class><USR>asdf</USR><Declaration>var foo</Declaration><Name>foo</Name></Class>
        """
      ),
      """
      ```swift
      var foo
      ```

      """
    )

    XCTAssertEqual(
      try xmlDocumentationToMarkdown(
        """
        <Class><Abstract>FOO</Abstract></Class>
        """
      ),
      """
      FOO
      """
    )
    XCTAssertEqual(
      try xmlDocumentationToMarkdown(
        """
        <Class><Abstract>FOO</Abstract><Declaration>var foo</Declaration></Class>
        """
      ),
      """
      FOO

      ```swift
      var foo
      ```

      """
    )

    XCTAssertEqual(
      try xmlDocumentationToMarkdown(
        """
        <Class><Abstract>FOO</Abstract><Discussion>BAR</Discussion></Class>
        """
      ),
      """
      FOO

      ### Discussion

      BAR
      """
    )

    XCTAssertEqual(
      try xmlDocumentationToMarkdown(
        """
        <Class><Para>A</Para><Para>B</Para><Para>C</Para></Class>
        """
      ),
      """
      A

      B

      C
      """
    )

    XCTAssertEqual(
      try xmlDocumentationToMarkdown(
        """
        <CodeListing>a</CodeListing>
        """
      ),
      """
      ```
      a
      ```


      """
    )

    XCTAssertEqual(
      try xmlDocumentationToMarkdown(
        """
        <CodeListing><zCodeLineNumbered>a</zCodeLineNumbered></CodeListing>
        """
      ),
      """
      ```
      1.\ta
      ```


      """
    )
    XCTAssertEqual(
      try xmlDocumentationToMarkdown(
        """
        <CodeListing><zCodeLineNumbered>a</zCodeLineNumbered><zCodeLineNumbered>b</zCodeLineNumbered></CodeListing>
        """
      ),
      """
      ```
      1.\ta
      2.\tb
      ```


      """
    )
    XCTAssertEqual(
      try xmlDocumentationToMarkdown(
        """
        <Class><CodeListing><zCodeLineNumbered>a</zCodeLineNumbered><zCodeLineNumbered>b</zCodeLineNumbered></CodeListing><CodeListing><zCodeLineNumbered>c</zCodeLineNumbered><zCodeLineNumbered>d</zCodeLineNumbered></CodeListing></Class>
        """
      ),
      """
      ```
      1.\ta
      2.\tb
      ```

      ```
      1.\tc
      2.\td
      ```


      """
    )

    XCTAssertEqual(
      try xmlDocumentationToMarkdown(
        """
        <Para>a b c <codeVoice>d e f</codeVoice> g h i</Para>
        """
      ),
      """
      a b c `d e f` g h i
      """
    )

    XCTAssertEqual(
      try xmlDocumentationToMarkdown(
        """
        <Para>a b c <emphasis>d e f</emphasis> g h i</Para>
        """
      ),
      """
      a b c *d e f* g h i
      """
    )

    XCTAssertEqual(
      try xmlDocumentationToMarkdown(
        """
        <Para>a b c <bold>d e f</bold> g h i</Para>
        """
      ),
      """
      a b c **d e f** g h i
      """
    )

    XCTAssertEqual(
      try xmlDocumentationToMarkdown(
        """
        <Para>a b c<h1>d e f</h1>g h i</Para>
        """
      ),
      """
      a b c

      # d e f

      g h i
      """
    )

    XCTAssertEqual(
      try xmlDocumentationToMarkdown(
        """
        <Para>a b c<h3>d e f</h3>g h i</Para>
        """
      ),
      """
      a b c

      ### d e f

      g h i
      """
    )

    XCTAssertEqual(
      try xmlDocumentationToMarkdown(
        "<Class>" + "<Name>String</Name>" + "<USR>s:SS</USR>" + "<Declaration>struct String</Declaration>"
          + "<CommentParts>" + "<Abstract>" + "<Para>A Unicode s</Para>" + "</Abstract>" + "<Discussion>"
          + "<Para>A string is a series of characters, such as <codeVoice>&quot;Swift&quot;</codeVoice>, that forms a collection. "
          + "The <codeVoice>String</codeVoice> type bridges with the Objective-C class <codeVoice>NSString</codeVoice> and offers"
          + "</Para>" + "<Para>You can create new strings A <emphasis>string literal</emphasis> i" + "</Para>"
          + "<CodeListing language=\"swift\">"
          + "<zCodeLineNumbered><![CDATA[let greeting = \"Welcome!\"]]></zCodeLineNumbered>"
          + "<zCodeLineNumbered></zCodeLineNumbered>" + "</CodeListing>" + "<Para>...</Para>"
          + "<CodeListing language=\"swift\">"
          + "<zCodeLineNumbered><![CDATA[let greeting = \"Welcome!\"]]></zCodeLineNumbered>"
          + "<zCodeLineNumbered></zCodeLineNumbered>" + "</CodeListing>" + "</Discussion>" + "</CommentParts>"
          + "</Class>"
      ),
      """
      ```swift
      struct String
      ```
      A Unicode s

      ### Discussion

      A string is a series of characters, such as `"Swift"`, that forms a collection. The `String` type bridges with the Objective-C class `NSString` and offers

      You can create new strings A *string literal* i

      ```swift
      1.\tlet greeting = "Welcome!"
      2.\t
      ```

      ...

      ```swift
      1.\tlet greeting = "Welcome!"
      2.\t
      ```


      """
    )

    XCTAssertEqual(
      try xmlDocumentationToMarkdown(
        "<Function file=\"DocumentManager.swift\" line=\"92\" column=\"15\">" + "<CommentParts>"
          + "<Abstract><Para>Applies the given edits to the document.</Para></Abstract>" + "<Parameters>"
          + "<Parameter>" + "<Name>editCallback</Name>" + "<Direction isExplicit=\"0\">in</Direction>"
          + "<Discussion><Para>Optional closure to call for each edit.</Para></Discussion>" + "</Parameter>"
          + "<Parameter>" + "<Name>before</Name>" + "<Direction isExplicit=\"0\">in</Direction>"
          + "<Discussion><Para>The document contents <emphasis>before</emphasis> the edit is applied.</Para></Discussion>"
          + "</Parameter>" + "</Parameters>" + "</CommentParts>" + "</Function>"
      ),
      """
      Applies the given edits to the document.

      - Parameters:
          - editCallback: Optional closure to call for each edit.
          - before: The document contents *before* the edit is applied.
      """
    )

    XCTAssertEqual(
      try xmlDocumentationToMarkdown(
        """
        <ResultDiscussion><Para>The contents of the file after all the edits are applied.</Para></ResultDiscussion>
        """
      ),
      """
      ### Returns

      The contents of the file after all the edits are applied.
      """
    )

    XCTAssertEqual(
      try xmlDocumentationToMarkdown(
        """
        <ThrowsDiscussion><Para>Error.missingDocument if the document is not open.</Para></ThrowsDiscussion>
        """
      ),
      """
      ### Throws

      Error.missingDocument if the document is not open.
      """
    )

    XCTAssertEqual(
      try xmlDocumentationToMarkdown(
        "<Class>" + "<Name>S</Name>" + "<USR>s:1a1SV</USR>" + "<Declaration>struct S</Declaration>" + "<CommentParts>"
          + "<Discussion>" + #"<CodeListing language="swift">"# + "<zCodeLineNumbered>" + "<![CDATA[let S = 12456]]>"
          + "</zCodeLineNumbered>" + "<zCodeLineNumbered></zCodeLineNumbered>" + "</CodeListing>" + "<rawHTML>"
          + "<![CDATA[<h2>]]>" + "</rawHTML>Title<rawHTML>" + "<![CDATA[</h2>]]>" + "</rawHTML>"
          + "<Para>Details.</Para>" + "</Discussion>" + "</CommentParts>" + "</Class>"
      ),
      """
      ```swift
      struct S
      ```
      ### Discussion

      ```swift
      1.\tlet S = 12456
      2.\t
      ```

      <h2>Title</h2>

      Details.
      """
    )
  }

  func testSymbolInfo() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let url = URL(fileURLWithPath: "/\(UUID())/a.swift")
    let uri = DocumentURI(url)

    testClient.openDocument(
      """
      import Foundation
      struct S {
        func foo() {
          var local = 1
        }
      }
      """,
      uri: uri
    )

    do {
      let resp = try await testClient.send(
        SymbolInfoRequest(
          textDocument: TextDocumentIdentifier(url),
          position: Position(line: 0, utf16index: 7)
        )
      )

      XCTAssertEqual(resp.count, 1)
      if let sym = resp.first {
        XCTAssertEqual(sym.name, "Foundation")
        XCTAssertNil(sym.containerName)
        XCTAssertEqual(sym.usr, nil)
        XCTAssertEqual(sym.kind, .module)
        XCTAssertEqual(sym.bestLocalDeclaration?.uri, nil)
        XCTAssertEqual(sym.bestLocalDeclaration?.range.lowerBound.line, nil)
        XCTAssertEqual(sym.bestLocalDeclaration?.range.lowerBound.utf16index, nil)
      }
    }

    do {
      let resp = try await testClient.send(
        SymbolInfoRequest(
          textDocument: TextDocumentIdentifier(url),
          position: Position(line: 1, utf16index: 7)
        )
      )

      XCTAssertEqual(resp.count, 1)
      if let sym = resp.first {
        XCTAssertEqual(sym.name, "S")
        XCTAssertNil(sym.containerName)
        XCTAssertEqual(sym.usr, "s:1a1SV")
        XCTAssertEqual(sym.bestLocalDeclaration?.uri, uri)
        XCTAssertEqual(sym.bestLocalDeclaration?.range.lowerBound.line, 1)
        XCTAssertEqual(sym.bestLocalDeclaration?.range.lowerBound.utf16index, 7)
      }
    }

    do {
      let resp = try await testClient.send(
        SymbolInfoRequest(
          textDocument: TextDocumentIdentifier(url),
          position: Position(line: 2, utf16index: 7)
        )
      )

      XCTAssertEqual(resp.count, 1)
      if let sym = resp.first {
        XCTAssertEqual(sym.name, "foo()")
        XCTAssertNil(sym.containerName)
        XCTAssertEqual(sym.usr, "s:1a1SV3fooyyF")
        XCTAssertEqual(sym.bestLocalDeclaration?.uri, uri)
        XCTAssertEqual(sym.bestLocalDeclaration?.range.lowerBound.line, 2)
        XCTAssertEqual(sym.bestLocalDeclaration?.range.lowerBound.utf16index, 7)
      }
    }

    do {
      let resp = try await testClient.send(
        SymbolInfoRequest(
          textDocument: TextDocumentIdentifier(url),
          position: Position(line: 3, utf16index: 8)
        )
      )

      XCTAssertEqual(resp.count, 1)
      if let sym = resp.first {
        XCTAssertEqual(sym.name, "local")
        XCTAssertNil(sym.containerName)
        XCTAssertEqual(sym.usr, "s:1a1SV3fooyyF5localL_Sivp")
        XCTAssertEqual(sym.bestLocalDeclaration?.uri, uri)
        XCTAssertEqual(sym.bestLocalDeclaration?.range.lowerBound.line, 3)
        XCTAssertEqual(sym.bestLocalDeclaration?.range.lowerBound.utf16index, 8)
      }
    }

    do {
      let resp = try await testClient.send(
        SymbolInfoRequest(
          textDocument: TextDocumentIdentifier(url),
          position: Position(line: 3, utf16index: 0)
        )
      )

      XCTAssertEqual(resp.count, 0)
    }
  }

  func testDocumentSymbolHighlight() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let url = URL(fileURLWithPath: "/\(UUID())/a.swift")
    let uri = DocumentURI(url)

    testClient.openDocument(
      """
      func test() {
        let a = 1
        let b = 2
        let ccc = 3
        _ = b
        _ = ccc + ccc
      }
      """,
      uri: uri
    )

    do {
      let resp = try await testClient.send(
        DocumentHighlightRequest(
          textDocument: TextDocumentIdentifier(url),
          position: Position(line: 0, utf16index: 0)
        )
      )
      XCTAssertEqual(resp?.count, 0)
    }

    do {
      let resp = try await testClient.send(
        DocumentHighlightRequest(
          textDocument: TextDocumentIdentifier(url),
          position: Position(line: 1, utf16index: 6)
        )
      )
      XCTAssertEqual(resp?.count, 1)
      if let highlight = resp?.first {
        XCTAssertEqual(highlight.range.lowerBound.line, 1)
        XCTAssertEqual(highlight.range.lowerBound.utf16index, 6)
        XCTAssertEqual(highlight.range.upperBound.line, 1)
        XCTAssertEqual(highlight.range.upperBound.utf16index, 7)
      }
    }

    do {
      let resp = try await testClient.send(
        DocumentHighlightRequest(
          textDocument: TextDocumentIdentifier(url),
          position: Position(line: 2, utf16index: 6)
        )
      )
      XCTAssertEqual(resp?.count, 2)
      if let highlight = resp?.first {
        XCTAssertEqual(highlight.range.lowerBound.line, 2)
        XCTAssertEqual(highlight.range.lowerBound.utf16index, 6)
        XCTAssertEqual(highlight.range.upperBound.line, 2)
        XCTAssertEqual(highlight.range.upperBound.utf16index, 7)
      }
      if let highlight = resp?.dropFirst().first {
        XCTAssertEqual(highlight.range.lowerBound.line, 4)
        XCTAssertEqual(highlight.range.lowerBound.utf16index, 6)
        XCTAssertEqual(highlight.range.upperBound.line, 4)
        XCTAssertEqual(highlight.range.upperBound.utf16index, 7)
      }
    }

    do {
      let resp = try await testClient.send(
        DocumentHighlightRequest(
          textDocument: TextDocumentIdentifier(url),
          position: Position(line: 3, utf16index: 6)
        )
      )
      XCTAssertEqual(resp?.count, 3)
      if let highlight = resp?.first {
        XCTAssertEqual(highlight.range.lowerBound.line, 3)
        XCTAssertEqual(highlight.range.lowerBound.utf16index, 6)
        XCTAssertEqual(highlight.range.upperBound.line, 3)
        XCTAssertEqual(highlight.range.upperBound.utf16index, 9)
      }
      if let highlight = resp?.dropFirst().first {
        XCTAssertEqual(highlight.range.lowerBound.line, 5)
        XCTAssertEqual(highlight.range.lowerBound.utf16index, 6)
        XCTAssertEqual(highlight.range.upperBound.line, 5)
        XCTAssertEqual(highlight.range.upperBound.utf16index, 9)
      }
      if let highlight = resp?.dropFirst(2).first {
        XCTAssertEqual(highlight.range.lowerBound.line, 5)
        XCTAssertEqual(highlight.range.lowerBound.utf16index, 12)
        XCTAssertEqual(highlight.range.upperBound.line, 5)
        XCTAssertEqual(highlight.range.upperBound.utf16index, 15)
      }
    }
  }

  func testIncrementalParse() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let url = URL(fileURLWithPath: "/\(UUID())/a.swift")
    let uri = DocumentURI(url)

    let reusedNodeCallback = self.expectation(description: "reused node callback called")
    let reusedNodes = ThreadSafeBox<[Syntax]>(initialValue: [])
    let swiftLanguageService =
      await testClient.server.languageService(for: uri, .swift, in: testClient.server.workspaceForDocument(uri: uri)!)
      as! SwiftLanguageService
    await swiftLanguageService.setReusedNodeCallback {
      reusedNodes.value.append($0)
      reusedNodeCallback.fulfill()
    }

    testClient.openDocument(
      """
      func foo() {
      }
      class bar {
      }
      """,
      uri: uri
    )

    // Send a request that triggers a syntax tree to be built.
    _ = try await testClient.send(FoldingRangeRequest(textDocument: .init(uri)))

    testClient.send(
      DidChangeTextDocumentNotification(
        textDocument: .init(uri, version: 1),
        contentChanges: [
          .init(range: Range(Position(line: 2, utf16index: 7)), text: "a")
        ]
      )
    )
    try await fulfillmentOfOrThrow([reusedNodeCallback])

    XCTAssertEqual(reusedNodes.value.count, 1)
    let firstNode = try XCTUnwrap(reusedNodes.value.first)
    XCTAssertEqual(
      firstNode.description,
      """
      func foo() {
      }
      """
    )
    XCTAssertEqual(firstNode.kind, .codeBlockItem)
  }

  func testDebouncePublishDiagnosticsNotification() async throws {
    try SkipUnless.longTestsEnabled()

    let options = SourceKitLSPOptions(swiftPublishDiagnosticsDebounceDuration: 1 /* second */)
    let testClient = try await TestSourceKitLSPClient(options: options, usePullDiagnostics: false)

    let uri = DocumentURI(URL(fileURLWithPath: "/\(UUID())/a.swift"))
    testClient.openDocument("foo", uri: uri)

    let edit = TextDocumentContentChangeEvent(
      range: Position(line: 0, utf16index: 0)..<Position(line: 0, utf16index: 3),
      text: "bar"
    )
    testClient.send(
      DidChangeTextDocumentNotification(
        textDocument: VersionedTextDocumentIdentifier(uri, version: 0),
        contentChanges: [edit]
      )
    )

    let diagnostic = try await testClient.nextDiagnosticsNotification()
    let diag = try XCTUnwrap(diagnostic.diagnostics.first)
    XCTAssertEqual(diag.message, "Cannot find 'bar' in scope")

    // Ensure that we don't get a second `PublishDiagnosticsNotification`
    await assertThrowsError(try await testClient.nextDiagnosticsNotification(timeout: .seconds(2)))
  }

  func testSourceKitdTimeout() async throws {
    var options = SourceKitLSPOptions.testDefault()
    options.sourcekitdRequestTimeout = 1 /* second */

    let testClient = try await TestSourceKitLSPClient(options: options)
    let uri = DocumentURI(for: .swift)

    let positions = testClient.openDocument(
      """
      1️⃣class Foo {
        func slow(x: Invalid1, y: Invalid2) {
          x / y / x / y / x / y / x / y.
        }
      }2️⃣
      """,
      uri: uri
    )

    let responseBeforeEdit = try await testClient.send(
      DocumentDiagnosticsRequest(textDocument: TextDocumentIdentifier(uri))
    )
    /// The diagnostic request times out, which causes us to return empty diagnostics.
    XCTAssertEqual(responseBeforeEdit, .full(RelatedFullDocumentDiagnosticReport(items: [])))

    // Now check that sourcekitd is not blocked.
    // Replacing the file and sending another diagnostic request should return proper diagnostics.
    testClient.send(
      DidChangeTextDocumentNotification(
        textDocument: VersionedTextDocumentIdentifier(uri, version: 2),
        contentChanges: [
          TextDocumentContentChangeEvent(range: positions["1️⃣"]..<positions["2️⃣"], text: "let x: String = 1")
        ]
      )
    )
    let responseAfterEdit = try await testClient.send(
      DocumentDiagnosticsRequest(textDocument: TextDocumentIdentifier(uri))
    )
    guard case .full(let responseAfterEdit) = responseAfterEdit else {
      XCTFail("Expected full diagnostics")
      return
    }
    XCTAssertEqual(
      responseAfterEdit.items.map(\.message),
      ["Cannot convert value of type 'Int' to specified type 'String'"]
    )
  }
}
