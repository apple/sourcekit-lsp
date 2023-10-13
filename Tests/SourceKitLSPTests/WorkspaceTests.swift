//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import LSPTestSupport
import LanguageServerProtocol
import SKCore
import SKTestSupport
import SourceKitLSP
import TSCBasic
import XCTest

final class WorkspaceTests: XCTestCase {

  func testMultipleSwiftPMWorkspaces() async throws {
    guard let ws = try await staticSourceKitSwiftPMWorkspace(name: "SwiftPMPackage") else { return }
    try ws.buildAndIndex()

    guard let otherWs = try await staticSourceKitSwiftPMWorkspace(name: "OtherSwiftPMPackage", server: ws.testServer)
    else { return }
    try otherWs.buildAndIndex()

    assert(ws.testServer === otherWs.testServer, "Sanity check: The two workspaces should be opened in the same server")

    let call = ws.testLoc("Lib.foo:call")
    let otherCall = otherWs.testLoc("FancyLib.sayHello:call")

    try ws.openDocument(call.url, language: .swift)

    let completions = try withExtendedLifetime(ws) {
      try ws.sk.sendSync(CompletionRequest(textDocument: call.docIdentifier, position: call.position))
    }

    XCTAssertEqual(
      completions.items,
      [
        CompletionItem(
          label: "foo()",
          kind: .method,
          detail: "Void",
          deprecated: false,
          sortText: nil,
          filterText: "foo()",
          insertText: "foo()",
          insertTextFormat: .plain,
          textEdit: .textEdit(
            TextEdit(range: Position(line: 2, utf16index: 24)..<Position(line: 2, utf16index: 24), newText: "foo()")
          )
        ),
        CompletionItem(
          label: "self",
          kind: .keyword,
          detail: "Lib",
          deprecated: false,
          sortText: nil,
          filterText: "self",
          insertText: "self",
          insertTextFormat: .plain,
          textEdit: .textEdit(
            TextEdit(range: Position(line: 2, utf16index: 24)..<Position(line: 2, utf16index: 24), newText: "self")
          )
        ),
      ]
    )

    try ws.openDocument(otherCall.url, language: .swift)

    let otherCompletions = try withExtendedLifetime(ws) {
      try ws.sk.sendSync(CompletionRequest(textDocument: otherCall.docIdentifier, position: otherCall.position))
    }

    XCTAssertEqual(
      otherCompletions.items,
      [
        CompletionItem(
          label: "sayHello()",
          kind: .method,
          detail: "Void",
          documentation: nil,
          deprecated: false,
          sortText: nil,
          filterText: "sayHello()",
          insertText: "sayHello()",
          insertTextFormat: .plain,
          textEdit: .textEdit(
            TextEdit(
              range: Position(line: 7, utf16index: 41)..<Position(line: 7, utf16index: 41),
              newText: "sayHello()"
            )
          )
        ),
        CompletionItem(
          label: "self",
          kind: LanguageServerProtocol.CompletionItemKind(rawValue: 14),
          detail: "FancyLib",
          documentation: nil,
          deprecated: false,
          sortText: nil,
          filterText: "self",
          insertText: "self",
          insertTextFormat: .plain,
          textEdit: .textEdit(
            TextEdit(range: Position(line: 7, utf16index: 41)..<Position(line: 7, utf16index: 41), newText: "self")
          )
        ),
      ]
    )
  }

  func testMultipleClangdWorkspaces() async throws {
    guard let ws = try await staticSourceKitTibsWorkspace(name: "ClangModules") else { return }

    let loc = ws.testLoc("main_file")

    let expectation = self.expectation(description: "diagnostics")

    ws.sk.handleNextNotification { (notification: Notification<PublishDiagnosticsNotification>) in
      XCTAssertEqual(notification.params.diagnostics.count, 0)
      expectation.fulfill()
    }

    try ws.openDocument(loc.url, language: .objective_c)

    try await fulfillmentOfOrThrow([expectation])

    let otherWs = try await staticSourceKitTibsWorkspace(
      name: "ClangCrashRecoveryBuildSettings",
      server: ws.testServer
    )!
    assert(ws.testServer === otherWs.testServer, "Sanity check: The two workspaces should be opened in the same server")
    let otherLoc = otherWs.testLoc("loc")

    try otherWs.openDocument(otherLoc.url, language: .cpp)

    // Do a sanity check and verify that we get the expected result from a hover response before crashing clangd.

    let expectedHighlightResponse = [
      DocumentHighlight(range: Position(line: 3, utf16index: 5)..<Position(line: 3, utf16index: 8), kind: .text),
      DocumentHighlight(range: Position(line: 9, utf16index: 2)..<Position(line: 9, utf16index: 5), kind: .text),
    ]

    let highlightRequest = DocumentHighlightRequest(
      textDocument: otherLoc.docIdentifier,
      position: Position(line: 9, utf16index: 3)
    )
    let highlightResponse = try otherWs.sk.sendSync(highlightRequest)
    XCTAssertEqual(highlightResponse, expectedHighlightResponse)
  }

  func testRecomputeFileWorkspaceMembershipOnPackageSwiftChange() async throws {
    guard let otherWs = try await staticSourceKitSwiftPMWorkspace(name: "OtherSwiftPMPackage") else { return }
    try otherWs.buildAndIndex()

    guard let ws = try await staticSourceKitSwiftPMWorkspace(name: "SwiftPMPackage", server: otherWs.testServer) else {
      return
    }
    try ws.buildAndIndex()

    assert(ws.testServer === otherWs.testServer, "Sanity check: The two workspaces should be opened in the same server")

    let otherLib = ws.testLoc("OtherLib.topLevelFunction:libMember")
    let packageTargets = ws.testLoc("Package.swift:targets")

    try ws.openDocument(otherLib.url, language: .swift)

    // We open OtherSwiftPMPackage first. Thus, otherLib (which is a folder in
    // SwiftPMPackage that hasn't been added to Package.swift yet) will belong
    // to OtherSwiftPMPackage by default (because it provides fallback build
    // settings for it).
    assertEqual(
      await ws.testServer.server!.workspaceForDocument(uri: otherLib.docUri)?.rootUri,
      DocumentURI(otherWs.sources.rootDirectory)
    )

    // Add the otherlib target to Package.swift
    _ = try ws.sources.edit { builder in
      let packageManifest = ws.sources.rootDirectory
        .appendingPathComponent("Package.swift")
      var packageManifestContents = try String(contentsOf: packageManifest, encoding: .utf8)
      let targetMarkerRange = packageManifestContents.range(of: "/*Package.swift:targets*/")!
      packageManifestContents.replaceSubrange(
        targetMarkerRange,
        with: """
          .target(
             name: "otherlib",
             dependencies: ["lib"]
          ),
          /*Package.swift:targets*/
          """
      )
      builder.write(packageManifestContents, to: packageManifest)
    }

    ws.sk.send(
      DidChangeWatchedFilesNotification(changes: [
        FileEvent(uri: packageTargets.docUri, type: .changed)
      ])
    )

    // After updating Package.swift in SwiftPMPackage, SwiftPMPackage can
    // provide proper build settings for otherLib and thus workspace
    // membership should switch to SwiftPMPackage.

    // Updating the build settings takes a few seconds. Send code completion requests every second until we receive correct results.
    var didReceiveCorrectWorkspaceMembership = false

    // Updating the build settings takes a few seconds. Send code completion requests every second until we receive correct results.
    for _ in 0..<30 {
      if await ws.testServer.server!.workspaceForDocument(uri: otherLib.docUri)?.rootUri
        == DocumentURI(ws.sources.rootDirectory)
      {
        didReceiveCorrectWorkspaceMembership = true
        break
      }
      try await Task.sleep(nanoseconds: 1_000_000_000)
    }

    XCTAssert(didReceiveCorrectWorkspaceMembership)
  }

  func testMixedPackage() async throws {
    guard let ws = try await staticSourceKitSwiftPMWorkspace(name: "MixedPackage") else { return }
    try ws.buildAndIndex()

    let cLoc = ws.testLoc("clib_func:body")
    let swiftLoc = ws.testLoc("lib.swift:toplevel")

    try ws.openDocument(swiftLoc.url, language: .swift)
    try ws.openDocument(cLoc.url, language: .c)

    let receivedResponse = self.expectation(description: "Received completion response")

    _ = ws.sk.send(CompletionRequest(textDocument: cLoc.docIdentifier, position: cLoc.position)) { result in
      defer {
        receivedResponse.fulfill()
      }
      guard case .success(_) = result else {
        XCTFail("Expected a successful response")
        return
      }
    }

    try await fulfillmentOfOrThrow([receivedResponse])
  }

  func testChangeWorkspaceFolders() async throws {
    guard let ws = try await staticSourceKitSwiftPMWorkspace(name: "ChangeWorkspaceFolders") else { return }
    // Build the package. We can't use ws.buildAndIndex() because that doesn't put the build products in .build where SourceKit-LSP expects them.
    try await TSCBasic.Process.checkNonZeroExit(arguments: [
      ToolchainRegistry.shared.default!.swift!.pathString,
      "build",
      "--package-path", ws.sources.rootDirectory.path,
      "-Xswiftc", "-index-ignore-system-modules",
      "-Xcc", "-index-ignore-system-symbols",
    ])

    let otherPackLoc = ws.testLoc("otherPackage:call")

    let testServer = TestSourceKitServer(connectionKind: .local)
    let sk = testServer.client
    _ = try sk.sendSync(
      InitializeRequest(
        rootURI: nil,
        capabilities: ClientCapabilities(workspace: .init(workspaceFolders: true)),
        workspaceFolders: [
          WorkspaceFolder(uri: DocumentURI(ws.sources.rootDirectory.deletingLastPathComponent()))
        ]
      )
    )

    let docString = try String(data: Data(contentsOf: otherPackLoc.url), encoding: .utf8)!

    sk.send(
      DidOpenTextDocumentNotification(
        textDocument: TextDocumentItem(
          uri: otherPackLoc.docUri,
          language: .swift,
          version: 1,
          text: docString
        )
      )
    )

    let preChangeWorkspaceResponse = try sk.sendSync(
      CompletionRequest(
        textDocument: TextDocumentIdentifier(otherPackLoc.docUri),
        position: otherPackLoc.position
      )
    )

    XCTAssertEqual(
      preChangeWorkspaceResponse.items,
      [],
      "Did not expect to receive cross-module code completion results if we opened the parent directory of the package"
    )

    sk.send(
      DidChangeWorkspaceFoldersNotification(
        event: WorkspaceFoldersChangeEvent(added: [
          WorkspaceFolder(uri: DocumentURI(ws.sources.rootDirectory))
        ])
      )
    )

    let postChangeWorkspaceResponse = try sk.sendSync(
      CompletionRequest(
        textDocument: TextDocumentIdentifier(otherPackLoc.docUri),
        position: otherPackLoc.position
      )
    )

    XCTAssertEqual(
      postChangeWorkspaceResponse.items,
      [
        CompletionItem(
          label: "helloWorld()",
          kind: .method,
          detail: "Void",
          documentation: nil,
          deprecated: false,
          sortText: nil,
          filterText: "helloWorld()",
          insertText: "helloWorld()",
          insertTextFormat: .plain,
          textEdit: .textEdit(
            TextEdit(
              range: otherPackLoc.position..<otherPackLoc.position,
              newText: "helloWorld()"
            )
          )
        ),
        CompletionItem(
          label: "self",
          kind: .keyword,
          detail: "Package",
          documentation: nil,
          deprecated: false,
          sortText: nil,
          filterText: "self",
          insertText: "self",
          insertTextFormat: .plain,
          textEdit: .textEdit(
            TextEdit(
              range: otherPackLoc.position..<otherPackLoc.position,
              newText: "self"
            )
          )
        ),
      ]
    )
  }
}
