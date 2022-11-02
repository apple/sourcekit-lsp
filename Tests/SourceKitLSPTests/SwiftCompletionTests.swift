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

import LanguageServerProtocol
import LSPTestSupport
import SKTestSupport
import SourceKitLSP
import XCTest

final class SwiftCompletionTests: XCTestCase {

  typealias CompletionCapabilities = TextDocumentClientCapabilities.Completion

  /// Base document text to use for completion tests.
  let text: String = """
    struct S {
      /// Documentation for `abc`.
      var abc: Int

      func test(a: Int) {
        self.abc
      }

      func test(_ b: Int) {
        self.abc
      }
    }
    """

  /// Connection and lifetime management for the service.
  var connection: TestSourceKitServer! = nil

  /// The primary interface to make requests to the SourceKitServer.
  var sk: TestClient! = nil

  override func tearDown() {
    shutdownServer()
  }

  func shutdownServer() {
    sk = nil
    connection = nil
  }

  func initializeServer(options: SKCompletionOptions = .init(), capabilities: CompletionCapabilities? = nil) {
    connection = TestSourceKitServer()
    sk = connection.client
    var documentCapabilities: TextDocumentClientCapabilities?
    if let capabilities = capabilities {
      documentCapabilities = TextDocumentClientCapabilities()
      documentCapabilities?.completion = capabilities
    } else {
      documentCapabilities = nil
    }
    _ = try! sk.sendSync(
      InitializeRequest(
        processId: nil,
        rootPath: nil,
        rootURI: nil,
        initializationOptions: .dictionary([
          "completion": .dictionary([
            "serverSideFiltering": .bool(options.serverSideFiltering),
            "maxResults": options.maxResults == nil ? .null : .int(options.maxResults!),
          ]),
        ]),
        capabilities: ClientCapabilities(workspace: nil, textDocument: documentCapabilities),
        trace: .off,
        workspaceFolders: nil))
  }

  func openDocument(text: String? = nil, url: URL) {
    sk.send(DidOpenTextDocumentNotification(textDocument: TextDocumentItem(
      uri: DocumentURI(url),
      language: .swift,
      version: 12,
      text: text ?? self.text)))
  }

  func testCompletionClientFilter() throws {
    try testCompletionBasic(options: SKCompletionOptions(serverSideFiltering: false, maxResults: nil))
  }

  func testCompletionServerFilter() throws {
    try testCompletionBasic(options: SKCompletionOptions(serverSideFiltering: true, maxResults: nil))
  }

  func testCompletionDefaultFilter() throws {
    try testCompletionBasic(options: SKCompletionOptions())
  }

  func testCompletionBasic(options: SKCompletionOptions) throws {
    initializeServer(options: options)
    let url = URL(fileURLWithPath: "/\(UUID())/a.swift")
    openDocument(url: url)

    let selfDot = try sk.sendSync(CompletionRequest(
      textDocument: TextDocumentIdentifier(url),
      position: Position(line: 5, utf16index: 9)))

    XCTAssertEqual(selfDot.isIncomplete, options.serverSideFiltering)
    XCTAssertGreaterThanOrEqual(selfDot.items.count, 2)
    let abc = selfDot.items.first { $0.label == "abc" }
    XCTAssertNotNil(abc)
    if let abc = abc {
      XCTAssertEqual(abc.kind, .property)
      XCTAssertEqual(abc.detail, "Int")
      XCTAssertEqual(abc.documentation, .markupContent(MarkupContent(kind: .markdown, value: "Documentation for abc.")))
      XCTAssertEqual(abc.filterText, "abc")
      XCTAssertEqual(abc.textEdit, TextEdit(range: Position(line: 5, utf16index: 9)..<Position(line: 5, utf16index: 9), newText: "abc"))
      XCTAssertEqual(abc.insertText, "abc")
      XCTAssertEqual(abc.insertTextFormat, .plain)
      XCTAssertEqual(abc.data, .dictionary(["textDocURI": .string(url.absoluteString), "usr": .string("s:1a1SV3abcSivp")]))

      // FIXME: SourceKit is "Unable to resolve type from" `s:1a1SV3abcSivp`.
      
      // `completionItem/resolve` should return full documentation.
      //let completionResolveResponse = try! sk.sendSync(abc)
      //XCTAssertEqual(completionResolveResponse.documentation, .markupContent(MarkupContent(kind: .markdown, value: "Documentation for `abc`.")))
    }

    for col in 10...12 {
      let inIdent = try sk.sendSync(CompletionRequest(
        textDocument: TextDocumentIdentifier(url),
        position: Position(line: 5, utf16index: col)))
      guard let abc = inIdent.items.first(where: { $0.label == "abc" }) else {
        XCTFail("No completion item with label 'abc'")
        return
      }

      // If we switch to server-side filtering this will change.
      XCTAssertEqual(abc.kind, .property)
      XCTAssertEqual(abc.detail, "Int")
      XCTAssertEqual(abc.documentation, .markupContent(MarkupContent(kind: .markdown, value: "Documentation for abc.")))
      XCTAssertEqual(abc.filterText, "abc")
      XCTAssertEqual(abc.textEdit, TextEdit(range: Position(line: 5, utf16index: 9)..<Position(line: 5, utf16index: col), newText: "abc"))
      XCTAssertEqual(abc.insertText, "abc")
      XCTAssertEqual(abc.insertTextFormat, .plain)
    }

    let after = try sk.sendSync(CompletionRequest(
      textDocument: TextDocumentIdentifier(url),
      position: Position(line: 6, utf16index: 0)))
    XCTAssertNotEqual(after, selfDot)
  }

  func testCompletionSnippetSupport() throws {
    var capabilities = CompletionCapabilities()
    capabilities.completionItem = CompletionCapabilities.CompletionItem(snippetSupport: true)

    initializeServer(capabilities: capabilities)
    let url = URL(fileURLWithPath: "/\(UUID())/a.swift")
    openDocument(url: url)

    func getTestMethodCompletion(_ position: Position, label: String) throws -> CompletionItem? {
      let selfDot = try sk.sendSync(CompletionRequest(
        textDocument: TextDocumentIdentifier(url),
        position: position))
      return selfDot.items.first { $0.label == label }
    }

    func getTestMethodACompletion() throws -> CompletionItem? {
      return try getTestMethodCompletion(Position(line: 5, utf16index: 9), label: "test(a: Int)")
    }

    func getTestMethodBCompletion() throws -> CompletionItem? {
      return try getTestMethodCompletion(Position(line: 9, utf16index: 9), label: "test(b: Int)")
    }

    var test = try getTestMethodACompletion()
    XCTAssertNotNil(test)
    if let test = test {
      XCTAssertEqual(test.kind, .method)
      XCTAssertEqual(test.detail, "Void")
      XCTAssertEqual(test.filterText, "test(a:)")
        XCTAssertEqual(test.textEdit, TextEdit(range: Position(line: 5, utf16index: 9)..<Position(line: 5, utf16index: 9), newText: "test(a: ${1:Int})"))
      XCTAssertEqual(test.insertText, "test(a: ${1:Int})")
      XCTAssertEqual(test.insertTextFormat, .snippet)
    }

    test = try getTestMethodBCompletion()
    XCTAssertNotNil(test)
    if let test = test {
      XCTAssertEqual(test.kind, .method)
      XCTAssertEqual(test.detail, "Void")
      XCTAssertEqual(test.filterText, "test(:)")
      XCTAssertEqual(test.textEdit, TextEdit(range: Position(line: 9, utf16index: 9)..<Position(line: 9, utf16index: 9), newText: "test(${1:b: Int})"))
      XCTAssertEqual(test.insertText, "test(${1:b: Int})")
      XCTAssertEqual(test.insertTextFormat, .snippet)
    }

    shutdownServer()
    capabilities.completionItem?.snippetSupport = false
    initializeServer(capabilities: capabilities)
    openDocument(url: url)

    test = try getTestMethodACompletion()
    XCTAssertNotNil(test)
    if let test = test {
      XCTAssertEqual(test.kind, .method)
      XCTAssertEqual(test.detail, "Void")
      XCTAssertEqual(test.filterText, "test(a:)")
      XCTAssertEqual(test.textEdit, TextEdit(range: Position(line: 5, utf16index: 9)..<Position(line: 5, utf16index: 9), newText: "test(a: )"))
      XCTAssertEqual(test.insertText, "test(a: )")
      XCTAssertEqual(test.insertTextFormat, .plain)
    }

    test = try getTestMethodBCompletion()
    XCTAssertNotNil(test)
    if let test = test {
      XCTAssertEqual(test.kind, .method)
      XCTAssertEqual(test.detail, "Void")
      XCTAssertEqual(test.filterText, "test(:)")
      // FIXME:
        XCTAssertEqual(test.textEdit, TextEdit(range: Position(line: 9, utf16index: 9)..<Position(line: 9, utf16index: 9), newText: "test()"))
      XCTAssertEqual(test.insertText, "test()")
      XCTAssertEqual(test.insertTextFormat, .plain)
    }
  }

  func testCompletionPositionClientFilter() throws {
    try testCompletionPosition(options: SKCompletionOptions(serverSideFiltering: false, maxResults: nil))
  }

  func testCompletionPositionServerFilter() throws {
    try testCompletionPosition(options: SKCompletionOptions(serverSideFiltering: true, maxResults: nil))
  }

  func testCompletionPosition(options: SKCompletionOptions) throws {
    initializeServer(options: options)
    let url = URL(fileURLWithPath: "/\(UUID())/a.swift")
    openDocument(text: "foo", url: url)

    for col in 0 ... 3 {
      let inOrAfterFoo = try sk.sendSync(CompletionRequest(
        textDocument: TextDocumentIdentifier(url),
        position: Position(line: 0, utf16index: col)))
      XCTAssertEqual(inOrAfterFoo.isIncomplete, options.serverSideFiltering)
      XCTAssertFalse(inOrAfterFoo.items.isEmpty)
    }

    let outOfRange1 = try sk.sendSync(CompletionRequest(
      textDocument: TextDocumentIdentifier(url),
      position: Position(line: 0, utf16index: 4)))
    XCTAssertTrue(outOfRange1.isIncomplete)

    let outOfRange2 = try sk.sendSync(CompletionRequest(
      textDocument: TextDocumentIdentifier(url),
      position: Position(line: 1, utf16index: 0)))
    XCTAssertTrue(outOfRange2.isIncomplete)
  }

  func testCompletionOptional() throws {
    initializeServer()
    let url = URL(fileURLWithPath: "/\(UUID())/a.swift")
    let text = """
    struct Foo {
      let bar: Int
    }
    let a: Foo? = Foo(bar: 1)
    a.ba
    """
    openDocument(text: text, url: url)

    for col in 2...4 {
      let response = try sk.sendSync(CompletionRequest(
        textDocument: TextDocumentIdentifier(url),
        position: Position(line: 4, utf16index: col)))

      guard let item = response.items.first(where: { $0.label.contains("bar") }) else {
        XCTFail("No completion item with label 'bar'")
        return
      }
      XCTAssertEqual(item.filterText, ".bar")
      XCTAssertEqual(item.textEdit, TextEdit(range: Position(line: 4, utf16index: 1)..<Position(line: 4, utf16index: col), newText: "?.bar"))
    }
  }

  func testCompletionOverride() throws {
    initializeServer()
    let url = URL(fileURLWithPath: "/\(UUID())/a.swift")
    let text = """
    class Base {
      func foo() {}
    }
    class C: Base {
      func    // don't delete trailing space in this file
    }
    """
    openDocument(text: text, url: url)

    let response = try sk.sendSync(CompletionRequest(
      textDocument: TextDocumentIdentifier(url),
      position: Position(line: 4, utf16index: 7)))
    guard let item = response.items.first(where: { $0.label == "foo()" }) else {
      XCTFail("No completion item with label 'foo()'")
      return
    }
    // FIXME: should be "foo()"
    XCTAssertEqual(item.filterText, "func foo()")
    XCTAssertEqual(item.textEdit, TextEdit(range: Position(line: 4, utf16index: 2)..<Position(line: 4, utf16index: 7), newText: "override func foo() {\n\n}"))
  }

  func testCompletionOverrideInNewLine() throws {
    initializeServer()
    let url = URL(fileURLWithPath: "/\(UUID())/a.swift")
    let text = """
    class Base {
      func foo() {}
    }
    class C: Base {
      func
        // don't delete trailing space in this file
    }
    """
    openDocument(text: text, url: url)

    let response = try sk.sendSync(CompletionRequest(
      textDocument: TextDocumentIdentifier(url),
      position: Position(line: 5, utf16index: 2)))
    guard let item = response.items.first(where: { $0.label == "foo()" }) else {
      XCTFail("No completion item with label 'foo()'")
      return
    }
    // If the edit would cross multiple lines, we are currently not replacing any text. It's not technically correct but the best we can do.
    XCTAssertEqual(item.filterText, "foo()")
    XCTAssertEqual(item.textEdit, TextEdit(range: Position(line: 5, utf16index: 2)..<Position(line: 5, utf16index: 2), newText: "override func foo() {\n\n}"))
  }

  func testMaxResults() throws {
    initializeServer(options: SKCompletionOptions(serverSideFiltering: true, maxResults: nil))
    let url = URL(fileURLWithPath: "/\(UUID())/a.swift")
    openDocument(text: """
      struct S {
        func f1() {}
        func f2() {}
        func f3() {}
        func f4() {}
        func f5() {}
        func test() {
          self.f
        }
      }
      """, url: url)

    // Server-wide option
    XCTAssertEqual(5, countFs(try sk.sendSync(CompletionRequest(
                                                textDocument: TextDocumentIdentifier(url),
                                                position: Position(line: 7, utf16index: 9)))))

    // Explicit option
    XCTAssertEqual(5, countFs(try sk.sendSync(CompletionRequest(
                                                textDocument: TextDocumentIdentifier(url),
                                                position: Position(line: 7, utf16index: 9),
                                                sourcekitlspOptions:
                                                  SKCompletionOptions(
                                                    serverSideFiltering: true,
                                                    maxResults: nil)))))

    // MARK: Limited

    XCTAssertEqual(5, countFs(try sk.sendSync(CompletionRequest(
                                                textDocument: TextDocumentIdentifier(url),
                                                position: Position(line: 7, utf16index: 9),
                                                sourcekitlspOptions:
                                                  SKCompletionOptions(
                                                    serverSideFiltering: true,
                                                    maxResults: 1000)))))

    XCTAssertEqual(3, countFs(try sk.sendSync(CompletionRequest(
                                                textDocument: TextDocumentIdentifier(url),
                                                position: Position(line: 7, utf16index: 9),
                                                sourcekitlspOptions:
                                                  SKCompletionOptions(
                                                    serverSideFiltering: true,
                                                    maxResults: 3)))))
    XCTAssertEqual(1, countFs(try sk.sendSync(CompletionRequest(
                                                textDocument: TextDocumentIdentifier(url),
                                                position: Position(line: 7, utf16index: 9),
                                                sourcekitlspOptions:
                                                  SKCompletionOptions(
                                                    serverSideFiltering: true,
                                                    maxResults: 1)))))

    // 0 also means unlimited
    XCTAssertEqual(5, countFs(try sk.sendSync(CompletionRequest(
                                                textDocument: TextDocumentIdentifier(url),
                                                position: Position(line: 7, utf16index: 9),
                                                sourcekitlspOptions:
                                                  SKCompletionOptions(
                                                    serverSideFiltering: true,
                                                    maxResults: 0)))))

    // MARK: With filter='f'

    XCTAssertEqual(5, countFs(try sk.sendSync(CompletionRequest(
                                                textDocument: TextDocumentIdentifier(url),
                                                position: Position(line: 7, utf16index: 10),
                                                sourcekitlspOptions:
                                                  SKCompletionOptions(
                                                    serverSideFiltering: true,
                                                    maxResults: nil)))))
    XCTAssertEqual(3, countFs(try sk.sendSync(CompletionRequest(
                                                textDocument: TextDocumentIdentifier(url),
                                                position: Position(line: 7, utf16index: 10),
                                                sourcekitlspOptions:
                                                  SKCompletionOptions(
                                                    serverSideFiltering: true,
                                                    maxResults: 3)))))

  }

  func testRefilterAfterIncompleteResults() throws {
    initializeServer(options: SKCompletionOptions(serverSideFiltering: true, maxResults: 20))
    let url = URL(fileURLWithPath: "/\(UUID())/a.swift")
    openDocument(text: """
      struct S {
        func fooAbc() {}
        func fooBcd() {}
        func fooCde() {}
        func fooDef() {}
        func fooGoop() {}
        func test() {
          self.fcdez
        }
      }
      """, url: url)

    XCTAssertEqual(5, countFs(try sk.sendSync(CompletionRequest(
                                                textDocument: TextDocumentIdentifier(url),
                                                position: Position(line: 7, utf16index: 10),
                                                context:CompletionContext(triggerKind: .invoked)))))

    XCTAssertEqual(3, countFs(try sk.sendSync(CompletionRequest(
                                                textDocument: TextDocumentIdentifier(url),
                                                position: Position(line: 7, utf16index: 11),
                                                context:CompletionContext(triggerKind: .triggerFromIncompleteCompletions)))))
    XCTAssertEqual(2, countFs(try sk.sendSync(CompletionRequest(
                                                textDocument: TextDocumentIdentifier(url),
                                                position: Position(line: 7, utf16index: 12),
                                                context:CompletionContext(triggerKind: .triggerFromIncompleteCompletions)))))
    XCTAssertEqual(1, countFs(try sk.sendSync(CompletionRequest(
                                                textDocument: TextDocumentIdentifier(url),
                                                position: Position(line: 7, utf16index: 13),
                                                context:CompletionContext(triggerKind: .triggerFromIncompleteCompletions)))))
    XCTAssertEqual(0, countFs(try sk.sendSync(CompletionRequest(
                                                textDocument: TextDocumentIdentifier(url),
                                                position: Position(line: 7, utf16index: 14),
                                                context:CompletionContext(triggerKind: .triggerFromIncompleteCompletions)))))
    XCTAssertEqual(2, countFs(try sk.sendSync(CompletionRequest(
                                                textDocument: TextDocumentIdentifier(url),
                                                position: Position(line: 7, utf16index: 12),
                                                context:CompletionContext(triggerKind: .triggerFromIncompleteCompletions)))))

    // Not valid for the current session.
    // We explicitly keep the session and fail any requests that don't match so that the editor
    // can rely on `.triggerFromIncompleteCompletions` always being fast.
    XCTAssertThrowsError(try sk.sendSync(CompletionRequest(
                                          textDocument: TextDocumentIdentifier(url),
                                          position: Position(line: 7, utf16index: 0),
                                          context:CompletionContext(triggerKind: .triggerFromIncompleteCompletions))))
    XCTAssertEqual(1, countFs(try sk.sendSync(CompletionRequest(
                                                textDocument: TextDocumentIdentifier(url),
                                                position: Position(line: 7, utf16index: 13),
                                                context:CompletionContext(triggerKind: .triggerFromIncompleteCompletions)))))

    // Trigger kind changed => OK (20 is maxResults since we're outside the member completion)
    XCTAssertEqual(20, try sk.sendSync(CompletionRequest(
                                        textDocument: TextDocumentIdentifier(url),
                                        position: Position(line: 7, utf16index: 0),
                                          context:CompletionContext(triggerKind: .invoked))).items.count)
  }

  func testRefilterAfterIncompleteResultsWithEdits() throws {
    initializeServer(options: SKCompletionOptions(serverSideFiltering: true, maxResults: nil))
    let url = URL(fileURLWithPath: "/\(UUID())/a.swift")
    openDocument(text: """
      struct S {
        func fooAbc() {}
        func fooBcd() {}
        func fooCde() {}
        func fooDef() {}
        func fooGoop() {}
        func test() {
          self.fz
        }
      }
      """, url: url)

    // 'f'
    XCTAssertEqual(5, countFs(try sk.sendSync(CompletionRequest(
                                                textDocument: TextDocumentIdentifier(url),
                                                position: Position(line: 7, utf16index: 10),
                                                context:CompletionContext(triggerKind: .invoked)))))

    // 'fz'
    XCTAssertEqual(0, countFs(try sk.sendSync(CompletionRequest(
                                                textDocument: TextDocumentIdentifier(url),
                                                position: Position(line: 7, utf16index: 11),
                                                context:CompletionContext(triggerKind: .triggerFromIncompleteCompletions)))))

    sk.send(DidChangeTextDocumentNotification(
              textDocument: VersionedTextDocumentIdentifier(DocumentURI(url), version: 1),
              contentChanges: [
                .init(range: Position(line: 7, utf16index: 10)..<Position(line: 7, utf16index: 11), text: "A ")]))

    // 'fA'
    XCTAssertEqual(1, countFs(try sk.sendSync(CompletionRequest(
                                                textDocument: TextDocumentIdentifier(url),
                                                position: Position(line: 7, utf16index: 11),
                                                context:CompletionContext(triggerKind: .triggerFromIncompleteCompletions)))))

    // 'fA '
    XCTAssertThrowsError(try sk.sendSync(CompletionRequest(
                                          textDocument: TextDocumentIdentifier(url),
                                          position: Position(line: 7, utf16index: 12),
                                          context:CompletionContext(triggerKind: .triggerFromIncompleteCompletions))))

    sk.send(DidChangeTextDocumentNotification(
              textDocument: VersionedTextDocumentIdentifier(DocumentURI(url), version: 1),
              contentChanges: [
                .init(range: Position(line: 7, utf16index: 10)..<Position(line: 7, utf16index: 11), text: "Ab")]))

    // 'fAb'
    XCTAssertEqual(1, countFs(try sk.sendSync(CompletionRequest(
                                                textDocument: TextDocumentIdentifier(url),
                                                position: Position(line: 7, utf16index: 11),
                                                context:CompletionContext(triggerKind: .triggerFromIncompleteCompletions)))))

    sk.send(DidChangeTextDocumentNotification(
              textDocument: VersionedTextDocumentIdentifier(DocumentURI(url), version: 1),
              contentChanges: [
                .init(range: Position(line: 7, utf16index: 10)..<Position(line: 7, utf16index: 11), text: "")]))

    // 'fb'
    XCTAssertEqual(2, countFs(try sk.sendSync(CompletionRequest(
                                                textDocument: TextDocumentIdentifier(url),
                                                position: Position(line: 7, utf16index: 11),
                                                context:CompletionContext(triggerKind: .triggerFromIncompleteCompletions)))))

    sk.send(DidChangeTextDocumentNotification(
              textDocument: VersionedTextDocumentIdentifier(DocumentURI(url), version: 1),
              contentChanges: [
                .init(range: Position(line: 7, utf16index: 11)..<Position(line: 7, utf16index: 11), text: "d")]))

    // 'fbd'
    XCTAssertEqual(1, countFs(try sk.sendSync(CompletionRequest(
                                                textDocument: TextDocumentIdentifier(url),
                                                position: Position(line: 7, utf16index: 12),
                                                context:CompletionContext(triggerKind: .triggerFromIncompleteCompletions)))))
  }

  /// Regression test for https://bugs.swift.org/browse/SR-13561 to make sure the a session
  /// close waits for its respective open to finish to prevent a session geting stuck open.
  func testSessionCloseWaitsforOpen() throws {
    initializeServer(options: SKCompletionOptions(serverSideFiltering: true, maxResults: nil))
    let url = URL(fileURLWithPath: "/\(UUID())/file.swift")
    openDocument(text: """
      struct S {
        func forSomethingCrazy() {}
        func forSomethingCool() {}
        func test() {
          self.forSome
        }
        func print() {}
        func anotherOne() {
          self.prin
        }
      }
      """, url: url)

    let forSomeComplete = CompletionRequest(
          textDocument: TextDocumentIdentifier(url),
        position: Position(line: 4, utf16index: 12), // forS^
        context:CompletionContext(triggerKind: .invoked))
    let printComplete = CompletionRequest(
        textDocument: TextDocumentIdentifier(url),
      position: Position(line: 8, utf16index: 12), // prin^
      context:CompletionContext(triggerKind: .invoked))

    // Code completion for "self.forSome"
    let forSomeExpectation = XCTestExpectation(description: "self.forSome code completion")
    _ = sk.send(forSomeComplete) { result in
      defer { forSomeExpectation.fulfill() }
      guard let list = result.success else {
        XCTFail("Request failed: \(String(describing: result.failure))")
        return
      }
      XCTAssertEqual(2, countFs(list))
    }

    // Code completion for "self.prin", previously could immediately invalidate
    // the previous request.
    let printExpectation = XCTestExpectation(description: "self.prin code completion")
    _ = sk.send(printComplete) { result in
      defer { printExpectation.fulfill() }
      guard let list = result.success else {
        XCTFail("Request failed: \(String(describing: result.failure))")
        return
      }
      XCTAssertEqual(1, list.items.count)
    }

    wait(for: [forSomeExpectation, printExpectation], timeout: defaultTimeout)

    // Try code completion for "self.forSome" again to verify that it still works.
    let result = try sk.sendSync(forSomeComplete)
    XCTAssertEqual(2, countFs(result))
  }
}

private func countFs(_ response: CompletionList) -> Int {
  return response.items.filter{$0.label.hasPrefix("f")}.count
}
