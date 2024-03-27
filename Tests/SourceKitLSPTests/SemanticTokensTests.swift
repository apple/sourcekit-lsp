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
import SourceKitD
import SourceKitLSP
import XCTest

private typealias Token = SyntaxHighlightingToken

final class SemanticTokensTests: XCTestCase {
  /// The mock client used to communicate with the SourceKit-LSP server.
  ///
  /// - Note: Set before each test run in `setUp`.
  private var testClient: TestSourceKitLSPClient! = nil

  /// The URI of the document that is being tested by the current test case.
  ///
  /// - Note: This URI is set to a unique value before each test case in `setUp`.
  private var uri: DocumentURI!

  /// The current version of the document being opened.
  ///
  /// - Note: This gets reset to 0 in `setUp` and incremented on every call to
  ///   `openDocument` and `editDocument`.
  private var version: Int = 0

  override func setUp() async throws {
    version = 0
    uri = DocumentURI(URL(fileURLWithPath: "/SemanticTokensTests/\(UUID()).swift"))
    testClient = try await TestSourceKitLSPClient(
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
            tokenTypes: SemanticTokenTypes.all.map(\.name),
            tokenModifiers: SemanticTokenModifiers.all.compactMap(\.name),
            formats: [.relative]
          )
        )
      ),
      usePullDiagnostics: false
    )
  }

  override func tearDown() {
    testClient = nil
  }

  private func openDocument(text: String) {
    // We will wait for the server to dynamically register semantic tokens

    let registerCapabilityExpectation = expectation(description: "\(#function) - register semantic tokens capability")
    testClient.handleNextRequest { (req: RegisterCapabilityRequest) -> VoidResponse in
      let capabilityRegistration = req.registrations.first { reg in
        reg.method == SemanticTokensRegistrationOptions.method
      }

      guard case .dictionary(let registerOptionsDict) = capabilityRegistration?.registerOptions,
        let registerOptions = SemanticTokensRegistrationOptions(fromLSPDictionary: registerOptionsDict)
      else {
        XCTFail("Expected semantic tokens registration options dictionary")
        return VoidResponse()
      }

      XCTAssertFalse(
        registerOptions.semanticTokenOptions.legend.tokenTypes.isEmpty,
        "Expected semantic tokens legend"
      )

      registerCapabilityExpectation.fulfill()
      return VoidResponse()
    }

    // We will wait for the first refresh request to make sure that the semantic tokens are ready

    testClient.openDocument(text, uri: uri)
    version += 1

    wait(for: [registerCapabilityExpectation], timeout: defaultTimeout)
  }

  private func editDocument(changes: [TextDocumentContentChangeEvent], expectRefresh: Bool = true) {
    // We wait for the semantic tokens again
    // Note that we assume to already have called openDocument before

    testClient.send(
      DidChangeTextDocumentNotification(
        textDocument: VersionedTextDocumentIdentifier(
          uri,
          version: version
        ),
        contentChanges: changes
      )
    )
    version += 1
  }

  private func editDocument(range: Range<Position>, text: String, expectRefresh: Bool = true) {
    editDocument(
      changes: [
        TextDocumentContentChangeEvent(
          range: range,
          text: text
        )
      ],
      expectRefresh: expectRefresh
    )
  }

  private func performSemanticTokensRequest(range: Range<Position>? = nil) async throws -> SyntaxHighlightingTokens {
    try await SkipUnless.sourcekitdHasSemanticTokensRequest()
    let response: DocumentSemanticTokensResponse!

    if let range = range {
      response = try await testClient.send(
        DocumentSemanticTokensRangeRequest(
          textDocument: TextDocumentIdentifier(uri),
          range: range
        )
      )
    } else {
      response = try await testClient.send(
        DocumentSemanticTokensRequest(
          textDocument: TextDocumentIdentifier(uri)
        )
      )
    }

    return SyntaxHighlightingTokens(lspEncodedTokens: response.data)
  }

  private func openAndPerformSemanticTokensRequest(
    text: String,
    range: Range<Position>? = nil
  ) async throws -> SyntaxHighlightingTokens {
    openDocument(text: text)
    return try await performSemanticTokensRequest(range: range)
  }

  func testIntArrayCoding() async throws {
    let tokens = SyntaxHighlightingTokens(tokens: [
      Token(
        start: Position(line: 2, utf16index: 3),
        utf16length: 5,
        kind: .string
      ),
      Token(
        start: Position(line: 4, utf16index: 2),
        utf16length: 1,
        kind: .interface,
        modifiers: [.deprecated, .definition]
      ),
    ])

    let encoded = tokens.lspEncoded
    XCTAssertEqual(
      encoded,
      [
        2,  // line delta
        3,  // char delta
        5,  // length
        SemanticTokenTypes.string.tokenType,  // kind
        0,  // modifiers

        2,  // line delta
        2,  // char delta
        1,  // length
        SemanticTokenTypes.interface.tokenType,  // kind
        SemanticTokenModifiers.deprecated.rawValue | SemanticTokenModifiers.definition.rawValue,  // modifiers
      ]
    )

    let decoded = SyntaxHighlightingTokens(lspEncodedTokens: encoded)
    XCTAssertEqual(decoded.tokens, tokens.tokens)
  }

  func testRangeSplitting() async throws {
    let text = """
      struct X {
        let x: Int
        let y: String


      }
      """
    openDocument(text: text)

    let snapshot = try await testClient.server._documentManager.latestSnapshot(uri)

    let empty = Position(line: 0, utf16index: 1)..<Position(line: 0, utf16index: 1)
    XCTAssertEqual(empty._splitToSingleLineRanges(in: snapshot), [])

    let multiLine = Position(line: 1, utf16index: 6)..<Position(line: 2, utf16index: 7)
    XCTAssertEqual(
      multiLine._splitToSingleLineRanges(in: snapshot),
      [
        Position(line: 1, utf16index: 6)..<Position(line: 1, utf16index: 12),
        Position(line: 2, utf16index: 0)..<Position(line: 2, utf16index: 7),
      ]
    )

    let emptyLines = Position(line: 2, utf16index: 14)..<Position(line: 5, utf16index: 1)
    XCTAssertEqual(
      emptyLines._splitToSingleLineRanges(in: snapshot),
      [
        Position(line: 2, utf16index: 14)..<Position(line: 2, utf16index: 15),
        Position(line: 5, utf16index: 0)..<Position(line: 5, utf16index: 1),
      ]
    )
  }

  func testEmpty() async throws {
    let text = ""
    let tokens = try await openAndPerformSemanticTokensRequest(text: text)
    XCTAssertEqual(tokens.tokens, [])
  }

  func testRanged() async throws {
    let text = """
      let x = 1
      let test = 20
      let abc = 333
      let y = 4
      """
    let start = Position(line: 1, utf16index: 0)
    let end = Position(line: 2, utf16index: 5)
    let tokens = try await openAndPerformSemanticTokensRequest(text: text, range: start..<end)
    XCTAssertEqual(
      tokens.tokens,
      [
        Token(line: 1, utf16index: 0, length: 3, kind: .keyword),
        Token(line: 1, utf16index: 4, length: 4, kind: .identifier),
        Token(line: 1, utf16index: 11, length: 2, kind: .number),
        Token(line: 2, utf16index: 0, length: 3, kind: .keyword),
        Token(line: 2, utf16index: 4, length: 3, kind: .identifier),
      ]
    )
  }

  func testLexicalTokens() async throws {
    let text = """
      let x = 3
      var y = "test"
      /* abc */ // 123
      """
    let tokens = try await openAndPerformSemanticTokensRequest(text: text)
    XCTAssertEqual(
      tokens.tokens,
      [
        // let x = 3
        Token(line: 0, utf16index: 0, length: 3, kind: .keyword),
        Token(line: 0, utf16index: 4, length: 1, kind: .identifier),
        Token(line: 0, utf16index: 8, length: 1, kind: .number),
        // var y = "test"
        Token(line: 1, utf16index: 0, length: 3, kind: .keyword),
        Token(line: 1, utf16index: 4, length: 1, kind: .identifier),
        Token(line: 1, utf16index: 8, length: 6, kind: .string),
        // /* abc */ // 123
        Token(line: 2, utf16index: 0, length: 9, kind: .comment),
        Token(line: 2, utf16index: 10, length: 6, kind: .comment),
      ]
    )
  }

  func testLexicalTokensForMultiLineComments() async throws {
    let text = """
      let x = 3 /*
      let x = 12
      */
      """
    let tokens = try await openAndPerformSemanticTokensRequest(text: text)
    XCTAssertEqual(
      tokens.tokens,
      [
        Token(line: 0, utf16index: 0, length: 3, kind: .keyword),
        Token(line: 0, utf16index: 4, length: 1, kind: .identifier),
        Token(line: 0, utf16index: 8, length: 1, kind: .number),
        // Multi-line comments are split into single-line tokens
        Token(line: 0, utf16index: 10, length: 2, kind: .comment),
        Token(line: 1, utf16index: 0, length: 10, kind: .comment),
        Token(line: 2, utf16index: 0, length: 2, kind: .comment),
      ]
    )
  }

  func testLexicalTokensForDocComments() async throws {
    let text = """
      /** abc */
        /// def
      """
    let tokens = try await openAndPerformSemanticTokensRequest(text: text)
    XCTAssertEqual(
      tokens.tokens,
      [
        Token(line: 0, utf16index: 0, length: 10, kind: .comment, modifiers: [.documentation]),
        Token(line: 1, utf16index: 2, length: 7, kind: .comment, modifiers: [.documentation]),
      ]
    )
  }

  func testLexicalTokensForBackticks() async throws {
    let text = """
      var `if` = 20
      let `else` = 3
      let `onLeft = ()
      let onRight` = ()
      """
    let tokens = try await openAndPerformSemanticTokensRequest(text: text)
    XCTAssertEqual(
      tokens.tokens,
      [
        // var `if` = 20
        Token(line: 0, utf16index: 0, length: 3, kind: .keyword),
        Token(line: 0, utf16index: 4, length: 4, kind: .identifier),
        Token(line: 0, utf16index: 11, length: 2, kind: .number),
        // let `else` = 3
        Token(line: 1, utf16index: 0, length: 3, kind: .keyword),
        Token(line: 1, utf16index: 4, length: 6, kind: .identifier),
        Token(line: 1, utf16index: 13, length: 1, kind: .number),
        // let `onLeft = ()
        Token(line: 2, utf16index: 0, length: 3, kind: .keyword),
        Token(line: 2, utf16index: 5, length: 6, kind: .identifier),
        // let onRight` = ()
        Token(line: 3, utf16index: 0, length: 3, kind: .keyword),
        Token(line: 3, utf16index: 4, length: 7, kind: .identifier),
      ]
    )
  }

  func testSemanticTokens() async throws {
    let text = """
      struct X {}

      let x = X()
      let y = x + x

      func a() {}
      let b = {}

      a()
      b()
      """
    let tokens = try await openAndPerformSemanticTokensRequest(text: text)
    XCTAssertEqual(
      tokens.tokens,
      [
        // struct X {}
        Token(line: 0, utf16index: 0, length: 6, kind: .keyword),
        Token(line: 0, utf16index: 7, length: 1, kind: .identifier),
        // let x = X()
        Token(line: 2, utf16index: 0, length: 3, kind: .keyword),
        Token(line: 2, utf16index: 4, length: 1, kind: .identifier),
        Token(line: 2, utf16index: 8, length: 1, kind: .struct),
        // let y = x + x
        Token(line: 3, utf16index: 0, length: 3, kind: .keyword),
        Token(line: 3, utf16index: 4, length: 1, kind: .identifier),
        Token(line: 3, utf16index: 8, length: 1, kind: .variable),
        Token(line: 3, utf16index: 10, length: 1, kind: .operator),
        Token(line: 3, utf16index: 12, length: 1, kind: .variable),
        // func a() {}
        Token(line: 5, utf16index: 0, length: 4, kind: .keyword),
        Token(line: 5, utf16index: 5, length: 1, kind: .identifier),
        // let b = {}
        Token(line: 6, utf16index: 0, length: 3, kind: .keyword),
        Token(line: 6, utf16index: 4, length: 1, kind: .identifier),
        // a()
        Token(line: 8, utf16index: 0, length: 1, kind: .function),
        // b()
        Token(line: 9, utf16index: 0, length: 1, kind: .variable),
      ]
    )
  }

  func testSemanticTokensForProtocols() async throws {
    let text = """
      protocol X {}
      class Y: X {}

      let y: Y = X()

      func f<T: X>() {}
      """
    let tokens = try await openAndPerformSemanticTokensRequest(text: text)
    XCTAssertEqual(
      tokens.tokens,
      [
        // protocol X {}
        Token(line: 0, utf16index: 0, length: 8, kind: .keyword),
        Token(line: 0, utf16index: 9, length: 1, kind: .identifier),
        // class Y: X {}
        Token(line: 1, utf16index: 0, length: 5, kind: .keyword),
        Token(line: 1, utf16index: 6, length: 1, kind: .identifier),
        Token(line: 1, utf16index: 9, length: 1, kind: .interface),
        // let y: Y = X()
        Token(line: 3, utf16index: 0, length: 3, kind: .keyword),
        Token(line: 3, utf16index: 4, length: 1, kind: .identifier),
        Token(line: 3, utf16index: 7, length: 1, kind: .class),
        Token(line: 3, utf16index: 11, length: 1, kind: .interface),
        // func f<T: X>() {}
        Token(line: 5, utf16index: 0, length: 4, kind: .keyword),
        Token(line: 5, utf16index: 5, length: 1, kind: .identifier),
        Token(line: 5, utf16index: 7, length: 1, kind: .identifier),
        Token(line: 5, utf16index: 10, length: 1, kind: .interface),
      ]
    )
  }

  func testSemanticTokensForFunctionSignatures() async throws {
    let text = "func f(x: Int, _ y: String) {}"
    let tokens = try await openAndPerformSemanticTokensRequest(text: text)
    XCTAssertEqual(
      tokens.tokens,
      [
        Token(line: 0, utf16index: 0, length: 4, kind: .keyword),
        Token(line: 0, utf16index: 5, length: 1, kind: .identifier),
        Token(line: 0, utf16index: 7, length: 1, kind: .function),
        Token(line: 0, utf16index: 10, length: 3, kind: .struct, modifiers: .defaultLibrary),
        Token(line: 0, utf16index: 17, length: 1, kind: .identifier),
        Token(line: 0, utf16index: 20, length: 6, kind: .struct, modifiers: .defaultLibrary),
      ]
    )
  }

  func testSemanticTokensForFunctionSignaturesWithEmoji() async throws {
    let text = "func x👍y() {}"
    let tokens = try await openAndPerformSemanticTokensRequest(text: text)
    XCTAssertEqual(
      tokens.tokens,
      [
        Token(line: 0, utf16index: 0, length: 4, kind: .keyword),
        Token(line: 0, utf16index: 5, length: 4, kind: .identifier),
      ]
    )
  }

  func testSemanticTokensForStaticMethods() async throws {
    let text = """
      class X {
        deinit {}
        static func f() {}
        class func g() {}
      }
      X.f()
      X.g()
      """
    let tokens = try await openAndPerformSemanticTokensRequest(text: text)
    XCTAssertEqual(
      tokens.tokens,
      [
        // class X
        Token(line: 0, utf16index: 0, length: 5, kind: .keyword),
        Token(line: 0, utf16index: 6, length: 1, kind: .identifier),
        // deinit {}
        Token(line: 1, utf16index: 2, length: 6, kind: .keyword),
        // static func f() {}
        Token(line: 2, utf16index: 2, length: 6, kind: .keyword),
        Token(line: 2, utf16index: 9, length: 4, kind: .keyword),
        Token(line: 2, utf16index: 14, length: 1, kind: .identifier),
        // class func g() {}
        Token(line: 3, utf16index: 2, length: 5, kind: .keyword),
        Token(line: 3, utf16index: 8, length: 4, kind: .keyword),
        Token(line: 3, utf16index: 13, length: 1, kind: .identifier),
        // X.f()
        Token(line: 5, utf16index: 0, length: 1, kind: .class),
        Token(line: 5, utf16index: 2, length: 1, kind: .method, modifiers: [.static]),
        // X.g()
        Token(line: 6, utf16index: 0, length: 1, kind: .class),
        Token(line: 6, utf16index: 2, length: 1, kind: .method, modifiers: [.static]),
      ]
    )
  }

  func testSemanticTokensForEnumMembers() async throws {
    let text = """
      enum Maybe<T> {
        case none
        case some(T)
      }

      let x = Maybe<String>.none
      let y: Maybe = .some(42)
      """
    let tokens = try await openAndPerformSemanticTokensRequest(text: text)
    XCTAssertEqual(
      tokens.tokens,
      [
        // enum Maybe<T>
        Token(line: 0, utf16index: 0, length: 4, kind: .keyword),
        Token(line: 0, utf16index: 5, length: 5, kind: .identifier),
        Token(line: 0, utf16index: 11, length: 1, kind: .identifier),
        // case none
        Token(line: 1, utf16index: 2, length: 4, kind: .keyword),
        Token(line: 1, utf16index: 7, length: 4, kind: .identifier),
        // case some
        Token(line: 2, utf16index: 2, length: 4, kind: .keyword),
        Token(line: 2, utf16index: 7, length: 4, kind: .identifier),
        Token(line: 2, utf16index: 12, length: 1, kind: .typeParameter),
        // let x = Maybe<String>.none
        Token(line: 5, utf16index: 0, length: 3, kind: .keyword),
        Token(line: 5, utf16index: 4, length: 1, kind: .identifier),
        Token(line: 5, utf16index: 8, length: 5, kind: .enum),
        Token(line: 5, utf16index: 14, length: 6, kind: .struct, modifiers: .defaultLibrary),
        Token(line: 5, utf16index: 22, length: 4, kind: .enumMember),
        // let y: Maybe = .some(42)
        Token(line: 6, utf16index: 0, length: 3, kind: .keyword),
        Token(line: 6, utf16index: 4, length: 1, kind: .identifier),
        Token(line: 6, utf16index: 7, length: 5, kind: .enum),
        Token(line: 6, utf16index: 16, length: 4, kind: .enumMember),
        Token(line: 6, utf16index: 21, length: 2, kind: .number),
      ]
    )
  }

  func testRegexSemanticTokens() async throws {
    let text = """
      let r = /a[bc]*/
      """
    let tokens = try await openAndPerformSemanticTokensRequest(text: text)
    XCTAssertEqual(
      tokens.tokens,
      [
        Token(line: 0, utf16index: 0, length: 3, kind: .keyword),
        Token(line: 0, utf16index: 4, length: 1, kind: .identifier),
        Token(line: 0, utf16index: 8, length: 8, kind: .regexp),
      ]
    )
  }

  func testOperatorDeclaration() async throws {
    let text = """
      infix operator ?= :ComparisonPrecedence
      """
    let tokens = try await openAndPerformSemanticTokensRequest(text: text)
    XCTAssertEqual(
      tokens.tokens,
      [
        Token(line: 0, utf16index: 0, length: 5, kind: .keyword),
        Token(line: 0, utf16index: 6, length: 8, kind: .keyword),
        Token(line: 0, utf16index: 15, length: 2, kind: .operator),
        Token(line: 0, utf16index: 19, length: 20, kind: .identifier),
      ]
    )
  }

  func testEmptyEdit() async throws {
    let text = """
      let x: String = "test"
      var y = 123
      """
    openDocument(text: text)

    let before = try await performSemanticTokensRequest()

    let pos = Position(line: 0, utf16index: 1)
    editDocument(range: pos..<pos, text: "", expectRefresh: false)

    let after = try await performSemanticTokensRequest()
    XCTAssertEqual(before.tokens, after.tokens)
  }

  func testReplaceUntilMiddleOfToken() async throws {
    let text = """
      var test = 4567
      """
    openDocument(text: text)

    let before = try await performSemanticTokensRequest()
    let expectedLeading = [
      Token(line: 0, utf16index: 0, length: 3, kind: .keyword),
      Token(line: 0, utf16index: 4, length: 4, kind: .identifier),
    ]
    XCTAssertEqual(
      before.tokens,
      expectedLeading + [
        Token(line: 0, utf16index: 11, length: 4, kind: .number)
      ]
    )

    let start = Position(line: 0, utf16index: 10)
    let end = Position(line: 0, utf16index: 13)
    editDocument(range: start..<end, text: " 1")

    let after = try await performSemanticTokensRequest()
    XCTAssertEqual(
      after.tokens,
      expectedLeading + [
        Token(line: 0, utf16index: 11, length: 3, kind: .number)
      ]
    )
  }

  func testReplaceUntilEndOfToken() async throws {
    let text = """
      fatalError("xyz")
      """
    openDocument(text: text)

    let before = try await performSemanticTokensRequest()
    XCTAssertEqual(
      before.tokens,
      [
        Token(line: 0, utf16index: 0, length: 10, kind: .function, modifiers: .defaultLibrary),
        Token(line: 0, utf16index: 11, length: 5, kind: .string),
      ]
    )

    let start = Position(line: 0, utf16index: 10)
    let end = Position(line: 0, utf16index: 16)
    editDocument(range: start..<end, text: "(\"test\"")

    let after = try await performSemanticTokensRequest()
    XCTAssertEqual(
      after.tokens,
      [
        Token(line: 0, utf16index: 0, length: 10, kind: .function, modifiers: .defaultLibrary),
        Token(line: 0, utf16index: 11, length: 6, kind: .string),
      ]
    )
  }

  func testInsertSpaceBeforeToken() async throws {
    let text = """
      let x: String = "test"
      """
    openDocument(text: text)

    let expectedBefore = [
      SyntaxHighlightingToken(line: 0, utf16index: 0, length: 3, kind: .keyword),
      SyntaxHighlightingToken(line: 0, utf16index: 4, length: 1, kind: .identifier),
      SyntaxHighlightingToken(line: 0, utf16index: 7, length: 6, kind: .struct, modifiers: [.defaultLibrary]),
      SyntaxHighlightingToken(line: 0, utf16index: 16, length: 6, kind: .string),
    ]
    let before = try await performSemanticTokensRequest()
    XCTAssertEqual(before.tokens, expectedBefore)

    let pos = Position(line: 0, utf16index: 0)
    let editText = " "
    editDocument(range: pos..<pos, text: editText, expectRefresh: false)

    let after = try await performSemanticTokensRequest()
    let expectedAfter = [
      SyntaxHighlightingToken(line: 0, utf16index: 1, length: 3, kind: .keyword),
      SyntaxHighlightingToken(line: 0, utf16index: 5, length: 1, kind: .identifier),
      SyntaxHighlightingToken(line: 0, utf16index: 8, length: 6, kind: .struct, modifiers: [.defaultLibrary]),
      SyntaxHighlightingToken(line: 0, utf16index: 17, length: 6, kind: .string),
    ]
    XCTAssertEqual(after.tokens, expectedAfter)
  }

  func testInsertSpaceAfterToken() async throws {
    let text = """
      var x = 0
      """
    openDocument(text: text)

    let before = try await performSemanticTokensRequest()

    let pos = Position(line: 0, utf16index: 9)
    let editText = " "
    editDocument(range: pos..<pos, text: editText, expectRefresh: false)

    let after = try await performSemanticTokensRequest()
    XCTAssertEqual(before.tokens, after.tokens)
  }

  func testInsertNewline() async throws {
    let text = """
      fatalError("123")
      """
    openDocument(text: text)

    let expectedBefore = [
      SyntaxHighlightingToken(line: 0, utf16index: 0, length: 10, kind: .function, modifiers: [.defaultLibrary]),
      SyntaxHighlightingToken(line: 0, utf16index: 11, length: 5, kind: .string),
    ]
    let before = try await performSemanticTokensRequest()
    XCTAssertEqual(before.tokens, expectedBefore)

    let pos = Position(line: 0, utf16index: 0)
    editDocument(range: pos..<pos, text: "\n", expectRefresh: false)

    let after = try await performSemanticTokensRequest()
    let expectedAfter = [
      SyntaxHighlightingToken(line: 1, utf16index: 0, length: 10, kind: .function, modifiers: [.defaultLibrary]),
      SyntaxHighlightingToken(line: 1, utf16index: 11, length: 5, kind: .string),
    ]
    XCTAssertEqual(after.tokens, expectedAfter)
  }

  func testRemoveNewline() async throws {
    let text = """
      let x =
              "abc"
      """
    openDocument(text: text)

    let before = try await performSemanticTokensRequest()
    let expectedBefore = [
      Token(line: 0, utf16index: 0, length: 3, kind: .keyword),
      Token(line: 0, utf16index: 4, length: 1, kind: .identifier),
      Token(line: 1, utf16index: 8, length: 5, kind: .string),
    ]
    XCTAssertEqual(before.tokens, expectedBefore)

    let start = Position(line: 0, utf16index: 7)
    let end = Position(line: 1, utf16index: 7)
    editDocument(range: start..<end, text: "", expectRefresh: false)

    let after = try await performSemanticTokensRequest()
    let expectedAfter = [
      Token(line: 0, utf16index: 0, length: 3, kind: .keyword),
      Token(line: 0, utf16index: 4, length: 1, kind: .identifier),
      Token(line: 0, utf16index: 8, length: 5, kind: .string),
    ]
    XCTAssertEqual(after.tokens, expectedAfter)
  }

  func testInsertTokens() async throws {
    let text = """
      let x =
              "abc"
      """
    openDocument(text: text)

    let before = try await performSemanticTokensRequest()
    let expectedBefore = [
      Token(line: 0, utf16index: 0, length: 3, kind: .keyword),
      Token(line: 0, utf16index: 4, length: 1, kind: .identifier),
      Token(line: 1, utf16index: 8, length: 5, kind: .string),
    ]
    XCTAssertEqual(before.tokens, expectedBefore)

    let start = Position(line: 0, utf16index: 7)
    let end = Position(line: 1, utf16index: 7)
    editDocument(range: start..<end, text: " \"test\" +", expectRefresh: true)

    let after = try await performSemanticTokensRequest()
    let expectedAfter: [Token] = [
      Token(line: 0, utf16index: 0, length: 3, kind: .keyword),
      Token(line: 0, utf16index: 4, length: 1, kind: .identifier),
      Token(line: 0, utf16index: 8, length: 6, kind: .string),
      Token(line: 0, utf16index: 15, length: 1, kind: .method, modifiers: [.defaultLibrary, .static]),
      Token(line: 0, utf16index: 17, length: 5, kind: .string),
    ]
    XCTAssertEqual(after.tokens, expectedAfter)
  }

  func testSemanticMultiEdit() async throws {
    let text = """
      let x = "abc"
      let y = x
      """
    openDocument(text: text)

    let before = try await performSemanticTokensRequest()
    XCTAssertEqual(
      before.tokens,
      [
        Token(line: 0, utf16index: 0, length: 3, kind: .keyword),
        Token(line: 0, utf16index: 4, length: 1, kind: .identifier),
        Token(line: 0, utf16index: 8, length: 5, kind: .string),
        Token(line: 1, utf16index: 0, length: 3, kind: .keyword),
        Token(line: 1, utf16index: 4, length: 1, kind: .identifier),
        Token(line: 1, utf16index: 8, length: 1, kind: .variable),
      ]
    )

    let newName = "renamed"
    editDocument(
      changes: [
        TextDocumentContentChangeEvent(
          range: Position(line: 0, utf16index: 4)..<Position(line: 0, utf16index: 5),
          text: newName
        ),
        TextDocumentContentChangeEvent(
          range: Position(line: 1, utf16index: 8)..<Position(line: 1, utf16index: 9),
          text: newName
        ),
      ],
      expectRefresh: true
    )

    let after = try await performSemanticTokensRequest()
    XCTAssertEqual(
      after.tokens,
      [
        Token(line: 0, utf16index: 0, length: 3, kind: .keyword),
        Token(line: 0, utf16index: 4, length: 7, kind: .identifier),
        Token(line: 0, utf16index: 14, length: 5, kind: .string),
        Token(line: 1, utf16index: 0, length: 3, kind: .keyword),
        Token(line: 1, utf16index: 4, length: 1, kind: .identifier),
        Token(line: 1, utf16index: 8, length: 7, kind: .variable),
      ]
    )
  }

  func testActor() async throws {
    let text = """
      actor MyActor {}

      struct MyStruct {}

      func t(
          x: MyActor,
          y: MyStruct
      ) {}
      """

    let tokens = try await openAndPerformSemanticTokensRequest(text: text)
    XCTAssertEqual(
      tokens.tokens,
      [
        Token(line: 0, utf16index: 0, length: 5, kind: .keyword),
        Token(line: 0, utf16index: 6, length: 7, kind: .identifier),
        Token(line: 2, utf16index: 0, length: 6, kind: .keyword),
        Token(line: 2, utf16index: 7, length: 8, kind: .identifier),
        Token(line: 4, utf16index: 0, length: 4, kind: .keyword),
        Token(line: 4, utf16index: 5, length: 1, kind: .identifier),
        Token(line: 5, utf16index: 4, length: 1, kind: .function),
        Token(line: 5, utf16index: 7, length: 7, kind: .actor),
        Token(line: 6, utf16index: 4, length: 1, kind: .function),
        Token(line: 6, utf16index: 7, length: 8, kind: .struct),
      ]
    )
  }

  func testArgumentLabels() async throws {
    let text = """
      func foo(arg: Int) {}
      foo(arg: 1)
      """

    let tokens = try await openAndPerformSemanticTokensRequest(text: text)
    XCTAssertEqual(
      tokens.tokens,
      [
        Token(line: 0, utf16index: 0, length: 4, kind: .keyword),
        Token(line: 0, utf16index: 5, length: 3, kind: .identifier),
        Token(line: 0, utf16index: 9, length: 3, kind: .function),
        Token(line: 0, utf16index: 14, length: 3, kind: .struct, modifiers: .defaultLibrary),
        Token(line: 1, utf16index: 0, length: 3, kind: .function),
        Token(line: 1, utf16index: 4, length: 3, kind: .function),
        Token(line: 1, utf16index: 9, length: 1, kind: .number),
      ]
    )
  }

  func testFunctionDeclarationWithFirstAndSecondName() async throws {
    let text = """
      func foo(arg internalName: Int) {}
      """

    let tokens = try await openAndPerformSemanticTokensRequest(text: text)
    XCTAssertEqual(
      tokens.tokens,
      [
        Token(line: 0, utf16index: 0, length: 4, kind: .keyword),
        Token(line: 0, utf16index: 5, length: 3, kind: .identifier),
        Token(line: 0, utf16index: 9, length: 3, kind: .function),
        Token(line: 0, utf16index: 13, length: 12, kind: .identifier),
        Token(line: 0, utf16index: 27, length: 3, kind: .struct, modifiers: .defaultLibrary),
      ]
    )
  }
}

extension Token {
  fileprivate init(
    line: Int,
    utf16index: Int,
    length: Int,
    kind: SemanticTokenTypes,
    modifiers: SemanticTokenModifiers = []
  ) {
    self.init(
      start: Position(line: line, utf16index: utf16index),
      utf16length: length,
      kind: kind,
      modifiers: modifiers
    )
  }
}
