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

import Foundation
import LanguageServerProtocol
import XCTest

final class SwiftPMIntegrationTests: XCTestCase {

  func testSwiftPMIntegration() throws {
    guard let ws = try staticSourceKitSwiftPMWorkspace(name: "SwiftPMPackage") else { return }
    try ws.buildAndIndex()

    let call = ws.testLoc("Lib.foo:call")
    let def = ws.testLoc("Lib.foo:def")
    try ws.openDocument(call.url, language: .swift)
    let refs = try ws.sk.sendSync(ReferencesRequest(textDocument: call.docIdentifier, position: call.position, context: ReferencesContext(includeDeclaration: true)))

    XCTAssertEqual(Set(refs), [
      Location(call),
      Location(def),
    ])

    let completions = try withExtendedLifetime(ws) {
        try ws.sk.sendSync(CompletionRequest(textDocument: call.docIdentifier, position: call.position))
    }

    XCTAssertEqual(completions.items, [
      CompletionItem(
        label: "foo()",
        kind: .method,
        detail: "Void",
        documentation: .markupContent(MarkupContent(kind: .markdown, value: "Documentation for foo.")),
        sortText: nil,
        filterText: "foo()",
        textEdit: TextEdit(range: Position(line: 2, utf16index: 24)..<Position(line: 2, utf16index: 24), newText: "foo()"),
        insertText: "foo()",
        insertTextFormat: .plain,
        deprecated: false,
        data: .dictionary(["textDocURI": .string(call.url.absoluteString), "usr": .string("s:3lib3LibV3fooyyF")])),
      CompletionItem(
        label: "self",
        kind: .keyword,
        detail: "Lib",
        sortText: nil,
        filterText: "self",
        textEdit: TextEdit(range: Position(line: 2, utf16index: 24)..<Position(line: 2, utf16index: 24), newText: "self"),
        insertText: "self",
        insertTextFormat: .plain,
        deprecated: false,
        data: .dictionary(["textDocURI": .string(call.url.absoluteString)])),
    ])

    // FIXME: SourceKit is "Unable to resolve type from" `s:3lib3LibV3fooyyF`.
    
    // `completionItem/resolve` should return full documentation.
    //let completionItemResolveResponse = try ws.sk.sendSync(completions.items[0])
    //XCTAssertEqual(completionItemResolveResponse.documentation, .markupContent(MarkupContent(kind: .markdown, value: "Documentation for `foo`.")))
  }

  func testAddFile() throws {
    guard let ws = try staticSourceKitSwiftPMWorkspace(name: "SwiftPMPackage") else { return }
    try ws.buildAndIndex()

    /// Add a new file to the project that wasn't built
    _ = try ws.sources.edit { builder in
      let otherFile = ws.sources.rootDirectory
        .appendingPathComponent("Sources")
        .appendingPathComponent("lib")
        .appendingPathComponent("other.swift")
      let otherFileContents = """
      func baz(l: Lib)  {
        l . /*newFile:call*/foo()
      }
      """
      builder.write(otherFileContents, to: otherFile)
    }

    let oldFile = ws.testLoc("Lib.topLevelFunction:body")
    let newFile = ws.testLoc("newFile:call")

    // Check that we don't get cross-file code completion before we send a `DidChangeWatchedFilesNotification` to make sure we didn't include the file in the initial retrieval of build settings.
    try ws.openDocument(newFile.url, language: .swift)
    try ws.openDocument(oldFile.url, language: .swift)

    let completionsBeforeDidChangeNotification = try withExtendedLifetime(ws) {
      try ws.sk.sendSync(CompletionRequest(textDocument: newFile.docIdentifier, position: newFile.position))
    }
    XCTAssertEqual(completionsBeforeDidChangeNotification.items, [])
    ws.closeDocument(newFile.url)

    // Send a `DidChangeWatchedFilesNotification` and verify that we now get cross-file code completion.
    ws.sk.send(DidChangeWatchedFilesNotification(changes: [
      FileEvent(uri: newFile.docUri, type: .created)
    ]))
    try ws.openDocument(newFile.url, language: .swift)
    
    let completions = try withExtendedLifetime(ws) {
      try ws.sk.sendSync(CompletionRequest(textDocument: newFile.docIdentifier, position: newFile.position))
    }

    XCTAssertEqual(completions.items, [
      CompletionItem(
        label: "foo()",
        kind: .method,
        detail: "Void",
        sortText: nil,
        filterText: "foo()",
        textEdit: TextEdit(range: Position(line: 1, utf16index: 22)..<Position(line: 1, utf16index: 22), newText: "foo()"),
        insertText: "foo()",
        insertTextFormat: .plain,
        deprecated: false),
      CompletionItem(
        label: "self",
        kind: .keyword,
        detail: "Lib",
        sortText: nil,
        filterText: "self",
        textEdit: TextEdit(range: Position(line: 1, utf16index: 22)..<Position(line: 1, utf16index: 22), newText: "self"),
        insertText: "self",
        insertTextFormat: .plain,
        deprecated: false),
    ])

    // Check that we get code completion for `baz` (defined in the new file) in the old file.
    // I.e. check that the existing file's build settings have been updated to include the new file.

    let oldFileCompletions = try withExtendedLifetime(ws) {
      try ws.sk.sendSync(CompletionRequest(textDocument: oldFile.docIdentifier, position: oldFile.position))
    }
    XCTAssert(oldFileCompletions.items.contains(CompletionItem(
      label: "baz(l: Lib)",
      kind: .function,
      detail: "Void",
      documentation: nil,
      sortText: nil,
      filterText: "baz(l:)",
      textEdit: TextEdit(range: Position(line: 7, utf16index: 31)..<Position(line: 7, utf16index: 31), newText: "baz(l: )"),
      insertText: "baz(l: )",
      insertTextFormat: .plain,
      deprecated: false))
    )
  }

  func testModifyPackageManifest() throws {
    guard let ws = try staticSourceKitSwiftPMWorkspace(name: "SwiftPMPackage") else { return }
    try ws.buildAndIndex()

    let otherLib = ws.testLoc("OtherLib.topLevelFunction:libMember")
    let packageTargets = ws.testLoc("Package.swift:targets")

    // Check that we don't get cross-file code completion before we send a `DidChangeWatchedFilesNotification` to make sure we didn't include the file in the initial retrieval of build settings.
    try ws.openDocument(otherLib.url, language: .swift)

    let completionsBeforeDidChangeNotification = try withExtendedLifetime(ws) {
      try ws.sk.sendSync(CompletionRequest(textDocument: otherLib.docIdentifier, position: otherLib.position))
    }
    XCTAssertEqual(completionsBeforeDidChangeNotification.items, [])

    // Add the otherlib target to Package.swift
    _ = try ws.sources.edit { builder in
      let packageManifest = ws.sources.rootDirectory
        .appendingPathComponent("Package.swift")
      var packageManifestContents = try! String(contentsOf: packageManifest, encoding: .utf8)
      let targetMarkerRange = packageManifestContents.range(of: "/*Package.swift:targets*/")!
      packageManifestContents.replaceSubrange(targetMarkerRange, with: """
      .target(
         name: "otherlib",
         dependencies: ["lib"]
      ),
      /*Package.swift:targets*/
      """)
      builder.write(packageManifestContents, to: packageManifest)
    }

    // Send a `DidChangeWatchedFilesNotification` and verify that we now get cross-file code completion.
    ws.sk.send(DidChangeWatchedFilesNotification(changes: [
      FileEvent(uri: packageTargets.docUri, type: .changed)
    ]))

    let expectedCompletions = [
      CompletionItem(
        label: "foo()",
        kind: .method,
        detail: "Void",
        sortText: nil,
        filterText: "foo()",
        textEdit: TextEdit(range: Position(line: 3, utf16index: 47)..<Position(line: 3, utf16index: 47), newText: "foo()"),
        insertText: "foo()",
        insertTextFormat: .plain,
        deprecated: false),
      CompletionItem(
        label: "self",
        kind: .keyword,
        detail: "Lib",
        sortText: nil,
        filterText: "self",
        textEdit: TextEdit(range: Position(line: 3, utf16index: 47)..<Position(line: 3, utf16index: 47), newText: "self"),
        insertText: "self",
        insertTextFormat: .plain,
        deprecated: false),
    ]

    var didReceiveCorrectCompletions = false

    // Updating the build settings takes a few seconds. Send code completion requests every second until we receive correct results.
    for _ in 0..<30 {
      let completions = try withExtendedLifetime(ws) {
        try ws.sk.sendSync(CompletionRequest(textDocument: otherLib.docIdentifier, position: otherLib.position))
      }

      if completions.items == expectedCompletions {
        didReceiveCorrectCompletions = true
        break
      }
      Thread.sleep(forTimeInterval: 1)
    }

    XCTAssert(didReceiveCorrectCompletions)
  }
}
