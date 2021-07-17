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

import LanguageServerProtocol
import LSPTestSupport
import SKTestSupport
import SourceKitLSP
import XCTest

private typealias Token = SyntaxHighlightingToken

final class SemanticTokensTests: XCTestCase {
  /// Connection and lifetime management for the service.
  var connection: TestSourceKitServer! = nil

  /// The primary interface to make requests to the SourceKitServer.
  var sk: TestClient! = nil

  override func tearDown() {
    sk = nil
    connection = nil
  }

  override func setUp() {
    connection = TestSourceKitServer()
    sk = connection.client
    _ = try! sk.sendSync(InitializeRequest(
      processId: nil,
      rootPath: nil,
      rootURI: nil,
      initializationOptions: nil,
      capabilities: ClientCapabilities(
        workspace: .init(
          semanticTokens: .init(
            refreshSupport: true
          )
        ),
        textDocument: .init(
          semanticTokens: .init(
            dynamicRegistration: true,
            requests: .init(
              range: .bool(true),
              full: .bool(true)
            ),
            tokenTypes: Token.Kind.allCases.map(\._lspName),
            tokenModifiers: Token.Modifiers.allCases.map { $0._lspName! },
            formats: [.relative]
          )
        )
      ),
      trace: .off,
      workspaceFolders: nil
    ))
  }

  private func performSemanticTokensRequest(text: String, range: Range<Position>? = nil) -> [Token] {
    let url = URL(fileURLWithPath: "/\(#function)/a.swift")

    // We will wait for the server to dynamically register semantic tokens

    let registerCapabilityExpectation = expectation(description: "performSemanticTokensRequest - register semantic tokens capability")
    sk.appendOneShotRequestHandler { (req: Request<RegisterCapabilityRequest>) in
      let registrations = req.params.registrations
      XCTAssert(registrations.contains { reg in
        reg.method == SemanticTokensRegistrationOptions.method
      })
      req.reply(VoidResponse())
      registerCapabilityExpectation.fulfill()
    }

    // We will wait for the first refresh request to make sure that the semantic tokens are ready

    let refreshExpectation = expectation(description: "performSemanticTokensRequest - refresh received")
    sk.appendOneShotRequestHandler { (req: Request<WorkspaceSemanticTokensRefreshRequest>) in
      req.reply(VoidResponse())
      refreshExpectation.fulfill()
    }

    sk.send(DidOpenTextDocumentNotification(textDocument: TextDocumentItem(
      uri: DocumentURI(url),
      language: .swift,
      version: 17,
      text: text
    )))

    wait(for: [registerCapabilityExpectation, refreshExpectation], timeout: 15)

    let textDocument = TextDocumentIdentifier(url)
    let response: DocumentSemanticTokensResponse!

    if let range = range {
      response = try! sk.sendSync(DocumentSemanticTokensRangeRequest(textDocument: textDocument, range: range))
    } else {
      response = try! sk.sendSync(DocumentSemanticTokensRequest(textDocument: textDocument))
    }

    return [Token](lspEncodedTokens: response.data)
  }

  func testIntArrayCoding() {
    let tokens = [
      Token(
        start: Position(line: 2, utf16index: 3),
        length: 5,
        kind: .string
      ),
      Token(
        start: Position(line: 4, utf16index: 2),
        length: 1,
        kind: .interface,
        modifiers: [.deprecated, .definition]
      ),
    ]

    let encoded = tokens.lspEncoded
    XCTAssertEqual(encoded, [
      2, // line delta
      3, // char delta
      5, // length
      Token.Kind.string.rawValue, // kind
      0, // modifiers

      2, // line delta
      2, // char delta
      1, // length
      Token.Kind.interface.rawValue, // kind
      Token.Modifiers.deprecated.rawValue | Token.Modifiers.definition.rawValue, // modifiers
    ])

    let decoded = [Token](lspEncodedTokens: encoded)
    XCTAssertEqual(decoded, tokens)
  }

  func testEmpty() {
    let text = ""
    let tokens = performSemanticTokensRequest(text: text)
    XCTAssertEqual(tokens, [])
  }

  func testRanged() {
    let text = """
    let x = 1
    let test = 20
    let abc = 333
    let y = 4
    """
    let start = Position(line: 1, utf16index: 0)
    let end = Position(line: 2, utf16index: 5)
    let tokens = performSemanticTokensRequest(text: text, range: start..<end)
    XCTAssertEqual(tokens, [
      Token(start: Position(line: 1, utf16index: 0), length: 3, kind: .keyword),
      Token(start: Position(line: 1, utf16index: 4), length: 4, kind: .variable, modifiers: .declaration),
      Token(start: Position(line: 1, utf16index: 11), length: 2, kind: .number),
      Token(start: Position(line: 2, utf16index: 0), length: 3, kind: .keyword),
      Token(start: Position(line: 2, utf16index: 4), length: 3, kind: .variable, modifiers: .declaration),
    ])
  }

  func testSyntacticTokens() {
    let text = """
    let x = 3
    var y = "test"
    /* abc */ // 123
    """
    let tokens = performSemanticTokensRequest(text: text)
    XCTAssertEqual(tokens, [
      // let x = 3
      Token(start: Position(line: 0, utf16index: 0), length: 3, kind: .keyword),
      Token(start: Position(line: 0, utf16index: 4), length: 1, kind: .variable, modifiers: .declaration),
      Token(start: Position(line: 0, utf16index: 8), length: 1, kind: .number),
      // var y = "test"
      Token(start: Position(line: 1, utf16index: 0), length: 3, kind: .keyword),
      Token(start: Position(line: 1, utf16index: 4), length: 1, kind: .variable, modifiers: .declaration),
      Token(start: Position(line: 1, utf16index: 8), length: 6, kind: .string),
      // /* abc */ // 123
      Token(start: Position(line: 2, utf16index: 0), length: 9, kind: .comment),
      Token(start: Position(line: 2, utf16index: 10), length: 6, kind: .comment),
    ])
  }

  func testSyntacticTokensForMultiLineComments() {
    let text = """
    let x = 3 /*
    let x = 12
    */
    """
    let tokens = performSemanticTokensRequest(text: text)
    XCTAssertEqual(tokens, [
      Token(start: Position(line: 0, utf16index: 0), length: 3, kind: .keyword),
      Token(start: Position(line: 0, utf16index: 4), length: 1, kind: .variable, modifiers: .declaration),
      Token(start: Position(line: 0, utf16index: 8), length: 1, kind: .number),
      // Multi-line comments are split into single-line tokens
      Token(start: Position(line: 0, utf16index: 10), length: 2, kind: .comment),
      Token(start: Position(line: 1, utf16index: 0), length: 10, kind: .comment),
      Token(start: Position(line: 2, utf16index: 0), length: 2, kind: .comment),
    ])
  }

  func testSyntacticTokensForDocComments() {
    let text = """
    /** abc */
      /// def
    """
    let tokens = performSemanticTokensRequest(text: text)
    XCTAssertEqual(tokens, [
      Token(start: Position(line: 0, utf16index: 0), length: 10, kind: .comment, modifiers: [.documentation]),
      Token(start: Position(line: 1, utf16index: 2), length: 7, kind: .comment, modifiers: [.documentation]),
    ])
  }

  func testSyntacticTokensForBackticks() {
    let text = """
    var `if` = 20
    let `else` = 3
    """
    let tokens = performSemanticTokensRequest(text: text)
    XCTAssertEqual(tokens, [
      // var `if` = 20
      Token(start: Position(line: 0, utf16index: 0), length: 3, kind: .keyword),
      Token(start: Position(line: 0, utf16index: 4), length: 4, kind: .variable, modifiers: .declaration),
      Token(start: Position(line: 0, utf16index: 11), length: 2, kind: .number),
      // let `else` = 3
      Token(start: Position(line: 1, utf16index: 0), length: 3, kind: .keyword),
      Token(start: Position(line: 1, utf16index: 4), length: 6, kind: .variable, modifiers: .declaration),
      Token(start: Position(line: 1, utf16index: 13), length: 1, kind: .number)
    ])
  }

  func testSemanticTokens() {
    let text = """
    struct X {}

    let x = X()
    let y = x + x

    func a() {}
    let b = {}

    a()
    b()
    """
    let tokens = performSemanticTokensRequest(text: text)
    XCTAssertEqual(tokens, [
      // struct X {}
      Token(start: Position(line: 0, utf16index: 0), length: 6, kind: .keyword),
      Token(start: Position(line: 0, utf16index: 7), length: 1, kind: .struct, modifiers: .declaration),
      // let x = X()
      Token(start: Position(line: 2, utf16index: 0), length: 3, kind: .keyword),
      Token(start: Position(line: 2, utf16index: 4), length: 1, kind: .variable, modifiers: .declaration),
      Token(start: Position(line: 2, utf16index: 8), length: 1, kind: .struct),
      // let y = x + x
      Token(start: Position(line: 3, utf16index: 0), length: 3, kind: .keyword),
      Token(start: Position(line: 3, utf16index: 4), length: 1, kind: .variable, modifiers: .declaration),
      Token(start: Position(line: 3, utf16index: 8), length: 1, kind: .variable),
      Token(start: Position(line: 3, utf16index: 12), length: 1, kind: .variable),
      // func a() {}
      Token(start: Position(line: 5, utf16index: 0), length: 4, kind: .keyword),
      Token(start: Position(line: 5, utf16index: 5), length: 1, kind: .function, modifiers: .declaration),
      // let b = {}
      Token(start: Position(line: 6, utf16index: 0), length: 3, kind: .keyword),
      Token(start: Position(line: 6, utf16index: 4), length: 1, kind: .variable, modifiers: .declaration),
      // a()
      Token(start: Position(line: 8, utf16index: 0), length: 1, kind: .function),
      // b()
      Token(start: Position(line: 9, utf16index: 0), length: 1, kind: .variable),
    ])
  }

  func testSemanticTokensForProtocols() {
    let text = """
    protocol X {}
    class Y: X {}

    let y: Y = X()

    func f<T: X>() {}
    """
    let tokens = performSemanticTokensRequest(text: text)
    XCTAssertEqual(tokens, [
      // protocol X {}
      Token(start: Position(line: 0, utf16index: 0), length: 8, kind: .keyword),
      Token(start: Position(line: 0, utf16index: 9), length: 1, kind: .interface, modifiers: .declaration),
      // class Y: X {}
      Token(start: Position(line: 1, utf16index: 0), length: 5, kind: .keyword),
      Token(start: Position(line: 1, utf16index: 6), length: 1, kind: .class, modifiers: .declaration),
      Token(start: Position(line: 1, utf16index: 9), length: 1, kind: .interface),
      // let y: Y = X()
      Token(start: Position(line: 3, utf16index: 0), length: 3, kind: .keyword),
      Token(start: Position(line: 3, utf16index: 4), length: 1, kind: .variable, modifiers: .declaration),
      Token(start: Position(line: 3, utf16index: 7), length: 1, kind: .class),
      Token(start: Position(line: 3, utf16index: 11), length: 1, kind: .interface),
      // func f<T: X>() {}
      Token(start: Position(line: 5, utf16index: 0), length: 4, kind: .keyword),
      Token(start: Position(line: 5, utf16index: 5), length: 1, kind: .function, modifiers: .declaration),
      Token(start: Position(line: 5, utf16index: 7), length: 1, kind: .typeParameter, modifiers: .declaration),
      Token(start: Position(line: 5, utf16index: 10), length: 1, kind: .interface),
    ])
  }

  func testSemanticTokensForFunctionSignatures() {
    let text = "func f(x: Int, _ y: String) {}"
    let tokens = performSemanticTokensRequest(text: text)
    XCTAssertEqual(tokens, [
      Token(start: Position(line: 0, utf16index: 0), length: 4, kind: .keyword),
      Token(start: Position(line: 0, utf16index: 5), length: 1, kind: .function, modifiers: .declaration),
      // Parameter labels use .function as a kind, see parseKindAndModifiers for rationale
      Token(start: Position(line: 0, utf16index: 7), length: 1, kind: .function, modifiers: .declaration),
      Token(start: Position(line: 0, utf16index: 10), length: 3, kind: .struct),
      Token(start: Position(line: 0, utf16index: 15), length: 1, kind: .keyword),
      Token(start: Position(line: 0, utf16index: 20), length: 6, kind: .struct),
    ])
  }

  func testSemanticTokensForFunctionSignaturesWithEmoji() {
    let text = "func 👍abc() {}"
    let tokens = performSemanticTokensRequest(text: text)
    XCTAssertEqual(tokens, [
      Token(start: Position(line: 0, utf16index: 0), length: 4, kind: .keyword),
      Token(start: Position(line: 0, utf16index: 5), length: 5, kind: .function, modifiers: .declaration),
    ])
  }

  func testSemanticTokensForStaticMethods() {
    let text = """
    class X {
      deinit {}
      static func f() {}
      class func g() {}
    }
    X.f()
    X.g()
    """
    let tokens = performSemanticTokensRequest(text: text)
    XCTAssertEqual(tokens, [
      // class X
      Token(start: Position(line: 0, utf16index: 0), length: 5, kind: .keyword),
      Token(start: Position(line: 0, utf16index: 6), length: 1, kind: .class, modifiers: .declaration),
      // deinit {}
      Token(start: Position(line: 1, utf16index: 2), length: 6, kind: .method, modifiers: .declaration),
      // static func f() {}
      Token(start: Position(line: 2, utf16index: 2), length: 6, kind: .keyword),
      Token(start: Position(line: 2, utf16index: 9), length: 4, kind: .keyword),
      Token(start: Position(line: 2, utf16index: 14), length: 1, kind: .method, modifiers: [.declaration, .static]),
      // class func g() {}
      Token(start: Position(line: 3, utf16index: 2), length: 5, kind: .keyword),
      Token(start: Position(line: 3, utf16index: 8), length: 4, kind: .keyword),
      Token(start: Position(line: 3, utf16index: 13), length: 1, kind: .method, modifiers: [.declaration, .static]),
      // X.f()
      Token(start: Position(line: 5, utf16index: 0), length: 1, kind: .class),
      Token(start: Position(line: 5, utf16index: 2), length: 1, kind: .method, modifiers: [.static]),
      // X.g()
      Token(start: Position(line: 6, utf16index: 0), length: 1, kind: .class),
      Token(start: Position(line: 6, utf16index: 2), length: 1, kind: .method, modifiers: [.static]),
    ])
  }

  func testSemanticTokensForEnumMembers() {
    let text = """
    enum Maybe<T> {
      case none
      case some(T)
    }

    let x = Maybe<String>.none
    let y: Maybe = .some(42)
    """
    let tokens = performSemanticTokensRequest(text: text)
    XCTAssertEqual(tokens, [
      // enum Maybe<T>
      Token(start: Position(line: 0, utf16index: 0), length: 4, kind: .keyword),
      Token(start: Position(line: 0, utf16index: 5), length: 5, kind: .enum, modifiers: .declaration),
      Token(start: Position(line: 0, utf16index: 11), length: 1, kind: .typeParameter, modifiers: .declaration),
      // case none
      Token(start: Position(line: 1, utf16index: 2), length: 4, kind: .keyword),
      Token(start: Position(line: 1, utf16index: 7), length: 4, kind: .enumMember, modifiers: .declaration),
      // case some
      Token(start: Position(line: 2, utf16index: 2), length: 4, kind: .keyword),
      Token(start: Position(line: 2, utf16index: 7), length: 4, kind: .enumMember, modifiers: .declaration),
      Token(start: Position(line: 2, utf16index: 12), length: 1, kind: .typeParameter),
      // let x = Maybe<String>.none
      Token(start: Position(line: 5, utf16index: 0), length: 3, kind: .keyword),
      Token(start: Position(line: 5, utf16index: 4), length: 1, kind: .variable, modifiers: .declaration),
      Token(start: Position(line: 5, utf16index: 8), length: 5, kind: .enum),
      Token(start: Position(line: 5, utf16index: 14), length: 6, kind: .struct),
      Token(start: Position(line: 5, utf16index: 22), length: 4, kind: .enumMember),
      // let y: Maybe = .some(42)
      Token(start: Position(line: 6, utf16index: 0), length: 3, kind: .keyword),
      Token(start: Position(line: 6, utf16index: 4), length: 1, kind: .variable, modifiers: .declaration),
      Token(start: Position(line: 6, utf16index: 7), length: 5, kind: .enum),
      Token(start: Position(line: 6, utf16index: 16), length: 4, kind: .enumMember),
      Token(start: Position(line: 6, utf16index: 21), length: 2, kind: .number),
    ])
  }
}
