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
import SourceKitD
@_spi(Testing) import SourceKitLSP
import XCTest

private typealias Token = SyntaxHighlightingToken

final class SemanticTokensTests: XCTestCase {
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
    let snapshot = DocumentSnapshot(
      uri: DocumentURI(for: .swift),
      language: .swift,
      version: 0,
      lineTable: LineTable(
        """
        struct X {
          let x: Int
          let y: String


        }
        """
      )
    )

    let empty = Position(line: 0, utf16index: 1)..<Position(line: 0, utf16index: 1)
    XCTAssertEqual(empty.splitToSingleLineRanges(in: snapshot), [])

    let multiLine = Position(line: 1, utf16index: 6)..<Position(line: 2, utf16index: 7)
    XCTAssertEqual(
      multiLine.splitToSingleLineRanges(in: snapshot),
      [
        Position(line: 1, utf16index: 6)..<Position(line: 1, utf16index: 12),
        Position(line: 2, utf16index: 0)..<Position(line: 2, utf16index: 7),
      ]
    )

    let emptyLines = Position(line: 2, utf16index: 14)..<Position(line: 5, utf16index: 1)
    XCTAssertEqual(
      emptyLines.splitToSingleLineRanges(in: snapshot),
      [
        Position(line: 2, utf16index: 14)..<Position(line: 2, utf16index: 15),
        Position(line: 5, utf16index: 0)..<Position(line: 5, utf16index: 1),
      ]
    )
  }

  func testEmpty() async throws {
    try await assertSemanticTokens(
      markedContents: "",
      expected: []
    )
  }

  func testRanged() async throws {
    try await SkipUnless.sourcekitdHasSemanticTokensRequest()

    try await assertSemanticTokens(
      markedContents: """
        let x = 1
        1️⃣let 2️⃣test = 3️⃣20
        4️⃣let 5️⃣a6️⃣bc = 333
        let y = 4
        """,
      range: ("1️⃣", "6️⃣"),
      expected: [
        TokenSpec(marker: "1️⃣", length: 3, kind: .keyword),
        TokenSpec(marker: "2️⃣", length: 4, kind: .identifier),
        TokenSpec(marker: "3️⃣", length: 2, kind: .number),
        TokenSpec(marker: "4️⃣", length: 3, kind: .keyword),
        TokenSpec(marker: "5️⃣", length: 3, kind: .identifier),
      ]
    )
  }

  func testLexicalTokens() async throws {
    try await SkipUnless.sourcekitdHasSemanticTokensRequest()

    try await assertSemanticTokens(
      markedContents: """
        1️⃣let 2️⃣x = 3️⃣3
        4️⃣var 5️⃣y = 6️⃣"test"
        7️⃣/* abc */ 8️⃣// 123
        """,
      expected: [
        // let x = 3
        TokenSpec(marker: "1️⃣", length: 3, kind: .keyword),
        TokenSpec(marker: "2️⃣", length: 1, kind: .identifier),
        TokenSpec(marker: "3️⃣", length: 1, kind: .number),
        // var y = "test"
        TokenSpec(marker: "4️⃣", length: 3, kind: .keyword),
        TokenSpec(marker: "5️⃣", length: 1, kind: .identifier),
        TokenSpec(marker: "6️⃣", length: 6, kind: .string),
        // /* abc */ // 123
        TokenSpec(marker: "7️⃣", length: 9, kind: .comment),
        TokenSpec(marker: "8️⃣", length: 6, kind: .comment),
      ]
    )
  }

  func testLexicalTokensForMultiLineComments() async throws {
    try await SkipUnless.sourcekitdHasSemanticTokensRequest()

    try await assertSemanticTokens(
      markedContents: """
        1️⃣let 2️⃣x = 3️⃣3 4️⃣/*
        5️⃣let x = 12
        6️⃣*/
        """,
      expected: [
        TokenSpec(marker: "1️⃣", length: 3, kind: .keyword),
        TokenSpec(marker: "2️⃣", length: 1, kind: .identifier),
        TokenSpec(marker: "3️⃣", length: 1, kind: .number),
        // Multi-line comments are split into single-line tokens
        TokenSpec(marker: "4️⃣", length: 2, kind: .comment),
        TokenSpec(marker: "5️⃣", length: 10, kind: .comment),
        TokenSpec(marker: "6️⃣", length: 2, kind: .comment),
      ]
    )
  }

  func testLexicalTokensForDocComments() async throws {
    try await SkipUnless.sourcekitdHasSemanticTokensRequest()

    try await assertSemanticTokens(
      markedContents: """
        1️⃣/** abc */
          2️⃣/// def
        """,
      expected: [
        TokenSpec(marker: "1️⃣", length: 10, kind: .comment, modifiers: .documentation),
        TokenSpec(marker: "2️⃣", length: 7, kind: .comment, modifiers: .documentation),
      ]
    )
  }

  func testLexicalTokensForBackticks() async throws {
    try await SkipUnless.sourcekitdHasSemanticTokensRequest()

    try await assertSemanticTokens(
      markedContents: """
        1️⃣var 2️⃣`if` = 3️⃣20
        """,
      expected: [
        TokenSpec(marker: "1️⃣", length: 3, kind: .keyword),
        TokenSpec(marker: "2️⃣", length: 4, kind: .identifier),
        TokenSpec(marker: "3️⃣", length: 2, kind: .number),
      ]
    )

    try await assertSemanticTokens(
      markedContents: """
        1️⃣let 2️⃣`else` = 3️⃣3
        """,
      expected: [
        TokenSpec(marker: "1️⃣", length: 3, kind: .keyword),
        TokenSpec(marker: "2️⃣", length: 6, kind: .identifier),
        TokenSpec(marker: "3️⃣", length: 1, kind: .number),
      ]
    )

    try await assertSemanticTokens(
      markedContents: """
        1️⃣let `2️⃣onLeft = ()
        """,
      expected: [
        TokenSpec(marker: "1️⃣", length: 3, kind: .keyword),
        TokenSpec(marker: "2️⃣", length: 6, kind: .identifier),
      ]
    )

    try await assertSemanticTokens(
      markedContents: """
        1️⃣let 2️⃣onRight` = ()
        """,
      expected: [
        TokenSpec(marker: "1️⃣", length: 3, kind: .keyword),
        TokenSpec(marker: "2️⃣", length: 7, kind: .identifier),
      ]
    )
  }

  func testSemanticTokens() async throws {
    try await SkipUnless.sourcekitdHasSemanticTokensRequest()

    try await assertSemanticTokens(
      markedContents: """
        1️⃣struct 2️⃣X {}

        3️⃣let 4️⃣x = 5️⃣X()
        6️⃣let 7️⃣y = 8️⃣x 9️⃣+ 🔟x
        """,
      expected: [
        // struct X {}
        TokenSpec(marker: "1️⃣", length: 6, kind: .keyword),
        TokenSpec(marker: "2️⃣", length: 1, kind: .identifier),
        // let x = X()
        TokenSpec(marker: "3️⃣", length: 3, kind: .keyword),
        TokenSpec(marker: "4️⃣", length: 1, kind: .identifier),
        TokenSpec(marker: "5️⃣", length: 1, kind: .struct),
        // let y = x + x
        TokenSpec(marker: "6️⃣", length: 3, kind: .keyword),
        TokenSpec(marker: "7️⃣", length: 1, kind: .identifier),
        TokenSpec(marker: "8️⃣", length: 1, kind: .variable),
        TokenSpec(marker: "9️⃣", length: 1, kind: .operator),
        TokenSpec(marker: "🔟", length: 1, kind: .variable),
      ]
    )

    try await assertSemanticTokens(
      markedContents: """
        1️⃣func 2️⃣a() {}
        3️⃣let 4️⃣b = {}

        5️⃣a()
        6️⃣b()
        """,
      expected: [
        // func a() {}
        TokenSpec(marker: "1️⃣", length: 4, kind: .keyword),
        TokenSpec(marker: "2️⃣", length: 1, kind: .identifier),
        // let b = {}
        TokenSpec(marker: "3️⃣", length: 3, kind: .keyword),
        TokenSpec(marker: "4️⃣", length: 1, kind: .identifier),
        // a()
        TokenSpec(marker: "5️⃣", length: 1, kind: .function),
        // b()
        TokenSpec(marker: "6️⃣", length: 1, kind: .variable),
      ]
    )
  }

  func testSemanticTokensForProtocols() async throws {
    try await SkipUnless.sourcekitdHasSemanticTokensRequest()

    try await assertSemanticTokens(
      markedContents: """
        1️⃣protocol 2️⃣X {}
        3️⃣class 4️⃣Y: 5️⃣X {}

        6️⃣let 7️⃣y: 8️⃣Y = 9️⃣X()
        """,
      expected: [
        // protocol X {}
        TokenSpec(marker: "1️⃣", length: 8, kind: .keyword),
        TokenSpec(marker: "2️⃣", length: 1, kind: .identifier),
        // class Y: X {}
        TokenSpec(marker: "3️⃣", length: 5, kind: .keyword),
        TokenSpec(marker: "4️⃣", length: 1, kind: .identifier),
        TokenSpec(marker: "5️⃣", length: 1, kind: .interface),
        // let y: Y = X()
        TokenSpec(marker: "6️⃣", length: 3, kind: .keyword),
        TokenSpec(marker: "7️⃣", length: 1, kind: .identifier),
        TokenSpec(marker: "8️⃣", length: 1, kind: .class),
        TokenSpec(marker: "9️⃣", length: 1, kind: .interface),
      ]
    )

    try await assertSemanticTokens(
      markedContents: """
        1️⃣protocol 2️⃣X {}

        3️⃣func 4️⃣f<5️⃣T: 6️⃣X>() {}
        """,
      expected: [
        // protocol X {}
        TokenSpec(marker: "1️⃣", length: 8, kind: .keyword),
        TokenSpec(marker: "2️⃣", length: 1, kind: .identifier),
        // func f<T: X>() {}
        TokenSpec(marker: "3️⃣", length: 4, kind: .keyword),
        TokenSpec(marker: "4️⃣", length: 1, kind: .identifier),
        TokenSpec(marker: "5️⃣", length: 1, kind: .identifier),
        TokenSpec(marker: "6️⃣", length: 1, kind: .interface),
      ]
    )
  }

  func testSemanticTokensForFunctionSignatures() async throws {
    try await SkipUnless.sourcekitdHasSemanticTokensRequest()

    try await assertSemanticTokens(
      markedContents: "1️⃣func 2️⃣f(3️⃣x: 4️⃣Int, _ 5️⃣y: 6️⃣String) {}",
      expected: [
        TokenSpec(marker: "1️⃣", length: 4, kind: .keyword),
        TokenSpec(marker: "2️⃣", length: 1, kind: .identifier),
        TokenSpec(marker: "3️⃣", length: 1, kind: .function, modifiers: .argumentLabel),
        TokenSpec(marker: "4️⃣", length: 3, kind: .struct, modifiers: .defaultLibrary),
        TokenSpec(marker: "5️⃣", length: 1, kind: .identifier),
        TokenSpec(marker: "6️⃣", length: 6, kind: .struct, modifiers: .defaultLibrary),
      ]
    )
  }

  func testSemanticTokensForFunctionSignaturesWithEmoji() async throws {
    try await SkipUnless.sourcekitdHasSemanticTokensRequest()

    try await assertSemanticTokens(
      markedContents: "1️⃣func 2️⃣x👍y() {}",
      expected: [
        TokenSpec(marker: "1️⃣", length: 4, kind: .keyword),
        TokenSpec(marker: "2️⃣", length: 4, kind: .identifier),
      ]
    )
  }

  func testSemanticTokensForStaticMethods() async throws {
    try await SkipUnless.sourcekitdHasSemanticTokensRequest()

    try await assertSemanticTokens(
      markedContents: """
        1️⃣class 2️⃣X {
          3️⃣static 4️⃣func 5️⃣f() {}
        }
        6️⃣X.7️⃣f()
        """,
      expected: [
        // class X
        TokenSpec(marker: "1️⃣", length: 5, kind: .keyword),
        TokenSpec(marker: "2️⃣", length: 1, kind: .identifier),
        // static func f() {}
        TokenSpec(marker: "3️⃣", length: 6, kind: .keyword),
        TokenSpec(marker: "4️⃣", length: 4, kind: .keyword),
        TokenSpec(marker: "5️⃣", length: 1, kind: .identifier),
        // X.f()
        TokenSpec(marker: "6️⃣", length: 1, kind: .class),
        TokenSpec(marker: "7️⃣", length: 1, kind: .method, modifiers: .static),
      ]
    )

    try await assertSemanticTokens(
      markedContents: """
        1️⃣class 2️⃣X {
          3️⃣class 4️⃣func 5️⃣g() {}
        }
        6️⃣X.7️⃣g()
        """,
      expected: [
        // class X
        TokenSpec(marker: "1️⃣", length: 5, kind: .keyword),
        TokenSpec(marker: "2️⃣", length: 1, kind: .identifier),
        // class func g() {}
        TokenSpec(marker: "3️⃣", length: 5, kind: .keyword),
        TokenSpec(marker: "4️⃣", length: 4, kind: .keyword),
        TokenSpec(marker: "5️⃣", length: 1, kind: .identifier),
        // X.f()
        TokenSpec(marker: "6️⃣", length: 1, kind: .class),
        TokenSpec(marker: "7️⃣", length: 1, kind: .method, modifiers: .static),
      ]
    )
  }

  func testSemanticTokensForEnumMembers() async throws {
    try await SkipUnless.sourcekitdHasSemanticTokensRequest()

    try await assertSemanticTokens(
      markedContents: """
        1️⃣enum 2️⃣Maybe<3️⃣T> {
          4️⃣case 5️⃣none
        }

        6️⃣let 7️⃣x = 8️⃣Maybe<9️⃣String>.🔟none
        """,
      expected: [
        // enum Maybe<T>
        TokenSpec(marker: "1️⃣", length: 4, kind: .keyword),
        TokenSpec(marker: "2️⃣", length: 5, kind: .identifier),
        TokenSpec(marker: "3️⃣", length: 1, kind: .identifier),
        // case none
        TokenSpec(marker: "4️⃣", length: 4, kind: .keyword),
        TokenSpec(marker: "5️⃣", length: 4, kind: .identifier),
        // let x = Maybe<String>.none
        TokenSpec(marker: "6️⃣", length: 3, kind: .keyword),
        TokenSpec(marker: "7️⃣", length: 1, kind: .identifier),
        TokenSpec(marker: "8️⃣", length: 5, kind: .enum),
        TokenSpec(marker: "9️⃣", length: 6, kind: .struct, modifiers: .defaultLibrary),
        TokenSpec(marker: "🔟", length: 4, kind: .enumMember),
      ]
    )

    try await assertSemanticTokens(
      markedContents: """
        1️⃣enum 2️⃣Maybe<3️⃣T> {
          4️⃣case 5️⃣some(6️⃣T)
        }

        7️⃣let 8️⃣y: 9️⃣Maybe = .🔟some(0️⃣42)
        """,
      expected: [
        // enum Maybe<T>
        TokenSpec(marker: "1️⃣", length: 4, kind: .keyword),
        TokenSpec(marker: "2️⃣", length: 5, kind: .identifier),
        TokenSpec(marker: "3️⃣", length: 1, kind: .identifier),
        // case some
        TokenSpec(marker: "4️⃣", length: 4, kind: .keyword),
        TokenSpec(marker: "5️⃣", length: 4, kind: .identifier),
        TokenSpec(marker: "6️⃣", length: 1, kind: .typeParameter),
        // let y: Maybe = .some(42)
        TokenSpec(marker: "7️⃣", length: 3, kind: .keyword),
        TokenSpec(marker: "8️⃣", length: 1, kind: .identifier),
        TokenSpec(marker: "9️⃣", length: 5, kind: .enum),
        TokenSpec(marker: "🔟", length: 4, kind: .enumMember),
        TokenSpec(marker: "0️⃣", length: 2, kind: .number),
      ]
    )
  }

  func testRegexSemanticTokens() async throws {
    try await SkipUnless.sourcekitdHasSemanticTokensRequest()

    try await assertSemanticTokens(
      markedContents: """
        1️⃣let 2️⃣r = 3️⃣/a[bc]*/
        """,
      expected: [
        TokenSpec(marker: "1️⃣", length: 3, kind: .keyword),
        TokenSpec(marker: "2️⃣", length: 1, kind: .identifier),
        TokenSpec(marker: "3️⃣", length: 8, kind: .regexp),
      ]
    )
  }

  func testOperatorDeclaration() async throws {
    try await SkipUnless.sourcekitdHasSemanticTokensRequest()

    try await assertSemanticTokens(
      markedContents: """
        1️⃣infix 2️⃣operator 3️⃣?= :4️⃣ComparisonPrecedence
        """,
      expected: [
        TokenSpec(marker: "1️⃣", length: 5, kind: .keyword),
        TokenSpec(marker: "2️⃣", length: 8, kind: .keyword),
        TokenSpec(marker: "3️⃣", length: 2, kind: .operator),
        TokenSpec(marker: "4️⃣", length: 20, kind: .identifier),
      ]
    )
  }

  func testEmptyEdit() async throws {
    try await SkipUnless.sourcekitdHasSemanticTokensRequest()

    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)
    let positions = testClient.openDocument(
      """
      1️⃣l0️⃣et 2️⃣x: 3️⃣String = 4️⃣"test"
      5️⃣var 6️⃣y = 7️⃣123
      """,
      uri: uri
    )

    let expectedTokens = [
      TokenSpec(marker: "1️⃣", length: 3, kind: .keyword),
      TokenSpec(marker: "2️⃣", length: 1, kind: .identifier),
      TokenSpec(marker: "3️⃣", length: 6, kind: .struct, modifiers: .defaultLibrary),
      TokenSpec(marker: "4️⃣", length: 6, kind: .string),
      TokenSpec(marker: "5️⃣", length: 3, kind: .keyword),
      TokenSpec(marker: "6️⃣", length: 1, kind: .identifier),
      TokenSpec(marker: "7️⃣", length: 3, kind: .number),
    ]

    try await assertSemanticTokens(uri: uri, in: testClient, positions: positions, expected: expectedTokens)

    testClient.send(
      DidChangeTextDocumentNotification(
        textDocument: VersionedTextDocumentIdentifier(uri, version: 2),
        contentChanges: [TextDocumentContentChangeEvent(range: Range(positions["0️⃣"]), text: "")]
      )
    )

    try await assertSemanticTokens(uri: uri, in: testClient, positions: positions, expected: expectedTokens)
  }

  func testReplaceUntilMiddleOfToken() async throws {
    try await SkipUnless.sourcekitdHasSemanticTokensRequest()

    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)
    let positions = testClient.openDocument(
      """
      1️⃣var 2️⃣test = 3️⃣454️⃣67
      """,
      uri: uri
    )

    try await assertSemanticTokens(
      uri: uri,
      in: testClient,
      positions: positions,
      expected: [
        TokenSpec(marker: "1️⃣", length: 3, kind: .keyword),
        TokenSpec(marker: "2️⃣", length: 4, kind: .identifier),
        TokenSpec(marker: "3️⃣", length: 4, kind: .number),
      ]
    )

    testClient.send(
      DidChangeTextDocumentNotification(
        textDocument: VersionedTextDocumentIdentifier(uri, version: 2),
        contentChanges: [TextDocumentContentChangeEvent(range: positions["3️⃣"]..<positions["4️⃣"], text: " 1")]
      )
    )

    let positionsAfterEdits = DocumentPositions(
      markedText: """
        1️⃣var 2️⃣test =  3️⃣167
        """
    )

    try await assertSemanticTokens(
      uri: uri,
      in: testClient,
      positions: positionsAfterEdits,
      expected: [
        TokenSpec(marker: "1️⃣", length: 3, kind: .keyword),
        TokenSpec(marker: "2️⃣", length: 4, kind: .identifier),
        TokenSpec(marker: "3️⃣", length: 3, kind: .number),
      ]
    )
  }

  func testReplaceUntilEndOfToken() async throws {
    try await SkipUnless.sourcekitdHasSemanticTokensRequest()

    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)
    let positions = testClient.openDocument(
      """
      1️⃣fatalError2️⃣(3️⃣"xyz"4️⃣)
      """,
      uri: uri
    )

    try await assertSemanticTokens(
      uri: uri,
      in: testClient,
      positions: positions,
      expected: [
        TokenSpec(marker: "1️⃣", length: 10, kind: .function, modifiers: .defaultLibrary),
        TokenSpec(marker: "3️⃣", length: 5, kind: .string),
      ]
    )

    testClient.send(
      DidChangeTextDocumentNotification(
        textDocument: VersionedTextDocumentIdentifier(uri, version: 2),
        contentChanges: [
          TextDocumentContentChangeEvent(
            range: positions["2️⃣"]..<positions["4️⃣"],
            text: """
              ("test"
              """
          )
        ]
      )
    )

    let positionsAfterEdits = DocumentPositions(
      markedText: """
        1️⃣fatalError2️⃣(3️⃣"test"4️⃣)
        """
    )

    try await assertSemanticTokens(
      uri: uri,
      in: testClient,
      positions: positionsAfterEdits,
      expected: [
        TokenSpec(marker: "1️⃣", length: 10, kind: .function, modifiers: .defaultLibrary),
        TokenSpec(marker: "3️⃣", length: 6, kind: .string),
      ]
    )
  }

  func testInsertSpaceBeforeToken() async throws {
    try await SkipUnless.sourcekitdHasSemanticTokensRequest()

    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)
    let positions = testClient.openDocument(
      """
      1️⃣let 2️⃣x: 3️⃣String = 4️⃣"test"
      """,
      uri: uri
    )

    let expectedTokens = [
      TokenSpec(marker: "1️⃣", length: 3, kind: .keyword),
      TokenSpec(marker: "2️⃣", length: 1, kind: .identifier),
      TokenSpec(marker: "3️⃣", length: 6, kind: .struct, modifiers: .defaultLibrary),
      TokenSpec(marker: "4️⃣", length: 6, kind: .string),
    ]

    try await assertSemanticTokens(uri: uri, in: testClient, positions: positions, expected: expectedTokens)

    testClient.send(
      DidChangeTextDocumentNotification(
        textDocument: VersionedTextDocumentIdentifier(uri, version: 2),
        contentChanges: [TextDocumentContentChangeEvent(range: Range(positions["1️⃣"]), text: " ")]
      )
    )

    let positionsAfterEdits = DocumentPositions(
      markedText: """
         1️⃣let 2️⃣x: 3️⃣String = 4️⃣"test"
        """
    )

    try await assertSemanticTokens(uri: uri, in: testClient, positions: positionsAfterEdits, expected: expectedTokens)
  }

  func testInsertSpaceAfterToken() async throws {
    try await SkipUnless.sourcekitdHasSemanticTokensRequest()

    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)
    let positions = testClient.openDocument(
      """
      1️⃣var 2️⃣x = 3️⃣04️⃣
      """,
      uri: uri
    )

    let expectedTokens = [
      TokenSpec(marker: "1️⃣", length: 3, kind: .keyword),
      TokenSpec(marker: "2️⃣", length: 1, kind: .identifier),
      TokenSpec(marker: "3️⃣", length: 1, kind: .number),
    ]

    try await assertSemanticTokens(uri: uri, in: testClient, positions: positions, expected: expectedTokens)

    testClient.send(
      DidChangeTextDocumentNotification(
        textDocument: VersionedTextDocumentIdentifier(uri, version: 2),
        contentChanges: [TextDocumentContentChangeEvent(range: Range(positions["4️⃣"]), text: " ")]
      )
    )

    try await assertSemanticTokens(uri: uri, in: testClient, positions: positions, expected: expectedTokens)
  }

  func testInsertNewline() async throws {
    try await SkipUnless.sourcekitdHasSemanticTokensRequest()

    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)
    let positions = testClient.openDocument(
      """
      1️⃣fatalError(2️⃣"123")
      """,
      uri: uri
    )

    let expectedTokens = [
      TokenSpec(marker: "1️⃣", length: 10, kind: .function, modifiers: .defaultLibrary),
      TokenSpec(marker: "2️⃣", length: 5, kind: .string),
    ]

    try await assertSemanticTokens(uri: uri, in: testClient, positions: positions, expected: expectedTokens)

    testClient.send(
      DidChangeTextDocumentNotification(
        textDocument: VersionedTextDocumentIdentifier(uri, version: 2),
        contentChanges: [TextDocumentContentChangeEvent(range: Range(positions["1️⃣"]), text: "\n")]
      )
    )

    let positionsAfterEdit = DocumentPositions(
      markedText: """

        1️⃣fatalError(2️⃣"123")
        """
    )

    try await assertSemanticTokens(uri: uri, in: testClient, positions: positionsAfterEdit, expected: expectedTokens)
  }

  func testRemoveNewline() async throws {
    try await SkipUnless.sourcekitdHasSemanticTokensRequest()

    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)
    let positions = testClient.openDocument(
      """
      1️⃣let 2️⃣x =3️⃣
              4️⃣"abc"
      """,
      uri: uri
    )

    let expectedTokens = [
      TokenSpec(marker: "1️⃣", length: 3, kind: .keyword),
      TokenSpec(marker: "2️⃣", length: 1, kind: .identifier),
      TokenSpec(marker: "4️⃣", length: 5, kind: .string),
    ]

    try await assertSemanticTokens(uri: uri, in: testClient, positions: positions, expected: expectedTokens)

    testClient.send(
      DidChangeTextDocumentNotification(
        textDocument: VersionedTextDocumentIdentifier(uri, version: 2),
        contentChanges: [TextDocumentContentChangeEvent(range: positions["3️⃣"]..<positions["4️⃣"], text: " ")]
      )
    )

    let positionsAfterEdit = DocumentPositions(
      markedText: """
        1️⃣let 2️⃣x = 4️⃣"abc"
        """
    )

    try await assertSemanticTokens(uri: uri, in: testClient, positions: positionsAfterEdit, expected: expectedTokens)
  }

  func testInsertTokens() async throws {
    try await SkipUnless.sourcekitdHasSemanticTokensRequest()

    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)
    let positions = testClient.openDocument(
      """
      1️⃣let 2️⃣x =3️⃣
              4️⃣"abc"
      """,
      uri: uri
    )

    try await assertSemanticTokens(
      uri: uri,
      in: testClient,
      positions: positions,
      expected: [
        TokenSpec(marker: "1️⃣", length: 3, kind: .keyword),
        TokenSpec(marker: "2️⃣", length: 1, kind: .identifier),
        TokenSpec(marker: "4️⃣", length: 5, kind: .string),
      ]
    )

    testClient.send(
      DidChangeTextDocumentNotification(
        textDocument: VersionedTextDocumentIdentifier(uri, version: 2),
        contentChanges: [TextDocumentContentChangeEvent(range: positions["3️⃣"]..<positions["4️⃣"], text: #" "test" + "#)]
      )
    )

    let positionsAfterEdits = DocumentPositions(
      markedText: """
        1️⃣let 2️⃣x = 3️⃣"test" 4️⃣+ 5️⃣"abc"
        """
    )

    try await assertSemanticTokens(
      uri: uri,
      in: testClient,
      positions: positionsAfterEdits,
      expected: [
        TokenSpec(marker: "1️⃣", length: 3, kind: .keyword),
        TokenSpec(marker: "2️⃣", length: 1, kind: .identifier),
        TokenSpec(marker: "3️⃣", length: 6, kind: .string),
        TokenSpec(marker: "4️⃣", length: 1, kind: .method, modifiers: [.defaultLibrary, .static]),
        TokenSpec(marker: "5️⃣", length: 5, kind: .string),
      ]
    )
  }

  func testSemanticMultiEdit() async throws {
    try await SkipUnless.sourcekitdHasSemanticTokensRequest()

    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)
    let positions = testClient.openDocument(
      """
      1️⃣let 2️⃣x3️⃣ = 4️⃣"abc"
      5️⃣let 6️⃣y = 7️⃣x8️⃣
      """,
      uri: uri
    )

    try await assertSemanticTokens(
      uri: uri,
      in: testClient,
      positions: positions,
      expected: [
        TokenSpec(marker: "1️⃣", length: 3, kind: .keyword),
        TokenSpec(marker: "2️⃣", length: 1, kind: .identifier),
        TokenSpec(marker: "4️⃣", length: 5, kind: .string),
        TokenSpec(marker: "5️⃣", length: 3, kind: .keyword),
        TokenSpec(marker: "6️⃣", length: 1, kind: .identifier),
        TokenSpec(marker: "7️⃣", length: 1, kind: .variable),
      ]
    )

    let newName = "renamed"
    testClient.send(
      DidChangeTextDocumentNotification(
        textDocument: VersionedTextDocumentIdentifier(uri, version: 2),
        contentChanges: [
          TextDocumentContentChangeEvent(range: positions["2️⃣"]..<positions["3️⃣"], text: newName),
          TextDocumentContentChangeEvent(range: positions["7️⃣"]..<positions["8️⃣"], text: newName),
        ]
      )
    )

    let positionsAfterEdits = DocumentPositions(
      markedText: """
        1️⃣let 2️⃣renamed = 4️⃣"abc"
        5️⃣let 6️⃣y = 7️⃣renamed
        """
    )

    try await assertSemanticTokens(
      uri: uri,
      in: testClient,
      positions: positionsAfterEdits,
      expected: [
        TokenSpec(marker: "1️⃣", length: 3, kind: .keyword),
        TokenSpec(marker: "2️⃣", length: 7, kind: .identifier),
        TokenSpec(marker: "4️⃣", length: 5, kind: .string),
        TokenSpec(marker: "5️⃣", length: 3, kind: .keyword),
        TokenSpec(marker: "6️⃣", length: 1, kind: .identifier),
        TokenSpec(marker: "7️⃣", length: 7, kind: .variable),
      ]
    )
  }

  func testActor() async throws {
    try await SkipUnless.sourcekitdHasSemanticTokensRequest()

    try await assertSemanticTokens(
      markedContents: """
        1️⃣actor 2️⃣MyActor {}

        3️⃣func 4️⃣t(5️⃣x: 6️⃣MyActor) {}
        """,
      expected: [
        TokenSpec(marker: "1️⃣", length: 5, kind: .keyword),
        TokenSpec(marker: "2️⃣", length: 7, kind: .identifier),
        TokenSpec(marker: "3️⃣", length: 4, kind: .keyword),
        TokenSpec(marker: "4️⃣", length: 1, kind: .identifier),
        TokenSpec(marker: "5️⃣", length: 1, kind: .function),
        TokenSpec(marker: "6️⃣", length: 7, kind: .actor),
      ]
    )
  }

  func testArgumentLabels() async throws {
    try await SkipUnless.sourcekitdHasSemanticTokensRequest()

    try await assertSemanticTokens(
      markedContents: """
        1️⃣func 2️⃣foo(3️⃣arg: 4️⃣Int) {}
        5️⃣foo(6️⃣arg: 7️⃣1)
        """,
      expected: [
        TokenSpec(marker: "1️⃣", length: 4, kind: .keyword),
        TokenSpec(marker: "2️⃣", length: 3, kind: .identifier),
        TokenSpec(marker: "3️⃣", length: 3, kind: .function, modifiers: .argumentLabel),
        TokenSpec(marker: "4️⃣", length: 3, kind: .struct, modifiers: .defaultLibrary),
        TokenSpec(marker: "5️⃣", length: 3, kind: .function),
        TokenSpec(marker: "6️⃣", length: 3, kind: .function),
        TokenSpec(marker: "7️⃣", length: 1, kind: .number),
      ]
    )
  }

  func testFunctionDeclarationWithFirstAndSecondName() async throws {
    try await SkipUnless.sourcekitdHasSemanticTokensRequest()

    try await assertSemanticTokens(
      markedContents: """
        1️⃣func 2️⃣foo(3️⃣arg 4️⃣internalName: 5️⃣Int) {}
        """,
      expected: [
        TokenSpec(marker: "1️⃣", length: 4, kind: .keyword),
        TokenSpec(marker: "2️⃣", length: 3, kind: .identifier),
        TokenSpec(marker: "3️⃣", length: 3, kind: .function),
        TokenSpec(marker: "4️⃣", length: 12, kind: .identifier),
        TokenSpec(marker: "5️⃣", length: 3, kind: .struct, modifiers: .defaultLibrary),
      ]
    )
  }

  func testClang() async throws {
    try await SkipUnless.sourcekitdHasSemanticTokensRequest()

    try await assertSemanticTokens(
      markedContents: """
        int 1️⃣main() {}
        """,
      language: .c,
      expected: [
        TokenSpec(marker: "1️⃣", length: 4, kind: .function, modifiers: [.declaration, .definition, .globalScope])
      ]
    )
  }
}

fileprivate struct TokenSpec {
  let marker: String
  let length: Int
  let kind: SemanticTokenTypes
  let modifiers: SemanticTokenModifiers

  init(
    marker: String,
    length: Int,
    kind: SemanticTokenTypes,
    modifiers: SemanticTokenModifiers = []
  ) {
    self.marker = marker
    self.length = length
    self.kind = kind
    self.modifiers = modifiers
  }
}

fileprivate func assertSemanticTokens(
  markedContents: String,
  language: Language = .swift,
  range: (startMarker: String, endMarker: String)? = nil,
  expected: [TokenSpec],
  file: StaticString = #filePath,
  line: UInt = #line
) async throws {
  let testClient = try await TestSourceKitLSPClient()
  let uri = DocumentURI(for: language)
  let positions = testClient.openDocument(markedContents, uri: uri)

  let response: DocumentSemanticTokensResponse?
  if let range {
    response = try await testClient.send(
      DocumentSemanticTokensRangeRequest(
        textDocument: TextDocumentIdentifier(uri),
        range: positions[range.startMarker]..<positions[range.endMarker]
      )
    )
  } else {
    response = try await testClient.send(DocumentSemanticTokensRequest(textDocument: TextDocumentIdentifier(uri)))
  }

  let expectedTokens = expected.map {
    Token(start: positions[$0.marker], utf16length: $0.length, kind: $0.kind, modifiers: $0.modifiers)
  }
  XCTAssertEqual(
    SyntaxHighlightingTokens(lspEncodedTokens: try unwrap(response, file: file, line: line).data).tokens,
    expectedTokens,
    file: file,
    line: line
  )
}

fileprivate func assertSemanticTokens(
  uri: DocumentURI,
  in testClient: TestSourceKitLSPClient,
  positions: DocumentPositions,
  expected: [TokenSpec],
  file: StaticString = #filePath,
  line: UInt = #line
) async throws {
  let response = try await unwrap(
    testClient.send(DocumentSemanticTokensRequest(textDocument: TextDocumentIdentifier(uri))),
    file: file,
    line: line
  )
  let expectedTokens = expected.map {
    Token(start: positions[$0.marker], utf16length: $0.length, kind: $0.kind, modifiers: $0.modifiers)
  }
  XCTAssertEqual(
    SyntaxHighlightingTokens(lspEncodedTokens: response.data).tokens,
    expectedTokens,
    file: file,
    line: line
  )
}
