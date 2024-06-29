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
import SKSupport
import SKTestSupport
import SourceKitLSP
import XCTest

final class PullDiagnosticsTests: XCTestCase {
  func testUnknownIdentifierDiagnostic() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)

    testClient.openDocument(
      """
      func foo() {
        invalid
      }
      """,
      uri: uri
    )

    let report = try await testClient.send(DocumentDiagnosticsRequest(textDocument: TextDocumentIdentifier(uri)))
    guard case .full(let fullReport) = report else {
      XCTFail("Expected full diagnostics report")
      return
    }

    XCTAssertEqual(fullReport.items.count, 1)
    let diagnostic = try XCTUnwrap(fullReport.items.first)
    XCTAssertEqual(diagnostic.range, Position(line: 1, utf16index: 2)..<Position(line: 1, utf16index: 9))
  }

  /// Test that we can get code actions for pulled diagnostics (https://github.com/swiftlang/sourcekit-lsp/issues/776)
  func testCodeActions() async throws {
    let testClient = try await TestSourceKitLSPClient(
      capabilities: ClientCapabilities(
        workspace: nil,
        textDocument: .init(
          codeAction: .init(codeActionLiteralSupport: .init(codeActionKind: .init(valueSet: [.quickFix])))
        )
      )
    )
    let uri = DocumentURI(for: .swift)

    let positions = testClient.openDocument(
      """
      protocol MyProtocol {
        func bar()
      }

      struct 1️⃣Test: 2️⃣MyProtocol {}
      """,
      uri: uri
    )
    let report = try await testClient.send(DocumentDiagnosticsRequest(textDocument: TextDocumentIdentifier(uri)))
    guard case .full(let fullReport) = report else {
      XCTFail("Expected full diagnostics report")
      return
    }
    let diagnostics = fullReport.items

    XCTAssertEqual(diagnostics.count, 1)
    let diagnostic = try XCTUnwrap(diagnostics.first)
    XCTAssert(
      diagnostic.range == Range(positions["1️⃣"]) || diagnostic.range == Range(positions["2️⃣"]),
      "Unexpected range: \(diagnostic.range)"
    )
    let note = try XCTUnwrap(diagnostic.relatedInformation?.first)
    XCTAssert(
      note.location.range == Range(positions["1️⃣"]) || note.location.range == Range(positions["2️⃣"]),
      "Unexpected range: \(note.location.range)"
    )
    XCTAssertEqual(note.codeActions?.count ?? 0, 1)

    let response = try await testClient.send(
      CodeActionRequest(
        range: note.location.range,
        context: CodeActionContext(
          diagnostics: diagnostics,
          only: [.quickFix],
          triggerKind: .invoked
        ),
        textDocument: TextDocumentIdentifier(note.location.uri)
      )
    )

    guard case .codeActions(let actions) = response else {
      XCTFail("Expected codeActions response")
      return
    }

    XCTAssertEqual(actions.count, 2)
    XCTAssert(
      actions.contains { action in
        // Allow the action message to be the one before or after
        // https://github.com/apple/swift/pull/67909, ensuring this test passes with
        // a sourcekitd that contains the change from that PR as well as older
        // toolchains that don't contain the change yet.
        [
          "Add stubs for conformance",
          "Do you want to add protocol stubs?",
        ].contains(action.title)
      }
    )
  }

  func testNotesFromIntegratedSwiftSyntaxDiagnostics() async throws {
    // Create a workspace that has compile_commands.json so that it has a build system but no compiler arguments
    // for test.swift so that we fall back to producing diagnostics from the built-in swift-syntax.
    let project = try await MultiFileTestProject(files: [
      "test.swift": "func foo() 1️⃣{2️⃣",
      "compile_commands.json": "[]",
    ])

    let (uri, positions) = try project.openDocument("test.swift")

    let report = try await project.testClient.send(
      DocumentDiagnosticsRequest(textDocument: TextDocumentIdentifier(uri))
    )
    guard case .full(let fullReport) = report else {
      XCTFail("Expected full diagnostics report")
      return
    }
    XCTAssertEqual(fullReport.items.count, 1)
    let diagnostic = try XCTUnwrap(fullReport.items.first)
    XCTAssertEqual(diagnostic.message, "expected '}' to end function")
    XCTAssertEqual(diagnostic.range, Range(positions["2️⃣"]))

    XCTAssertEqual(diagnostic.relatedInformation?.count, 1)
    let note = try XCTUnwrap(diagnostic.relatedInformation?.first)
    XCTAssertEqual(note.message, "to match this opening '{'")
    XCTAssertEqual(note.location.range, positions["1️⃣"]..<positions["2️⃣"])
  }

  func testDiagnosticUpdatedAfterFilesInSameModuleAreUpdated() async throws {
    try SkipUnless.longTestsEnabled()

    let project = try await SwiftPMTestProject(
      files: [
        "FileA.swift": "",
        "FileB.swift": """
        func test() {
          sayHello()
        }
        """,
      ]
    )

    let (bUri, _) = try project.openDocument("FileB.swift")
    let beforeChangingFileA = try await project.testClient.send(
      DocumentDiagnosticsRequest(textDocument: TextDocumentIdentifier(bUri))
    )
    guard case .full(let fullReportBeforeChangingFileA) = beforeChangingFileA else {
      XCTFail("Expected full diagnostics report")
      return
    }
    XCTAssert(fullReportBeforeChangingFileA.items.contains(where: { $0.message == "Cannot find 'sayHello' in scope" }))

    let diagnosticsRefreshRequestReceived = self.expectation(description: "DiagnosticsRefreshRequest received")
    project.testClient.handleSingleRequest { (request: DiagnosticsRefreshRequest) in
      diagnosticsRefreshRequestReceived.fulfill()
      return VoidResponse()
    }

    let updatedACode = "func sayHello() {}"
    let aUri = try project.uri(for: "FileA.swift")
    try updatedACode.write(to: try XCTUnwrap(aUri.fileURL), atomically: true, encoding: .utf8)
    project.testClient.send(
      DidChangeWatchedFilesNotification(changes: [FileEvent(uri: aUri, type: .changed)])
    )

    try await self.fulfillmentOfOrThrow([diagnosticsRefreshRequestReceived])

    let afterChangingFileA = try await project.testClient.send(
      DocumentDiagnosticsRequest(textDocument: TextDocumentIdentifier(bUri))
    )
    XCTAssertEqual(afterChangingFileA, .full(RelatedFullDocumentDiagnosticReport(items: [])))
  }

  func testDiagnosticUpdatedAfterDependentModuleIsBuilt() async throws {
    try SkipUnless.longTestsEnabled()

    let project = try await SwiftPMTestProject(
      files: [
        "LibA/LibA.swift": """
        public func 1️⃣sayHello() {}
        """,
        "LibB/LibB.swift": """
        import LibA

        func test() {
          2️⃣sayHello()
        }
        """,
      ],
      manifest: """
        let package = Package(
          name: "MyLibrary",
          targets: [
            .target(name: "LibA"),
            .target(name: "LibB", dependencies: ["LibA"]),
          ]
        )
        """
    )

    let (bUri, _) = try project.openDocument("LibB.swift")
    let beforeBuilding = try await project.testClient.send(
      DocumentDiagnosticsRequest(textDocument: TextDocumentIdentifier(bUri))
    )
    guard case .full(let fullReportBeforeBuilding) = beforeBuilding else {
      XCTFail("Expected full diagnostics report")
      return
    }
    XCTAssert(
      fullReportBeforeBuilding.items.contains(where: {
        #if compiler(>=6.1)
        #warning("When we drop support for Swift 5.10 we no longer need to check for the Objective-C error message")
        #endif
        return $0.message == "No such module 'LibA'" || $0.message == "Could not build Objective-C module 'LibA'"
      })
    )

    let diagnosticsRefreshRequestReceived = self.expectation(description: "DiagnosticsRefreshRequest received")
    project.testClient.handleSingleRequest { (request: DiagnosticsRefreshRequest) in
      diagnosticsRefreshRequestReceived.fulfill()
      return VoidResponse()
    }

    try await SwiftPMTestProject.build(at: project.scratchDirectory)

    project.testClient.send(
      DidChangeWatchedFilesNotification(
        changes:
          FileManager.default.findFiles(withExtension: "swiftmodule", in: project.scratchDirectory).map {
            FileEvent(uri: DocumentURI($0), type: .created)
          }
      )
    )

    try await self.fulfillmentOfOrThrow([diagnosticsRefreshRequestReceived])

    let afterChangingFileA = try await project.testClient.send(
      DocumentDiagnosticsRequest(textDocument: TextDocumentIdentifier(bUri))
    )
    XCTAssertEqual(afterChangingFileA, .full(RelatedFullDocumentDiagnosticReport(items: [])))
  }

  func testDiagnosticsWaitForDocumentToBePrepared() async throws {
    let diagnosticRequestSent = AtomicBool(initialValue: false)
    var testHooks = TestHooks()
    testHooks.indexTestHooks.preparationTaskDidStart = { @Sendable taskDescription in
      // Only start preparation after we sent the diagnostic request. In almost all cases, this should not give
      // preparation enough time to finish before the diagnostic request is handled unless we wait for preparation in
      // the diagnostic request.
      while diagnosticRequestSent.value == false {
        do {
          try await Task.sleep(for: .seconds(0.01))
        } catch {
          XCTFail("Did not expect sleep to fail")
          break
        }
      }
    }

    let project = try await SwiftPMTestProject(
      files: [
        "LibA/LibA.swift": """
        public func sayHello() {}
        """,
        "LibB/LibB.swift": """
        import LibA

        func test() {
          sayHello()
        }
        """,
      ],
      manifest: """
        let package = Package(
          name: "MyLibrary",
          targets: [
            .target(name: "LibA"),
            .target(name: "LibB", dependencies: ["LibA"]),
          ]
        )
        """,
      testHooks: testHooks,
      enableBackgroundIndexing: true,
      pollIndex: false
    )

    let (uri, _) = try project.openDocument("LibB.swift")

    // Use completion handler based method to send request so we can fulfill `diagnosticRequestSent` after sending it
    // but before receiving a reply. The async variant doesn't allow this distinction.
    let receivedDiagnostics = self.expectation(description: "Received diagnostics")
    project.testClient.send(DocumentDiagnosticsRequest(textDocument: TextDocumentIdentifier(uri))) { diagnostics in
      XCTAssertEqual(diagnostics.success, .full(RelatedFullDocumentDiagnosticReport(items: [])))
      receivedDiagnostics.fulfill()
    }
    diagnosticRequestSent.value = true
    try await fulfillmentOfOrThrow([receivedDiagnostics])
  }

  func testDontReturnEmptyDiagnosticsIfDiagnosticRequestIsCancelled() async throws {
    let diagnosticRequestCancelled = self.expectation(description: "diagnostic request cancelled")
    var testHooks = TestHooks()
    testHooks.indexTestHooks.preparationTaskDidStart = { _ in
      await self.fulfillment(of: [diagnosticRequestCancelled], timeout: defaultTimeout)
      // Poll until the `CancelRequestNotification` has been propagated to the request handling.
      for _ in 0..<Int(defaultTimeout * 100) {
        if Task.isCancelled {
          break
        }
        usleep(10_000)
      }
    }
    let project = try await SwiftPMTestProject(
      files: [
        "Lib.swift": "let x: String = 1"
      ],
      testHooks: testHooks,
      enableBackgroundIndexing: true,
      pollIndex: false
    )
    let (uri, _) = try project.openDocument("Lib.swift")

    let diagnosticResponseReceived = self.expectation(description: "Received diagnostic response")
    let requestID = project.testClient.send(
      DocumentDiagnosticsRequest(textDocument: TextDocumentIdentifier(uri))
    ) { result in
      XCTAssertEqual(result, .failure(ResponseError.cancelled))
      diagnosticResponseReceived.fulfill()
    }
    project.testClient.send(CancelRequestNotification(id: requestID))
    diagnosticRequestCancelled.fulfill()
    try await fulfillmentOfOrThrow([diagnosticResponseReceived])
  }

  func testNoteInSecondaryFile() async throws {
    let project = try await SwiftPMTestProject(files: [
      "FileA.swift": """
      @available(*, unavailable)
      struct 1️⃣Test {}
      """,
      "FileB.swift": """
      func test() {
          _ = Test()
      }
      """,
    ])

    let (uri, _) = try project.openDocument("FileB.swift")
    let diagnostics = try await project.testClient.send(
      DocumentDiagnosticsRequest(textDocument: TextDocumentIdentifier(uri))
    )
    guard case .full(let diagnostics) = diagnostics else {
      XCTFail("Expected full diagnostics report")
      return
    }
    let diagnostic = try XCTUnwrap(diagnostics.items.only)
    let note = try XCTUnwrap(diagnostic.relatedInformation?.only)
    XCTAssertEqual(note.location, try project.location(from: "1️⃣", to: "1️⃣", in: "FileA.swift"))
  }
}
