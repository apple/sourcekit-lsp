//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import ISDBTestSupport
import LSPLogging
import LSPTestSupport
import LanguageServerProtocol
import SKSupport
import SKTestSupport
import SourceKitD
import SourceKitLSP
import XCTest

import enum PackageLoading.Platform

fileprivate extension HoverResponse {
  func contains(string: String) -> Bool {
    switch self.contents {
    case .markedStrings(let markedStrings):
      for markedString in markedStrings {
        switch markedString {
        case .markdown(value: let value), .codeBlock(language: _, value: let value):
          if value.contains(string) {
            return true
          }
        }
      }
    case .markupContent(let markdownString):
      if markdownString.value.contains(string) {
        return true
      }
    }
    return false
  }
}

final class CrashRecoveryTests: XCTestCase {
  func testSourcekitdCrashRecovery() async throws {
    try XCTSkipUnless(Platform.current == .darwin, "Linux and Windows use in-process sourcekitd")
    try XCTSkipIf(longTestsDisabled)

    let ws = try await staticSourceKitTibsWorkspace(name: "sourcekitdCrashRecovery")!
    let loc = ws.testLoc("loc")

    // Open the document. Wait for the semantic diagnostics to know it has been fully opened and we are not entering any data races about outstanding diagnostics when we crash sourcekitd.

    let documentOpened = self.expectation(description: "documentOpened")
    documentOpened.expectedFulfillmentCount = 2
    ws.sk.handleNextNotification({ (notification: LanguageServerProtocol.Notification<PublishDiagnosticsNotification>) in
      log("Received diagnostics for open - syntactic")
      documentOpened.fulfill()
    })
    ws.sk.appendOneShotNotificationHandler({
      (notification: LanguageServerProtocol.Notification<PublishDiagnosticsNotification>) in
      log("Received diagnostics for open - semantic")
      documentOpened.fulfill()
    })
    try ws.openDocument(loc.url, language: .swift)
    try await fulfillmentOfOrThrow([documentOpened])

    // Make a change to the file that's not saved to disk. This way we can check that we re-open the correct in-memory state.

    let addFuncChange = TextDocumentContentChangeEvent(
      range: loc.position..<loc.position,
      rangeLength: 0,
      text: """

        func foo() {
          print("Hello world")
        }
        """
    )
    ws.sk.sendNotificationSync(
      DidChangeTextDocumentNotification(
        textDocument: VersionedTextDocumentIdentifier(loc.docUri, version: 2),
        contentChanges: [addFuncChange]
      ),
      { (notification: LanguageServerProtocol.Notification<PublishDiagnosticsNotification>) -> Void in
        log("Received diagnostics for text edit - syntactic")
      },
      { (notification: LanguageServerProtocol.Notification<PublishDiagnosticsNotification>) -> Void in
        log("Received diagnostics for text edit - semantic")
      }
    )

    // Do a sanity check and verify that we get the expected result from a hover response before crashing sourcekitd.

    let hoverRequest = HoverRequest(textDocument: loc.docIdentifier, position: Position(line: 1, utf16index: 6))
    let preCrashHoverResponse = try ws.sk.sendSync(hoverRequest)
    precondition(
      preCrashHoverResponse?.contains(string: "foo()") ?? false,
      "Sanity check failed. The Hover response did not contain foo(), even before crashing sourcekitd. Received response: \(String(describing: preCrashHoverResponse))"
    )

    // Crash sourcekitd

    let sourcekitdServer =
      await ws.testServer.server!._languageService(
        for: loc.docUri,
        .swift,
        in: ws.testServer.server!.workspaceForDocument(uri: loc.docUri)!
      )
      as! SwiftLanguageServer

    let sourcekitdCrashed = expectation(description: "sourcekitd has crashed")
    let sourcekitdRestarted = expectation(description: "sourcekitd has been restarted (syntactic only)")
    let semanticFunctionalityRestored = expectation(
      description: "sourcekitd has restored semantic language functionality"
    )

    await sourcekitdServer.addStateChangeHandler { (oldState, newState) in
      switch newState {
      case .connectionInterrupted:
        sourcekitdCrashed.fulfill()
      case .semanticFunctionalityDisabled:
        sourcekitdRestarted.fulfill()
      case .connected:
        semanticFunctionalityRestored.fulfill()
      }
    }

    await sourcekitdServer._crash()

    try await fulfillmentOfOrThrow([sourcekitdCrashed], timeout: 5)
    try await fulfillmentOfOrThrow([sourcekitdRestarted], timeout: 30)

    // Check that we have syntactic functionality again

    _ = try ws.sk.sendSync(FoldingRangeRequest(textDocument: loc.docIdentifier))

    // sourcekitd's semantic request timer is only started when the first semantic request comes in.
    // Send a hover request (which will fail) to trigger that timer.
    // Afterwards wait for semantic functionality to be restored.
    _ = try? ws.sk.sendSync(hoverRequest)
    try await fulfillmentOfOrThrow([semanticFunctionalityRestored], timeout: 30)

    // Check that we get the same hover response from the restored in-memory state

    assertNoThrow {
      let postCrashHoverResponse = try ws.sk.sendSync(hoverRequest)
      XCTAssertTrue(postCrashHoverResponse?.contains(string: "foo()") ?? false)
    }
  }

  /// Crashes clangd and waits for it to restart
  /// - Parameters:
  ///   - ws: The workspace for which the clangd server shall be crashed
  ///   - document: The URI of a C/C++/... document in the workspace
  private func crashClangd(for ws: SKTibsTestWorkspace, document docUri: DocumentURI) async throws {
    let clangdServer = await ws.testServer.server!._languageService(
      for: docUri,
      .cpp,
      in: ws.testServer.server!.workspaceForDocument(uri: docUri)!
    )!

    let clangdCrashed = self.expectation(description: "clangd crashed")
    let clangdRestarted = self.expectation(description: "clangd restarted")

    await clangdServer.addStateChangeHandler { (oldState, newState) in
      switch newState {
      case .connectionInterrupted:
        clangdCrashed.fulfill()
      case .connected:
        clangdRestarted.fulfill()
      default:
        break
      }
    }

    await clangdServer._crash()

    try await fulfillmentOfOrThrow([clangdCrashed])
    try await fulfillmentOfOrThrow([clangdRestarted])
  }

  func testClangdCrashRecovery() async throws {
    try XCTSkipIf(longTestsDisabled)

    let ws = try await staticSourceKitTibsWorkspace(name: "ClangCrashRecovery")!
    let loc = ws.testLoc("loc")

    try ws.openDocument(loc.url, language: .cpp)

    // Make a change to the file that's not saved to disk. This way we can check that we re-open the correct in-memory state.

    let addFuncChange = TextDocumentContentChangeEvent(
      range: loc.position..<loc.position,
      rangeLength: 0,
      text: """

        void main() {
        }
        """
    )
    ws.sk.send(
      DidChangeTextDocumentNotification(
        textDocument: VersionedTextDocumentIdentifier(loc.docUri, version: 2),
        contentChanges: [addFuncChange]
      )
    )

    // Do a sanity check and verify that we get the expected result from a hover response before crashing clangd.

    let expectedHoverRange = Position(line: 1, utf16index: 5)..<Position(line: 1, utf16index: 9)

    let hoverRequest = HoverRequest(textDocument: loc.docIdentifier, position: Position(line: 1, utf16index: 6))
    let preCrashHoverResponse = try ws.sk.sendSync(hoverRequest)
    precondition(
      preCrashHoverResponse?.range == expectedHoverRange,
      "Sanity check failed. The Hover response was not what we expected, even before crashing sourcekitd"
    )

    // Crash clangd

    try await crashClangd(for: ws, document: loc.docUri)

    // Check that we have re-opened the document with the correct in-memory state

    assertNoThrow {
      let postCrashHoverResponse = try ws.sk.sendSync(hoverRequest)
      XCTAssertEqual(postCrashHoverResponse?.range, expectedHoverRange)
    }
  }

  func testClangdCrashRecoveryReopensWithCorrectBuildSettings() async throws {
    try XCTSkipIf(longTestsDisabled)

    let ws = try await staticSourceKitTibsWorkspace(name: "ClangCrashRecoveryBuildSettings")!
    let loc = ws.testLoc("loc")

    try ws.openDocument(loc.url, language: .cpp)

    // Do a sanity check and verify that we get the expected result from a hover response before crashing clangd.

    let expectedHighlightResponse = [
      DocumentHighlight(range: Position(line: 3, utf16index: 5)..<Position(line: 3, utf16index: 8), kind: .text),
      DocumentHighlight(range: Position(line: 9, utf16index: 2)..<Position(line: 9, utf16index: 5), kind: .text),
    ]

    let highlightRequest = DocumentHighlightRequest(
      textDocument: loc.docIdentifier,
      position: Position(line: 9, utf16index: 3)
    )
    let preCrashHighlightResponse = try ws.sk.sendSync(highlightRequest)
    precondition(
      preCrashHighlightResponse == expectedHighlightResponse,
      "Sanity check failed. The Hover response was not what we expected, even before crashing sourcekitd"
    )

    // Crash clangd

    try await crashClangd(for: ws, document: loc.docUri)

    // Check that we have re-opened the document with the correct build settings
    // If we did not recover the correct build settings, document highlight would
    // pick the definition of foo() in the #else branch.

    assertNoThrow {
      let postCrashHighlightResponse = try ws.sk.sendSync(highlightRequest)
      XCTAssertEqual(postCrashHighlightResponse, expectedHighlightResponse)
    }
  }

  func testPreventClangdCrashLoop() async throws {
    try XCTSkipIf(longTestsDisabled)

    let ws = try await staticSourceKitTibsWorkspace(name: "ClangCrashRecovery")!
    let loc = ws.testLoc("loc")

    try ws.openDocument(loc.url, language: .cpp)

    // Send a nonsensical request to wait for clangd to start up

    let hoverRequest = HoverRequest(textDocument: loc.docIdentifier, position: Position(line: 1, utf16index: 6))
    _ = try ws.sk.sendSync(hoverRequest)

    // Keep track of clangd crashes

    let clangdServer = await ws.testServer.server!._languageService(
      for: loc.docUri,
      .cpp,
      in: ws.testServer.server!.workspaceForDocument(uri: loc.docUri)!
    )!

    let clangdCrashed = self.expectation(description: "clangd crashed")
    clangdCrashed.assertForOverFulfill = false

    let clangdRestartedFirstTime = self.expectation(description: "clangd restarted for the first time")
    let clangdRestartedSecondTime = self.expectation(description: "clangd restarted for the second time")

    var clangdHasRestartedFirstTime = false

    await clangdServer.addStateChangeHandler { (oldState, newState) in
      switch newState {
      case .connectionInterrupted:
        clangdCrashed.fulfill()
      case .connected:
        if !clangdHasRestartedFirstTime {
          clangdRestartedFirstTime.fulfill()
          clangdHasRestartedFirstTime = true
        } else {
          clangdRestartedSecondTime.fulfill()
        }
      default:
        break
      }
    }

    await clangdServer._crash()

    try await fulfillmentOfOrThrow([clangdCrashed], timeout: 5)
    try await fulfillmentOfOrThrow([clangdRestartedFirstTime], timeout: 30)
    // Clangd has restarted. Note the date so we can check that the second restart doesn't happen too quickly.
    let firstRestartDate = Date()

    // Crash clangd again. This time, it should only restart after a delay.
    await clangdServer._crash()

    try await fulfillmentOfOrThrow([clangdRestartedSecondTime], timeout: 30)
    XCTAssert(
      Date().timeIntervalSince(firstRestartDate) > 5,
      "Clangd restarted too quickly after crashing twice in a row. We are not preventing crash loops."
    )
  }
}
