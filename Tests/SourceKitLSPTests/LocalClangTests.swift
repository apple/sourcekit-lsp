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

import LSPTestSupport
import LanguageServerProtocol
import SKCore
import SKTestSupport
import XCTest

final class LocalClangTests: XCTestCase {

  /// Whether to fail tests if clangd cannot be found.
  static let requireClangd: Bool = false  // Note: Swift CI doesn't build clangd on all jobs

  /// Whether clangd exists in the toolchain.
  var haveClangd: Bool = false

  /// Connection and lifetime management for the service.
  var connection: TestSourceKitServer! = nil

  /// The primary interface to make requests to the SourceKitServer.
  var sk: TestClient! = nil

  override func setUp() {
    haveClangd = ToolchainRegistry.shared.toolchains.contains { $0.clangd != nil }
    if LocalClangTests.requireClangd && !haveClangd {
      XCTFail("cannot find clangd in toolchain")
    }

    connection = TestSourceKitServer()
    sk = connection.client
    let documentSymbol = TextDocumentClientCapabilities.DocumentSymbol(
      dynamicRegistration: nil,
      symbolKind: nil,
      hierarchicalDocumentSymbolSupport: true
    )
    let textDocument = TextDocumentClientCapabilities(documentSymbol: documentSymbol)
    _ = try! sk.sendSync(
      InitializeRequest(
        processId: nil,
        rootPath: nil,
        rootURI: nil,
        initializationOptions: nil,
        capabilities: ClientCapabilities(workspace: nil, textDocument: textDocument),
        trace: .off,
        workspaceFolders: nil
      )
    )
  }

  override func tearDown() {
    sk = nil
    connection = nil
  }

  // MARK: Tests

  func testSymbolInfo() throws {
    guard haveClangd else { return }
    #if os(Windows)
    let url = URL(fileURLWithPath: "C:/a.cpp")
    #else
    let url = URL(fileURLWithPath: "/a.cpp")
    #endif

    sk.send(
      DidOpenTextDocumentNotification(
        textDocument: TextDocumentItem(
          uri: DocumentURI(url),
          language: .cpp,
          version: 1,
          text: """
            struct S {
              void foo() {
                int local = 1;
              }
            };
            """
        )
      )
    )

    do {
      let resp = try sk.sendSync(
        SymbolInfoRequest(
          textDocument: TextDocumentIdentifier(url),
          position: Position(line: 0, utf16index: 7)
        )
      )

      XCTAssertEqual(resp.count, 1)
      if let sym = resp.first {
        XCTAssertEqual(sym.name, "S")
        XCTAssertNil(sym.containerName)
        XCTAssertEqual(sym.usr, "c:@S@S")
      }
    }

    do {
      let resp = try sk.sendSync(
        SymbolInfoRequest(
          textDocument: TextDocumentIdentifier(url),
          position: Position(line: 1, utf16index: 7)
        )
      )

      XCTAssertEqual(resp.count, 1)
      if let sym = resp.first {
        XCTAssertEqual(sym.name, "foo")
        XCTAssertEqual(sym.containerName, "S::")
        XCTAssertEqual(sym.usr, "c:@S@S@F@foo#")
      }
    }

    do {
      let resp = try sk.sendSync(
        SymbolInfoRequest(
          textDocument: TextDocumentIdentifier(url),
          position: Position(line: 2, utf16index: 8)
        )
      )

      XCTAssertEqual(resp.count, 1)
      if let sym = resp.first {
        XCTAssertEqual(sym.name, "local")
        XCTAssertEqual(sym.containerName, "S::foo")
        XCTAssertEqual(sym.usr, "c:a.cpp@30@S@S@F@foo#@local")
      }
    }

    do {
      let resp = try sk.sendSync(
        SymbolInfoRequest(
          textDocument: TextDocumentIdentifier(url),
          position: Position(line: 3, utf16index: 0)
        )
      )

      XCTAssertEqual(resp.count, 0)
    }
  }

  func testFoldingRange() throws {
    guard haveClangd else { return }
    #if os(Windows)
    let url = URL(fileURLWithPath: "C:/a.cpp")
    #else
    let url = URL(fileURLWithPath: "/a.cpp")
    #endif

    sk.send(
      DidOpenTextDocumentNotification(
        textDocument: TextDocumentItem(
          uri: DocumentURI(url),
          language: .cpp,
          version: 1,
          text: """
            struct S {
              void foo() {
                int local = 1;
              }
            };
            """
        )
      )
    )

    let resp = try sk.sendSync(FoldingRangeRequest(textDocument: TextDocumentIdentifier(url)))
    if let resp = resp {
      XCTAssertEqual(
        resp,
        [
          FoldingRange(startLine: 0, startUTF16Index: 10, endLine: 4, kind: .region),
          FoldingRange(startLine: 1, startUTF16Index: 14, endLine: 3, endUTF16Index: 2, kind: .region),
        ]
      )
    }
  }

  func testDocumentSymbols() throws {
    guard haveClangd else { return }
    #if os(Windows)
    let url = URL(fileURLWithPath: "C:/a.cpp")
    #else
    let url = URL(fileURLWithPath: "/a.cpp")
    #endif

    sk.send(
      DidOpenTextDocumentNotification(
        textDocument: TextDocumentItem(
          uri: DocumentURI(url),
          language: .cpp,
          version: 1,
          text: """
            struct S {
              void foo() {
                int local = 1;
              }
            };
            """
        )
      )
    )

    guard let resp = try sk.sendSync(DocumentSymbolRequest(textDocument: TextDocumentIdentifier(url))) else {
      XCTFail("Invalid document symbol response")
      return
    }
    guard case let .documentSymbols(syms) = resp else {
      XCTFail("Expected a [DocumentSymbol] but got \(resp)")
      return
    }
    XCTAssertEqual(syms.count, 1)
    XCTAssertEqual(syms.first?.name, "S")
    XCTAssertEqual(syms.first?.children?.first?.name, "foo")
  }

  func testCodeAction() async throws {
    guard let ws = try await staticSourceKitTibsWorkspace(name: "CodeActionCxx") else { return }
    if ToolchainRegistry.shared.default?.clangd == nil { return }

    let loc = ws.testLoc("SwitchColor")
    let endLoc = ws.testLoc("SwitchColor:end")

    let expectation = XCTestExpectation(description: "diagnostics")

    ws.sk.handleNextNotification { (notification: Notification<PublishDiagnosticsNotification>) in
      let diagnostics = notification.params.diagnostics
      // It seems we either get no diagnostics or a `-Wswitch` warning. Either is fine
      // as long as our code action works properly.
      XCTAssert(
        diagnostics.isEmpty || (diagnostics.count == 1 && diagnostics.first?.code == .string("-Wswitch")),
        "Unexpected diagnostics \(diagnostics)"
      )
      expectation.fulfill()
    }

    try ws.openDocument(loc.url, language: .cpp)

    try await fulfillmentOfOrThrow([expectation])

    let codeAction = CodeActionRequest(
      range: Position(loc)..<Position(endLoc),
      context: CodeActionContext(),
      textDocument: loc.docIdentifier
    )
    guard let reply = try ws.sk.sendSync(codeAction) else {
      XCTFail("CodeActionRequest had nil reply")
      return
    }
    guard case let .commands(commands) = reply else {
      XCTFail("Expected [Command] but got \(reply)")
      return
    }
    guard let command = commands.first else {
      XCTFail("Expected a non-empty [Command]")
      return
    }
    XCTAssertEqual(command.command, "clangd.applyTweak")

    let applyEdit = XCTestExpectation(description: "applyEdit")
    ws.sk.handleNextRequest { (request: Request<ApplyEditRequest>) in
      XCTAssertNotNil(request.params.edit.changes)
      request.reply(ApplyEditResponse(applied: true, failureReason: nil))
      applyEdit.fulfill()
    }

    let executeCommand = ExecuteCommandRequest(
      command: command.command,
      arguments: command.arguments
    )
    _ = try ws.sk.sendSync(executeCommand)

    try await fulfillmentOfOrThrow([applyEdit])
  }

  func testClangStdHeaderCanary() async throws {
    guard let ws = try await staticSourceKitTibsWorkspace(name: "ClangStdHeaderCanary") else { return }
    if ToolchainRegistry.shared.default?.clangd == nil { return }

    let loc = ws.testLoc("unused_b")

    let expectation = XCTestExpectation(description: "diagnostics")

    ws.sk.handleNextNotification { (notification: Notification<PublishDiagnosticsNotification>) in
      // Don't use exact equality because of differences in recent clang.
      XCTAssertEqual(notification.params.diagnostics.count, 1)
      XCTAssertEqual(
        notification.params.diagnostics.first?.range,
        Position(loc)..<Position(ws.testLoc("unused_b:end"))
      )
      XCTAssertEqual(notification.params.diagnostics.first?.severity, .warning)
      XCTAssertEqual(notification.params.diagnostics.first?.message, "Unused variable 'b'")
      expectation.fulfill()
    }

    try ws.openDocument(loc.url, language: .cpp)

    try await fulfillmentOfOrThrow([expectation])
  }

  func testClangModules() async throws {
    guard let ws = try await staticSourceKitTibsWorkspace(name: "ClangModules") else { return }
    if ToolchainRegistry.shared.default?.clangd == nil { return }

    let loc = ws.testLoc("main_file")

    let expectation = self.expectation(description: "diagnostics")

    ws.sk.handleNextNotification { (notification: Notification<PublishDiagnosticsNotification>) in
      XCTAssertEqual(notification.params.diagnostics.count, 0)
      expectation.fulfill()
    }

    try ws.openDocument(loc.url, language: .objective_c)

    try await fulfillmentOfOrThrow([expectation])
    withExtendedLifetime(ws) {}
  }

  func testSemanticHighlighting() async throws {
    guard haveClangd else { return }
    guard let ws = try await staticSourceKitTibsWorkspace(name: "BasicCXX") else {
      return
    }
    let mainLoc = ws.testLoc("Object:include:main")

    let diagnostics = self.expectation(description: "diagnostics")
    ws.sk.handleNextNotification { (notification: Notification<PublishDiagnosticsNotification>) in
      diagnostics.fulfill()
      XCTAssertEqual(notification.params.diagnostics.count, 0)
    }

    try ws.openDocument(mainLoc.url, language: .c)
    try await fulfillmentOfOrThrow([diagnostics])

    let request = DocumentSemanticTokensRequest(textDocument: mainLoc.docIdentifier)
    do {
      let reply = try ws.sk.sendSync(request)
      XCTAssertNotNil(reply)
    } catch let e {
      if let error = e as? ResponseError {
        try XCTSkipIf(
          error.code == ErrorCode.methodNotFound,
          "clangd does not support semantic tokens"
        )
      }
      throw e
    }
  }

  func testDocumentDependenciesUpdated() async throws {
    let ws = try await mutableSourceKitTibsTestWorkspace(name: "BasicCXX")!

    let cFileLoc = ws.testLoc("Object:ref:main")

    // Initially the workspace should build fine.
    let documentOpened = self.expectation(description: "documentOpened")
    ws.sk.handleNextNotification({ (notification: LanguageServerProtocol.Notification<PublishDiagnosticsNotification>) in
      XCTAssert(notification.params.diagnostics.isEmpty)
      documentOpened.fulfill()
    })

    try ws.openDocument(cFileLoc.url, language: .cpp)

    try await fulfillmentOfOrThrow([documentOpened], timeout: 5)

    // We rename Object to MyObject in the header.
    _ = try ws.sources.edit { builder in
      let headerFilePath = ws.sources.rootDirectory.appendingPathComponent("Object.h")
      var headerFile = try String(contentsOf: headerFilePath, encoding: .utf8)
      let targetMarkerRange = headerFile.range(of: "/*Object*/")!
      headerFile.replaceSubrange(targetMarkerRange, with: "My")
      builder.write(headerFile, to: headerFilePath)
    }

    // Now we should get a diagnostic in main.c file because `Object` is no longer defined.
    let updatedNotificationsReceived = self.expectation(description: "updatedNotificationsReceived")
    ws.sk.handleNextNotification({ (notification: LanguageServerProtocol.Notification<PublishDiagnosticsNotification>) in
      XCTAssertFalse(notification.params.diagnostics.isEmpty)
      updatedNotificationsReceived.fulfill()
    })

    let clangdServer = await ws.testServer.server!._languageService(
      for: cFileLoc.docUri,
      .cpp,
      in: ws.testServer.server!.workspaceForDocument(uri: cFileLoc.docUri)!
    )!

    await clangdServer.documentDependenciesUpdated(cFileLoc.docUri)

    try await fulfillmentOfOrThrow([updatedNotificationsReceived], timeout: 5)
  }
}
