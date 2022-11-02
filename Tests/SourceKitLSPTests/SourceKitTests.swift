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

import ISDBTestSupport
import LanguageServerProtocol
import LSPTestSupport
import SKCore
import SKTestSupport
import TSCBasic
import XCTest

public typealias URL = Foundation.URL

final class SKTests: XCTestCase {

    func testInitLocal() {
      let c = TestSourceKitServer()
      defer { withExtendedLifetime(c) {} } // Keep connection alive for callbacks.

      let sk = c.client

      let initResult = try! sk.sendSync(InitializeRequest(
        processId: nil,
        rootPath: nil,
        rootURI: nil,
        initializationOptions: nil,
        capabilities: ClientCapabilities(workspace: nil, textDocument: nil),
        trace: .off,
        workspaceFolders: nil))

      XCTAssertEqual(initResult.capabilities.textDocumentSync?.openClose, true)
      XCTAssertNotNil(initResult.capabilities.completionProvider)
    }

    func testInitJSON() {
      let c = TestSourceKitServer(connectionKind: .jsonrpc)
      defer { withExtendedLifetime(c) {} } // Keep connection alive for callbacks.

      let sk = c.client

      let initResult = try! sk.sendSync(InitializeRequest(
        processId: nil,
        rootPath: nil,
        rootURI: nil,
        initializationOptions: nil,
        capabilities: ClientCapabilities(workspace: nil, textDocument: nil),
        trace: .off,
        workspaceFolders: nil))

      XCTAssertEqual(initResult.capabilities.textDocumentSync?.openClose, true)
      XCTAssertNotNil(initResult.capabilities.completionProvider)
    }

  func testIndexSwiftModules() throws {
    guard let ws = try staticSourceKitTibsWorkspace(name: "SwiftModules") else { return }
    try ws.buildAndIndex()
    defer { withExtendedLifetime(ws) {} } // Keep workspace alive for callbacks.

    let locDef = ws.testLoc("aaa:def")
    let locRef = ws.testLoc("aaa:call:c")

    try ws.openDocument(locDef.url, language: .swift)
    try ws.openDocument(locRef.url, language: .swift)

    // MARK: Jump to definition

    let response = try ws.sk.sendSync(DefinitionRequest(
      textDocument: locRef.docIdentifier,
      position: locRef.position))
    guard case .locations(let jump) = response else {
      XCTFail("Response is not locations")
      return
    }

    XCTAssertEqual(jump.count, 1)
    XCTAssertEqual(jump.first?.uri, try locDef.docUri.nativeURI)
    XCTAssertEqual(jump.first?.range.lowerBound, locDef.position)

    // MARK: Find references

    let refs = try ws.sk.sendSync(ReferencesRequest(
      textDocument: locDef.docIdentifier,
      position: locDef.position,
      context: ReferencesContext(includeDeclaration: true)))

    let call = ws.testLoc("aaa:call")
    XCTAssertEqual(Set(refs), [
      Location(TestLocation(url: URL(fileURLWithPath: try resolveSymlinks(AbsolutePath(locDef.url.path)).pathString), line: locDef.line, utf8Column: locDef.utf8Column, utf16Column: locDef.utf16Column)),
      Location(TestLocation(url: URL(fileURLWithPath: try resolveSymlinks(AbsolutePath(locRef.url.path)).pathString), line: locRef.line, utf8Column: locRef.utf8Column, utf16Column: locRef.utf16Column)),
      Location(TestLocation(url: URL(fileURLWithPath: try resolveSymlinks(AbsolutePath(call.url.path)).pathString), line: call.line, utf8Column: call.utf8Column, utf16Column: call.utf16Column)),
    ])
  }

  func testIndexShutdown() throws {

    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("sk-test-data/\(testDirectoryName)", isDirectory: true)

    func listdir(_ url: URL) throws -> [URL] {
      try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }

    func checkRunningIndex(build: Bool) throws -> URL? {
      guard let ws = try staticSourceKitTibsWorkspace(
        name: "SwiftModules", tmpDir: tmpDir, removeTmpDir: false)
      else {
        return nil
      }

      if build {
        try ws.buildAndIndex()
      }

      let locDef = ws.testLoc("aaa:def")
      let locRef = ws.testLoc("aaa:call:c")
      try ws.openDocument(locRef.url, language: .swift)
      let response = try ws.sk.sendSync(DefinitionRequest(
        textDocument: locRef.docIdentifier,
        position: locRef.position))
      guard case .locations(let jump) = response else {
        XCTFail("Response is not locations")
        return nil
      }
      XCTAssertEqual(jump.count, 1)
      XCTAssertEqual(jump.first?.uri, try locDef.docUri.nativeURI)
      XCTAssertEqual(jump.first?.range.lowerBound, locDef.position)

      let tmpContents = try listdir(tmpDir)
      guard let versionedPath = tmpContents.filter({ $0.lastPathComponent.starts(with: "v") }).spm_only else {
        XCTFail("expected one version path 'v[0-9]*', found \(tmpContents)")
        return nil
      }

      let versionContentsBefore = try listdir(versionedPath)
      XCTAssertEqual(versionContentsBefore.count, 1)
      XCTAssert(versionContentsBefore.first?.lastPathComponent.starts(with: "p") ?? false)

      try withExtendedLifetime(ws) {
        _ = try ws.sk.sendSync(ShutdownRequest())
      }
      return versionedPath
    }

    guard let versionedPath = try checkRunningIndex(build: true) else { return }

    let versionContentsAfter = try listdir(versionedPath)
    XCTAssertEqual(versionContentsAfter.count, 1)
    XCTAssertEqual(versionContentsAfter.first?.lastPathComponent, "saved")

    _ = try checkRunningIndex(build: true)

    try FileManager.default.removeItem(atPath: tmpDir.path)
  }

  func testCodeCompleteSwiftTibs() throws {
    guard let ws = try staticSourceKitTibsWorkspace(name: "CodeCompleteSingleModule") else { return }
    let loc = ws.testLoc("cc:A")
    try ws.openDocument(loc.url, language: .swift)

    let results = try withExtendedLifetime(ws) { try ws.sk.sendSync(
      CompletionRequest(textDocument: loc.docIdentifier, position: loc.position))
    }

    XCTAssertEqual(results.items, [
      CompletionItem(
        label: "method(a: Int)",
        kind: .method,
        detail: "Void",
        sortText: nil,
        filterText: "method(a:)",
        textEdit: TextEdit(range: Position(line: 1, utf16index: 14)..<Position(line: 1, utf16index: 14), newText: "method(a: )"),
        insertText: "method(a: )",
        insertTextFormat: .plain,
        deprecated: false,
        data: .dictionary(["textDocURI": .string(loc.url.absoluteString), "usr": .string("s:4main1AV6method1aySi_tF")])),
      CompletionItem(
        label: "self",
        kind: .keyword,
        detail: "A",
        sortText: nil,
        filterText: "self",
        textEdit: TextEdit(range: Position(line: 1, utf16index: 14)..<Position(line: 1, utf16index: 14), newText: "self"),
        insertText: "self",
        insertTextFormat: .plain,
        deprecated: false,
        data: .dictionary(["textDocURI": .string(loc.url.absoluteString)])),
    ])
  }

  func testDependenciesUpdatedSwiftTibs() throws {
    guard let ws = try mutableSourceKitTibsTestWorkspace(name: "SwiftModules") else { return }
    defer { withExtendedLifetime(ws) {} } // Keep workspace alive for callbacks.
    guard let server = ws.testServer.server else {
      XCTFail("Unable to fetch SourceKitServer to notify for build system events.")
      return
    }

    let moduleRef = ws.testLoc("aaa:call:c")
    let startExpectation = XCTestExpectation(description: "initial diagnostics")
    startExpectation.expectedFulfillmentCount = 2
    ws.sk.handleNextNotification { (note: Notification<PublishDiagnosticsNotification>) in
      // Semantic analysis: no errors expected here.
      XCTAssertEqual(note.params.diagnostics.count, 0)
      startExpectation.fulfill()
    }
    ws.sk.appendOneShotNotificationHandler  { (note: Notification<PublishDiagnosticsNotification>) in
      // Semantic analysis: expect module import error.
      XCTAssertEqual(note.params.diagnostics.count, 1)
      if let diagnostic = note.params.diagnostics.first {
        XCTAssert(diagnostic.message.contains("no such module"),
                  "expected module import error but found \"\(diagnostic.message)\"")
      }
      startExpectation.fulfill()
    }

    try ws.openDocument(moduleRef.url, language: .swift)
    let started = XCTWaiter.wait(for: [startExpectation], timeout: defaultTimeout)
    if started != .completed {
      fatalError("error \(started) waiting for initial diagnostics notification")
    }

    try ws.buildAndIndex()

    let finishExpectation = XCTestExpectation(description: "post-build diagnostics")
    finishExpectation.expectedFulfillmentCount = 2
    ws.sk.handleNextNotification { (note: Notification<PublishDiagnosticsNotification>) in
      // Semantic analysis - SourceKit currently caches diagnostics so we still see an error.
      XCTAssertEqual(note.params.diagnostics.count, 1)
      finishExpectation.fulfill()
    }
    ws.sk.appendOneShotNotificationHandler  { (note: Notification<PublishDiagnosticsNotification>) in
      // Semantic analysis: no more errors expected, import should resolve since we built.
      XCTAssertEqual(note.params.diagnostics.count, 0)
      finishExpectation.fulfill()
    }
    server.filesDependenciesUpdated([DocumentURI(moduleRef.url)])

    let finished = XCTWaiter.wait(for: [finishExpectation], timeout: defaultTimeout)
    if finished != .completed {
      fatalError("error \(finished) waiting for post-build diagnostics notification")
    }
  }

  func testDependenciesUpdatedCXXTibs() throws {
    guard let ws = try mutableSourceKitTibsTestWorkspace(name: "GeneratedHeader") else { return }
    defer { withExtendedLifetime(ws) {} } // Keep workspace alive for callbacks.
    guard let server = ws.testServer.server else {
      XCTFail("Unable to fetch SourceKitServer to notify for build system events.")
      return
    }

    let moduleRef = ws.testLoc("libX:call:main")
    let startExpectation = XCTestExpectation(description: "initial diagnostics")
    ws.sk.handleNextNotification { (note: Notification<PublishDiagnosticsNotification>) in
      // Expect one error:
      // - Implicit declaration of function invalid
      XCTAssertEqual(note.params.diagnostics.count, 1)
      startExpectation.fulfill()
    }

    let generatedHeaderURL = moduleRef.url.deletingLastPathComponent()
        .appendingPathComponent("lib-generated.h", isDirectory: false)

    // Write an empty header file first since clangd doesn't handle missing header
    // files without a recently upstreamed extension.
    try "".write(to: generatedHeaderURL, atomically: true, encoding: .utf8)
    try ws.openDocument(moduleRef.url, language: .c)
    let started = XCTWaiter.wait(for: [startExpectation], timeout: defaultTimeout)
    guard started == .completed else {
      XCTFail("error \(started) waiting for initial diagnostics notification")
      return
    }

    // Update the header file to have the proper contents for our code to build.
    let contents = "int libX(int value);"
    try contents.write(to: generatedHeaderURL, atomically: true, encoding: .utf8)
    try ws.buildAndIndex()

    let finishExpectation = XCTestExpectation(description: "post-build diagnostics")
    ws.sk.handleNextNotification { (note: Notification<PublishDiagnosticsNotification>) in
      // No more errors expected, import should resolve since we the generated header file
      // now has the proper contents.
      XCTAssertEqual(note.params.diagnostics.count, 0)
      finishExpectation.fulfill()
    }
    server.filesDependenciesUpdated([DocumentURI(moduleRef.url)])

    let finished = XCTWaiter.wait(for: [finishExpectation], timeout: defaultTimeout)
    guard finished == .completed else {
      XCTFail("error \(finished) waiting for post-build diagnostics notification")
      return
    }
  }

  func testClangdGoToInclude() throws {
    guard let ws = try staticSourceKitTibsWorkspace(name: "BasicCXX") else { return }
    guard ToolchainRegistry.shared.default?.clangd != nil else { return }

    let mainLoc = ws.testLoc("Object:include:main")
    let expectedDoc = ws.testLoc("Object").docIdentifier.uri
    let includePosition =
        Position(line: mainLoc.position.line, utf16index: mainLoc.utf16Column + 2)

    try ws.openDocument(mainLoc.url, language: .c)

    let goToInclude = DefinitionRequest(
      textDocument: mainLoc.docIdentifier, position: includePosition)
    let resp = try withExtendedLifetime(ws) { try ws.sk.sendSync(goToInclude) }

    let locationsOrLinks = try XCTUnwrap(resp, "No response for go-to-#include")
    switch locationsOrLinks {
    case .locations(let locations):
      XCTAssert(!locations.isEmpty, "Found no locations for go-to-#include")
      if let loc = locations.first {
        XCTAssertEqual(loc.uri, expectedDoc)
      }
    case .locationLinks(let locationLinks):
      XCTAssert(!locationLinks.isEmpty, "Found no location links for go-to-#include")
      if let link = locationLinks.first {
        XCTAssertEqual(link.targetUri, expectedDoc)
      }
    }
  }

  func testClangdGoToDefinitionWithoutIndex() throws {
    guard let ws = try staticSourceKitTibsWorkspace(name: "BasicCXX") else { return }
    guard ToolchainRegistry.shared.default?.clangd != nil else { return }

    let refLoc = ws.testLoc("Object:ref:main")
    let expectedDoc = try ws.testLoc("Object").docIdentifier.uri.nativeURI
    let refPos = Position(line: refLoc.position.line, utf16index: refLoc.utf16Column + 2)

    try ws.openDocument(refLoc.url, language: .c)

    let goToDefinition = DefinitionRequest(
      textDocument: refLoc.docIdentifier, position: refPos)
    let resp = try withExtendedLifetime(ws) { try ws.sk.sendSync(goToDefinition) }

    let locationsOrLinks = try XCTUnwrap(resp, "No response for go-to-definition")
    switch locationsOrLinks {
    case .locations(let locations):
      XCTAssert(!locations.isEmpty, "Found no locations for go-to-definition")
      if let loc = locations.first {
        XCTAssertEqual(loc.uri, expectedDoc)
      }
    case .locationLinks(let locationLinks):
      XCTAssert(!locationLinks.isEmpty, "Found no location links for go-to-definition")
      if let link = locationLinks.first {
        XCTAssertEqual(link.targetUri, expectedDoc)
      }
    }
  }

  func testClangdGoToDeclaration() throws {
    guard let ws = try staticSourceKitTibsWorkspace(name: "BasicCXX") else { return }
    guard ToolchainRegistry.shared.default?.clangd != nil else { return }

    let mainLoc = ws.testLoc("Object:ref:newObject")
    let expectedDoc = ws.testLoc("Object:decl:newObject").docIdentifier.uri
    let includePosition =
        Position(line: mainLoc.position.line, utf16index: mainLoc.utf16Column + 2)

    try ws.openDocument(mainLoc.url, language: .c)

    let goToInclude = DeclarationRequest(
      textDocument: mainLoc.docIdentifier, position: includePosition)
    let resp = try! ws.sk.sendSync(goToInclude)

    let locationsOrLinks = try XCTUnwrap(resp, "No response for go-to-declaration")
    switch locationsOrLinks {
    case .locations(let locations):
      XCTAssert(!locations.isEmpty, "Found no locations for go-to-declaration")
      if let loc = locations.first {
        XCTAssertEqual(loc.uri, expectedDoc)
      }
    case .locationLinks(let locationLinks):
      XCTAssert(!locationLinks.isEmpty, "Found no location links for go-to-declaration")
      if let link = locationLinks.first {
        XCTAssertEqual(link.targetUri, expectedDoc)
      }
    }
  }
}
