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
@_spi(Testing) import SourceKitLSP
import SwiftExtensions
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

    var command = args.asCommand()
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

    var command = args.asCommand()
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

  func testFreestandingMacroExpansion() async throws {
    try await SkipUnless.canBuildMacroUsingSwiftSyntaxFromSourceKitLSPBuild()

    let options = SourceKitLSPOptions.testDefault(experimentalFeatures: [.showMacroExpansions])

    let project = try await SwiftPMTestProject(
      files: [
        "MyMacros/MyMacros.swift": #"""
        import SwiftCompilerPlugin
        import SwiftSyntax
        import SwiftSyntaxBuilder
        import SwiftSyntaxMacros

        public struct StringifyMacro: ExpressionMacro {
          public static func expansion(
            of node: some FreestandingMacroExpansionSyntax,
            in context: some MacroExpansionContext
          ) -> ExprSyntax {
            guard let argument = node.argumentList.first?.expression else {
              fatalError("compiler bug: the macro does not have any arguments")
            }

            return "(\(argument), \(literal: argument.description))"
          }
        }

        @main
        struct MyMacroPlugin: CompilerPlugin {
          let providingMacros: [Macro.Type] = [
            StringifyMacro.self,
          ]
        }
        """#,
        "MyMacroClient/MyMacroClient.swift": """
        @freestanding(expression)
        public macro stringify<T>(_ value: T) -> (T, String) = #externalMacro(module: "MyMacros", type: "StringifyMacro")

        func test() {
          1️⃣#2️⃣stringify3️⃣(1 + 2)
        }
        """,
      ],
      manifest: SwiftPMTestProject.macroPackageManifest,
      options: options
    )
    try await SwiftPMTestProject.build(at: project.scratchDirectory)

    let (uri, positions) = try project.openDocument("MyMacroClient.swift")

    let positionMarkersToBeTested = [
      (start: "1️⃣", end: "1️⃣"),
      (start: "2️⃣", end: "2️⃣"),
      (start: "1️⃣", end: "3️⃣"),
      (start: "2️⃣", end: "3️⃣"),
    ]

    for positionMarker in positionMarkersToBeTested {
      let args = ExpandMacroCommand(
        positionRange: positions[positionMarker.start]..<positions[positionMarker.end],
        textDocument: TextDocumentIdentifier(uri)
      )

      let metadata = SourceKitLSPCommandMetadata(textDocument: TextDocumentIdentifier(uri))

      var command = args.asCommand()
      command.arguments?.append(metadata.encodeToLSPAny())

      let request = ExecuteCommandRequest(command: command.command, arguments: command.arguments)

      let expectation = self.expectation(description: "Handle Show Document Request")
      let showDocumentRequestURI = ThreadSafeBox<DocumentURI?>(initialValue: nil)

      project.testClient.handleSingleRequest { (req: ShowDocumentRequest) in
        showDocumentRequestURI.value = req.uri
        expectation.fulfill()
        return ShowDocumentResponse(success: true)
      }

      let result = try await project.testClient.send(request)

      guard let resultArray: [RefactoringEdit] = Array(fromLSPArray: result ?? .null) else {
        XCTFail(
          "Result is not an array. Failed for position range between \(positionMarker.start) and \(positionMarker.end)"
        )
        return
      }

      XCTAssertEqual(
        resultArray.count,
        1,
        "resultArray is empty. Failed for position range between \(positionMarker.start) and \(positionMarker.end)"
      )
      XCTAssertEqual(
        resultArray.only?.newText,
        "(1 + 2, \"1 + 2\")",
        "Wrong macro expansion. Failed for position range between \(positionMarker.start) and \(positionMarker.end)"
      )

      try await fulfillmentOfOrThrow([expectation])

      let url = try XCTUnwrap(
        showDocumentRequestURI.value?.fileURL,
        "Failed for position range between \(positionMarker.start) and \(positionMarker.end)"
      )

      let fileContents = try String(contentsOf: url, encoding: .utf8)

      XCTAssert(
        fileContents.contains("(1 + 2, \"1 + 2\")"),
        "File doesn't contain macro expansion. Failed for position range between \(positionMarker.start) and \(positionMarker.end)"
      )

      XCTAssertEqual(
        url.lastPathComponent,
        "MyMacroClient_L5C3-L5C20.swift",
        "Failed for position range between \(positionMarker.start) and \(positionMarker.end)"
      )
    }
  }

  func testAttachedMacroExpansion() async throws {
    try await SkipUnless.canBuildMacroUsingSwiftSyntaxFromSourceKitLSPBuild()

    let options = SourceKitLSPOptions.testDefault(experimentalFeatures: [.showMacroExpansions])

    let project = try await SwiftPMTestProject(
      files: [
        "MyMacros/MyMacros.swift": #"""
        import SwiftCompilerPlugin
        import SwiftSyntax
        import SwiftSyntaxBuilder
        import SwiftSyntaxMacros

        public struct DictionaryStorageMacro {}

        extension DictionaryStorageMacro: MemberMacro {
          public static func expansion(
            of node: AttributeSyntax,
            providingMembersOf declaration: some DeclGroupSyntax,
            in context: some MacroExpansionContext
          ) throws -> [DeclSyntax] {
            return ["\n  var _storage: [String: Any] = [:]"]
          }
        }

        extension DictionaryStorageMacro: MemberAttributeMacro {
          public static func expansion(
            of node: AttributeSyntax,
            attachedTo declaration: some DeclGroupSyntax,
            providingAttributesFor member: some DeclSyntaxProtocol,
            in context: some MacroExpansionContext
          ) throws -> [AttributeSyntax] {
            return [
              AttributeSyntax(
                leadingTrivia: [.newlines(1), .spaces(2)],
                attributeName: IdentifierTypeSyntax(
                  name: .identifier("DictionaryStorageProperty")
                )
              )
            ]
          }
        }

        public struct DictionaryStoragePropertyMacro: AccessorMacro {
          public static func expansion<
            Context: MacroExpansionContext,
            Declaration: DeclSyntaxProtocol
          >(
            of node: AttributeSyntax,
            providingAccessorsOf declaration: Declaration,
            in context: Context
          ) throws -> [AccessorDeclSyntax] {
            guard let binding = declaration.as(VariableDeclSyntax.self)?.bindings.first,
              let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier,
              binding.accessorBlock == nil,
              let type = binding.typeAnnotation?.type,
              let defaultValue = binding.initializer?.value,
              identifier.text != "_storage"
            else {
              return []
            }

            return [
              """
              get {
                _storage[\(literal: identifier.text), default: \(defaultValue)] as! \(type)
              }
              """,
              """
              set {
                _storage[\(literal: identifier.text)] = newValue
              }
              """,
            ]
          }
        }

        @main
        struct MyMacroPlugin: CompilerPlugin {
          let providingMacros: [Macro.Type] = [
            DictionaryStorageMacro.self,
            DictionaryStoragePropertyMacro.self
          ]
        }
        """#,
        "MyMacroClient/MyMacroClient.swift": #"""
        @attached(memberAttribute)
        @attached(member, names: named(_storage))
        public macro DictionaryStorage() = #externalMacro(module: "MyMacros", type: "DictionaryStorageMacro")

        @attached(accessor)
        public macro DictionaryStorageProperty() =
          #externalMacro(module: "MyMacros", type: "DictionaryStoragePropertyMacro")

        1️⃣@2️⃣DictionaryStorage3️⃣
        struct Point {
          var x: Int = 1
          var y: Int = 2
        }
        """#,
      ],
      manifest: SwiftPMTestProject.macroPackageManifest,
      options: options
    )
    try await SwiftPMTestProject.build(at: project.scratchDirectory)

    let (uri, positions) = try project.openDocument("MyMacroClient.swift")

    let positionMarkersToBeTested = [
      (start: "1️⃣", end: "1️⃣"),
      (start: "2️⃣", end: "2️⃣"),
      (start: "1️⃣", end: "3️⃣"),
      (start: "2️⃣", end: "3️⃣"),
    ]

    for positionMarker in positionMarkersToBeTested {
      let args = ExpandMacroCommand(
        positionRange: positions[positionMarker.start]..<positions[positionMarker.end],
        textDocument: TextDocumentIdentifier(uri)
      )

      let metadata = SourceKitLSPCommandMetadata(textDocument: TextDocumentIdentifier(uri))

      var command = args.asCommand()
      command.arguments?.append(metadata.encodeToLSPAny())

      let request = ExecuteCommandRequest(command: command.command, arguments: command.arguments)

      let expectation = self.expectation(description: "Handle Show Document Requests")
      expectation.expectedFulfillmentCount = 3

      let showDocumentRequestURIs = ThreadSafeBox<[DocumentURI?]>(initialValue: [nil, nil, nil])

      for i in 0...2 {
        project.testClient.handleSingleRequest { (req: ShowDocumentRequest) in
          showDocumentRequestURIs.value[i] = req.uri
          expectation.fulfill()
          return ShowDocumentResponse(success: true)
        }
      }

      let result = try await project.testClient.send(request)

      guard let resultArray: [RefactoringEdit] = Array(fromLSPArray: result ?? .null) else {
        XCTFail(
          "Result is not an array. Failed for position range between \(positionMarker.start) and \(positionMarker.end)"
        )
        return
      }

      XCTAssertEqual(
        resultArray.count,
        4,
        "resultArray count is not equal to four. Failed for position range between \(positionMarker.start) and \(positionMarker.end)"
      )

      XCTAssertEqual(
        resultArray.map { $0.newText }.sorted(),
        [
          "",
          "@DictionaryStorageProperty",
          "@DictionaryStorageProperty",
          "var _storage: [String: Any] = [:]",
        ].sorted(),
        "Wrong macro expansion. Failed for position range between \(positionMarker.start) and \(positionMarker.end)"
      )

      try await fulfillmentOfOrThrow([expectation])

      let urls = try showDocumentRequestURIs.value.map {
        try XCTUnwrap(
          $0?.fileURL,
          "Failed for position range between \(positionMarker.start) and \(positionMarker.end)"
        )
      }

      let filesContents = try urls.map {
        try String(contentsOf: $0, encoding: .utf8)
      }

      XCTAssertEqual(
        filesContents.sorted(),
        [
          "@DictionaryStorageProperty",
          "@DictionaryStorageProperty",
          "var _storage: [String: Any] = [:]",
        ].sorted(),
        "Files doesn't contain correct macro expansion. Failed for position range between \(positionMarker.start) and \(positionMarker.end)"
      )

      XCTAssertEqual(
        urls.map { $0.lastPathComponent }.sorted(),
        [
          "MyMacroClient_L11C3-L11C3.swift",
          "MyMacroClient_L12C3-L12C3.swift",
          "MyMacroClient_L13C1-L13C1.swift",
        ].sorted(),
        "Failed for position range between \(positionMarker.start) and \(positionMarker.end)"
      )
    }
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
