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

final class PullDiagnosticsTests: XCTestCase {
  enum Error: Swift.Error {
    case unexpectedDiagnosticReport
  }

  /// Connection and lifetime management for the service.
  var connection: TestSourceKitServer! = nil

  /// The primary interface to make requests to the SourceKitServer.
  var sk: TestClient! = nil

  override func setUp() {
    connection = TestSourceKitServer()
    sk = connection.client
    _ = try! sk.sendSync(
      InitializeRequest(
        processId: nil,
        rootPath: nil,
        rootURI: nil,
        initializationOptions: nil,
        capabilities: ClientCapabilities(
          workspace: nil,
          textDocument: .init(
            codeAction: .init(codeActionLiteralSupport: .init(codeActionKind: .init(valueSet: [.quickFix])))
          )
        ),
        trace: .off,
        workspaceFolders: nil
      )
    )
  }

  override func tearDown() {
    sk = nil
    connection = nil
  }

  func performDiagnosticRequest(text: String) throws -> [Diagnostic] {
    let url = URL(fileURLWithPath: "/PullDiagnostics/\(UUID()).swift")

    sk.send(
      DidOpenTextDocumentNotification(
        textDocument: TextDocumentItem(
          uri: DocumentURI(url),
          language: .swift,
          version: 17,
          text: text
        )
      )
    )

    let request = DocumentDiagnosticsRequest(textDocument: TextDocumentIdentifier(url))

    let report: DocumentDiagnosticReport
    do {
      report = try sk.sendSync(request)
    } catch let error as ResponseError where error.message.contains("unknown request: source.request.diagnostics") {
      throw XCTSkip("toolchain does not support source.request.diagnostics request")
    }

    guard case .full(let fullReport) = report else {
      throw Error.unexpectedDiagnosticReport
    }

    return fullReport.items
  }

  func testUnknownIdentifierDiagnostic() throws {
    let diagnostics = try performDiagnosticRequest(
      text: """
        func foo() {
          invalid
        }
        """
    )
    XCTAssertEqual(diagnostics.count, 1)
    let diagnostic = try XCTUnwrap(diagnostics.first)
    XCTAssertEqual(diagnostic.range, Position(line: 1, utf16index: 2)..<Position(line: 1, utf16index: 9))
  }

  /// Test that we can get code actions for pulled diagnostics (https://github.com/apple/sourcekit-lsp/issues/776)
  func testCodeActions() throws {
    let diagnostics = try performDiagnosticRequest(
      text: """
        protocol MyProtocol {
          func bar()
        }

        struct Test: MyProtocol {}
        """
    )
    XCTAssertEqual(diagnostics.count, 1)
    let diagnostic = try XCTUnwrap(diagnostics.first)
    XCTAssertEqual(diagnostic.range, Position(line: 4, utf16index: 7)..<Position(line: 4, utf16index: 7))
    let notification = try XCTUnwrap(diagnostic.relatedInformation?.first)
    XCTAssertEqual(notification.location.range, Position(line: 4, utf16index: 7)..<Position(line: 4, utf16index: 7))
    XCTAssertEqual(notification.codeActions?.count ?? 0, 1)

    let response = try sk.sendSync(
      CodeActionRequest(
        range: notification.location.range,
        context: CodeActionContext(
          diagnostics: diagnostics,
          only: [.quickFix],
          triggerKind: .invoked
        ),
        textDocument: TextDocumentIdentifier(notification.location.uri)
      )
    )

    guard case .codeActions(let actions) = response else {
      XCTFail("Expected codeActions response")
      return
    }

    XCTAssertEqual(actions.count, 1)
    let action = try XCTUnwrap(actions.first)
    // Allow the action message to be the one before or after
    // https://github.com/apple/swift/pull/67909, ensuring this test passes with
    // a sourcekitd that contains the change from that PR as well as older
    // toolchains that don't contain the change yet.
    XCTAssert([
      "add stubs for conformance",
      "do you want to add protocol stubs?"
    ].contains(action.title))
  }
}
