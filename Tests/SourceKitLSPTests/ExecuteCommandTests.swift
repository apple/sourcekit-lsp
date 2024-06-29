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
import SourceKitLSP
import XCTest

final class ExecuteCommandTests: XCTestCase {
  func testLocationSemanticRefactoring() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)

    let positions = testClient.openDocument(
      """
      func foo() {
        1️⃣"hello2️⃣"3️⃣
      }
      """,
      uri: uri
    )

    let args = SemanticRefactorCommand(
      title: "Localize String",
      actionString: "source.refactoring.kind.localize.string",
      positionRange: Range(positions["2️⃣"]),
      textDocument: TextDocumentIdentifier(uri)
    )

    let metadata = SourceKitLSPCommandMetadata(textDocument: TextDocumentIdentifier(uri))

    var command = try args.asCommand()
    command.arguments?.append(metadata.encodeToLSPAny())

    let request = ExecuteCommandRequest(command: command.command, arguments: command.arguments)

    testClient.handleSingleRequest { (req: ApplyEditRequest) -> ApplyEditResponse in
      return ApplyEditResponse(applied: true, failureReason: nil)
    }

    let result = try await testClient.send(request)

    guard case .dictionary(let resultDict) = result else {
      XCTFail("Result is not a dictionary.")
      return
    }

    XCTAssertEqual(
      WorkspaceEdit(fromLSPDictionary: resultDict),
      WorkspaceEdit(changes: [
        uri: [
          TextEdit(
            range: Range(positions["1️⃣"]),
            newText: "NSLocalizedString("
          ),
          TextEdit(
            range: Range(positions["3️⃣"]),
            newText: ", comment: \"\")"
          ),
        ]
      ])
    )
  }

  func testRangeSemanticRefactoring() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)

    let positions = testClient.openDocument(
      """
      func foo() -> String {
        1️⃣var a = "hello"
        return a2️⃣
      }
      """,
      uri: uri
    )

    let args = SemanticRefactorCommand(
      title: "Extract Method",
      actionString: "source.refactoring.kind.extract.function",
      positionRange: positions["1️⃣"]..<positions["2️⃣"],
      textDocument: TextDocumentIdentifier(uri)
    )

    let metadata = SourceKitLSPCommandMetadata(textDocument: TextDocumentIdentifier(uri))

    var command = try args.asCommand()
    command.arguments?.append(metadata.encodeToLSPAny())

    let request = ExecuteCommandRequest(command: command.command, arguments: command.arguments)

    testClient.handleSingleRequest { (req: ApplyEditRequest) -> ApplyEditResponse in
      return ApplyEditResponse(applied: true, failureReason: nil)
    }

    let result = try await testClient.send(request)

    guard case .dictionary(let resultDict) = result else {
      XCTFail("Result is not a dictionary.")
      return
    }

    XCTAssertEqual(
      WorkspaceEdit(fromLSPDictionary: resultDict),
      WorkspaceEdit(changes: [
        uri: [
          TextEdit(
            range: Range(Position(line: 0, utf16index: 0)),
            newText:
              """
              fileprivate func extractedFunc() -> String {
              var a = "hello"
                return a
              }


              """
          ),
          TextEdit(
            range: positions["1️⃣"]..<positions["2️⃣"],
            newText: "return extractedFunc()"
          ),
        ]
      ])
    )
  }

  func testLSPCommandMetadataRetrieval() {
    var req = ExecuteCommandRequest(command: "", arguments: nil)
    XCTAssertNil(req.metadata)
    req.arguments = [1, 2, ""]
    XCTAssertNil(req.metadata)
    let url = URL(fileURLWithPath: "/a.swift")
    let textDocument = TextDocumentIdentifier(url)
    let metadata = SourceKitLSPCommandMetadata(textDocument: textDocument)
    req.arguments = [metadata.encodeToLSPAny(), 1, 2, ""]
    XCTAssertNil(req.metadata)
    req.arguments = [1, 2, "", [metadata.encodeToLSPAny()]]
    XCTAssertNil(req.metadata)
    req.arguments = [1, 2, "", metadata.encodeToLSPAny()]
    XCTAssertEqual(req.metadata, metadata)
    req.arguments = [metadata.encodeToLSPAny()]
    XCTAssertEqual(req.metadata, metadata)
  }

  func testLSPCommandMetadataRemoval() {
    var req = ExecuteCommandRequest(command: "", arguments: nil)
    XCTAssertNil(req.argumentsWithoutSourceKitMetadata)
    req.arguments = [1, 2, ""]
    XCTAssertEqual(req.arguments, req.argumentsWithoutSourceKitMetadata)
    let url = URL(fileURLWithPath: "/a.swift")
    let textDocument = TextDocumentIdentifier(url)
    let metadata = SourceKitLSPCommandMetadata(textDocument: textDocument)
    req.arguments = [metadata.encodeToLSPAny(), 1, 2, ""]
    XCTAssertEqual(req.arguments, req.argumentsWithoutSourceKitMetadata)
    req.arguments = [1, 2, "", [metadata.encodeToLSPAny()]]
    XCTAssertEqual(req.arguments, req.argumentsWithoutSourceKitMetadata)
    req.arguments = [1, 2, "", metadata.encodeToLSPAny()]
    XCTAssertEqual([1, 2, ""], req.argumentsWithoutSourceKitMetadata)
  }
}
