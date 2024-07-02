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
import SKTestSupport
import SourceKitLSP
import XCTest

private typealias CodeActionCapabilities = TextDocumentClientCapabilities.CodeAction
private typealias CodeActionLiteralSupport = CodeActionCapabilities.CodeActionLiteralSupport
private typealias CodeActionKindCapabilities = CodeActionLiteralSupport.CodeActionKind

private let clientCapabilitiesWithCodeActionSupport: ClientCapabilities = {
  var documentCapabilities = TextDocumentClientCapabilities()
  var codeActionCapabilities = CodeActionCapabilities()
  let codeActionKinds = CodeActionKindCapabilities(valueSet: [.refactor, .quickFix])
  let codeActionLiteralSupport = CodeActionLiteralSupport(codeActionKind: codeActionKinds)
  codeActionCapabilities.codeActionLiteralSupport = codeActionLiteralSupport
  documentCapabilities.codeAction = codeActionCapabilities
  documentCapabilities.completion = .init(completionItem: .init(snippetSupport: true))
  return ClientCapabilities(workspace: nil, textDocument: documentCapabilities)
}()

final class CodeActionTests: XCTestCase {
  func testCodeActionResponseLegacySupport() throws {
    let command = Command(title: "Title", command: "Command", arguments: [1, "text", 2.2, nil])
    let codeAction = CodeAction(title: "1")
    let codeAction2 = CodeAction(title: "2", command: command)

    var capabilities: TextDocumentClientCapabilities.CodeAction
    var capabilityJson: String
    var data: Data
    var response: CodeActionRequestResponse
    capabilityJson =
      """
       {
         "dynamicRegistration": true,
         "codeActionLiteralSupport" : {
           "codeActionKind": {
             "valueSet": []
           }
         }
       }
      """
    data = capabilityJson.data(using: .utf8)!
    capabilities = try JSONDecoder().decode(
      TextDocumentClientCapabilities.CodeAction.self,
      from: data
    )
    response = .init(codeActions: [codeAction, codeAction2], clientCapabilities: capabilities)
    let actions = try JSONDecoder().decode([CodeAction].self, from: JSONEncoder().encode(response))
    XCTAssertEqual(actions, [codeAction, codeAction2])

    capabilityJson =
      """
      {
        "dynamicRegistration": true
      }
      """
    data = capabilityJson.data(using: .utf8)!
    capabilities = try JSONDecoder().decode(
      TextDocumentClientCapabilities.CodeAction.self,
      from: data
    )
    response = .init(codeActions: [codeAction, codeAction2], clientCapabilities: capabilities)
    let commands = try JSONDecoder().decode([Command].self, from: JSONEncoder().encode(response))
    XCTAssertEqual(commands, [command])
  }

  func testCodeActionResponseIgnoresSupportedKinds() throws {
    // The client guarantees that unsupported kinds will be handled, and in
    // practice some clients use `"codeActionKind":{"valueSet":[]}`, since
    // they support all kinds anyway. So to avoid filtering all actions, we
    // ignore the supported kinds.

    let unspecifiedAction = CodeAction(title: "Unspecified")
    let refactorAction = CodeAction(title: "Refactor", kind: .refactor)
    let quickfixAction = CodeAction(title: "Quickfix", kind: .quickFix)
    let actions = [unspecifiedAction, refactorAction, quickfixAction]

    var capabilities: TextDocumentClientCapabilities.CodeAction
    var capabilityJson: String
    var data: Data
    var response: CodeActionRequestResponse
    capabilityJson =
      """
      {
        "dynamicRegistration": true,
        "codeActionLiteralSupport" : {
          "codeActionKind": {
            "valueSet": ["refactor"]
          }
        }
      }
      """
    data = capabilityJson.data(using: .utf8)!
    capabilities = try JSONDecoder().decode(
      TextDocumentClientCapabilities.CodeAction.self,
      from: data
    )

    response = .init(codeActions: actions, clientCapabilities: capabilities)
    XCTAssertEqual(response, .codeActions([unspecifiedAction, refactorAction, quickfixAction]))

    capabilityJson =
      """
      {
        "dynamicRegistration": true,
        "codeActionLiteralSupport" : {
          "codeActionKind": {
            "valueSet": []
          }
        }
      }
      """
    data = capabilityJson.data(using: .utf8)!
    capabilities = try JSONDecoder().decode(
      TextDocumentClientCapabilities.CodeAction.self,
      from: data
    )

    response = .init(codeActions: actions, clientCapabilities: capabilities)
    XCTAssertEqual(response, .codeActions([unspecifiedAction, refactorAction, quickfixAction]))
  }

  func testCodeActionResponseCommandMetadataInjection() throws {
    let url = URL(fileURLWithPath: "/a.swift")
    let textDocument = TextDocumentIdentifier(url)
    let expectedMetadata: LSPAny = try {
      let metadata = SourceKitLSPCommandMetadata(textDocument: textDocument)
      let data = try JSONEncoder().encode(metadata)
      return try JSONDecoder().decode(LSPAny.self, from: data)
    }()
    XCTAssertEqual(expectedMetadata, .dictionary(["sourcekitlsp_textDocument": ["uri": "file:///a.swift"]]))
    let command = Command(title: "Title", command: "Command", arguments: [1, "text", 2.2, nil])
    let codeAction = CodeAction(title: "1")
    let codeAction2 = CodeAction(title: "2", command: command)
    let request = CodeActionRequest(
      range: Position(line: 0, utf16index: 0)..<Position(line: 1, utf16index: 1),
      context: .init(diagnostics: [], only: nil),
      textDocument: textDocument
    )
    var response = request.injectMetadata(toResponse: .commands([command]))
    XCTAssertEqual(
      response,
      .commands([
        Command(
          title: command.title,
          command: command.command,
          arguments: command.arguments! + [expectedMetadata]
        )
      ])
    )
    response = request.injectMetadata(toResponse: .codeActions([codeAction, codeAction2]))
    XCTAssertEqual(
      response,
      .codeActions([
        codeAction,
        CodeAction(
          title: codeAction2.title,
          command: Command(
            title: command.title,
            command: command.command,
            arguments: command.arguments! + [expectedMetadata]
          )
        ),
      ])
    )
    response = request.injectMetadata(toResponse: nil)
    XCTAssertNil(response)
  }

  func testCommandEncoding() throws {
    let dictionary: LSPAny = ["1": [nil, 2], "2": "text", "3": ["4": [1, 2]]]
    let array: LSPAny = [1, [2, "string"], dictionary]
    let arguments: LSPAny = [1, 2.2, "text", nil, array, dictionary]
    let command = Command(title: "Command", command: "command.id", arguments: [arguments, arguments])
    let decoded = try JSONDecoder().decode(Command.self, from: JSONEncoder().encode(command))
    XCTAssertEqual(decoded, command)
  }

  func testEmptyCodeActionResult() async throws {
    let testClient = try await TestSourceKitLSPClient(capabilities: clientCapabilitiesWithCodeActionSupport)
    let uri = DocumentURI(for: .swift)
    let positions = testClient.openDocument(
      """
      func foo() -> String {
        var a = "hello"
      1️⃣  return a
      }

      """,
      uri: uri
    )

    let request = CodeActionRequest(
      range: positions["1️⃣"]..<positions["1️⃣"],
      context: .init(),
      textDocument: TextDocumentIdentifier(uri)
    )
    let result = try await testClient.send(request)
    XCTAssertEqual(result, .codeActions([]))
  }

  func testSemanticRefactorLocalRenameResult() async throws {
    let testClient = try await TestSourceKitLSPClient(capabilities: clientCapabilitiesWithCodeActionSupport)
    let uri = DocumentURI(for: .swift)
    let positions = testClient.openDocument(
      """
      func localRename() {
        var 1️⃣local = 1
        _ = local
      }
      """,
      uri: uri
    )

    let request = CodeActionRequest(
      range: Range(positions["1️⃣"]),
      context: .init(),
      textDocument: TextDocumentIdentifier(uri)
    )
    let result = try await testClient.send(request)
    guard case .codeActions(let codeActions) = result else {
      XCTFail("Expected code actions")
      return
    }
    XCTAssertEqual(codeActions.map(\.title), ["Add documentation"])
  }

  func testSemanticRefactorLocationCodeActionResult() async throws {
    let testClient = try await TestSourceKitLSPClient(capabilities: clientCapabilitiesWithCodeActionSupport)
    let uri = DocumentURI(for: .swift)
    let positions = testClient.openDocument(
      """
      func foo() -> String {
        var a = "1️⃣"
        return a
      }
      """,
      uri: uri
    )

    let testPosition = positions["1️⃣"]
    let request = CodeActionRequest(
      range: Range(testPosition),
      context: .init(),
      textDocument: TextDocumentIdentifier(uri)
    )
    let result = try await testClient.send(request)

    let expectedCommandArgs: LSPAny = [
      "actionString": "source.refactoring.kind.localize.string",
      "positionRange": [
        "start": [
          "character": .int(testPosition.utf16index),
          "line": .int(testPosition.line),
        ],
        "end": [
          "character": .int(testPosition.utf16index),
          "line": .int(testPosition.line),
        ],
      ],
      "title": "Localize String",
      "textDocument": ["uri": .string(uri.stringValue)],
    ]

    let metadataArguments: LSPAny = ["sourcekitlsp_textDocument": ["uri": .string(uri.stringValue)]]
    let expectedCommand = Command(
      title: "Localize String",
      command: "semantic.refactor.command",
      arguments: [expectedCommandArgs] + [metadataArguments]
    )
    let expectedCodeAction = CodeAction(
      title: "Localize String",
      kind: .refactor,
      command: expectedCommand
    )

    guard case .codeActions(let codeActions) = result else {
      XCTFail("Expected code actions")
      return
    }

    XCTAssertTrue(codeActions.contains(expectedCodeAction))
  }

  func testJSONCodableCodeActionResult() async throws {
    let testClient = try await TestSourceKitLSPClient(capabilities: clientCapabilitiesWithCodeActionSupport)
    let uri = DocumentURI(for: .swift)
    let positions = testClient.openDocument(
      """
         1️⃣{
         "name": "Produce",
         "shelves": [
             {
                 "name": "Discount Produce",
                 "product": {
                     "name": "Banana",
                     "points": 200,
                     "description": "A banana that's perfectly ripe."
                 }
             }
         ]
      }
      """,
      uri: uri
    )

    let testPosition = positions["1️⃣"]
    let request = CodeActionRequest(
      range: Range(testPosition),
      context: .init(),
      textDocument: TextDocumentIdentifier(uri)
    )
    let result = try await testClient.send(request)

    guard case .codeActions(let codeActions) = result else {
      XCTFail("Expected code actions")
      return
    }

    // Make sure we get a JSON conversion action.
    let codableAction = codeActions.first { action in
      return action.title == "Create Codable structs from JSON"
    }
    XCTAssertNotNil(codableAction)
  }

  func testSemanticRefactorRangeCodeActionResult() async throws {
    let testClient = try await TestSourceKitLSPClient(capabilities: clientCapabilitiesWithCodeActionSupport)
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

    let startPosition = positions["1️⃣"]
    let endPosition = positions["2️⃣"]
    let request = CodeActionRequest(
      range: startPosition..<endPosition,
      context: .init(),
      textDocument: TextDocumentIdentifier(uri)
    )
    let result = try await testClient.send(request)

    let expectedCommandArgs: LSPAny = [
      "actionString": "source.refactoring.kind.extract.function",
      "positionRange": [
        "start": [
          "character": .int(startPosition.utf16index),
          "line": .int(startPosition.line),
        ],
        "end": [
          "character": .int(endPosition.utf16index),
          "line": .int(endPosition.line),
        ],
      ],
      "title": "Extract Method",
      "textDocument": ["uri": .string(uri.stringValue)],
    ]
    let metadataArguments: LSPAny = ["sourcekitlsp_textDocument": ["uri": .string(uri.stringValue)]]
    let expectedCommand = Command(
      title: "Extract Method",
      command: "semantic.refactor.command",
      arguments: [expectedCommandArgs] + [metadataArguments]
    )
    let expectedCodeAction = CodeAction(
      title: "Extract Method",
      kind: .refactor,
      command: expectedCommand
    )

    guard case .codeActions(var resultActions) = result else {
      XCTFail("Result doesn't have code actions: \(String(describing: result))")
      return
    }

    // Filter out "Add documentation"; we test it elsewhere
    if let addDocIndex = resultActions.firstIndex(where: {
      $0.title == "Add documentation"
    }
    ) {
      resultActions.remove(at: addDocIndex)
    } else {
      XCTFail("Missing 'Add documentation'.")
      return
    }

    XCTAssertEqual(resultActions, [expectedCodeAction])
  }

  func testCodeActionsRemovePlaceholders() async throws {
    let testClient = try await TestSourceKitLSPClient(
      capabilities: clientCapabilitiesWithCodeActionSupport,
      usePullDiagnostics: false
    )
    let uri = DocumentURI(for: .swift)

    let positions = testClient.openDocument(
      """
      protocol MyProto {
        func foo()
      }

      struct 1️⃣MyStruct: MyProto {

      }
      """,
      uri: uri
    )

    let diags = try await testClient.nextDiagnosticsNotification()
    XCTAssertEqual(diags.uri, uri)
    XCTAssertEqual(diags.diagnostics.count, 1)
    let diagPosition = try XCTUnwrap(diags.diagnostics.only?.range.lowerBound)

    let quickFixActionResult = try await testClient.send(
      CodeActionRequest(
        range: Range(diagPosition),
        context: .init(diagnostics: diags.diagnostics),
        textDocument: TextDocumentIdentifier(uri)
      )
    )

    guard case .codeActions(let quickFixCodeActions) = quickFixActionResult else {
      return XCTFail("Expected code actions, not commands as a response")
    }

    // Check that the Fix-It action contains snippets

    guard let quickFixAction = quickFixCodeActions.filter({ $0.kind == .quickFix }).spm_only else {
      return XCTFail("Expected exactly one quick fix action")
    }
    guard let change = quickFixAction.edit?.changes?[uri]?.spm_only else {
      return XCTFail("Expected exactly one change")
    }
    XCTAssertEqual(
      change.newText.trimmingTrailingWhitespace(),
      """

          func foo() {

          }

      """
    )

    // Check that the refactor action contains snippets
    let refactorActionResult = try await testClient.send(
      CodeActionRequest(
        range: Range(positions["1️⃣"]),
        context: .init(diagnostics: diags.diagnostics),
        textDocument: TextDocumentIdentifier(uri)
      )
    )

    guard case .codeActions(let refactorActions) = refactorActionResult else {
      return XCTFail("Expected code actions, not commands as a response")
    }

    guard let refactorAction = refactorActions.filter({ $0.kind == .refactor }).spm_only else {
      return XCTFail("Expected exactly one refactor action")
    }
    guard let command = refactorAction.command else {
      return XCTFail("Expected the refactor action to have a command")
    }

    let editReceived = self.expectation(description: "Received ApplyEdit request")

    testClient.handleSingleRequest { (request: ApplyEditRequest) -> ApplyEditResponse in
      defer {
        editReceived.fulfill()
      }
      guard let change = request.edit.changes?[uri]?.spm_only else {
        XCTFail("Expected exactly one edit")
        return ApplyEditResponse(applied: false, failureReason: "Expected exactly one edit")
      }
      XCTAssertEqual(
        change.newText.trimmingTrailingWhitespace(),
        """

            func foo() {

            }

        """
      )
      return ApplyEditResponse(applied: true, failureReason: nil)
    }
    _ = try await testClient.send(ExecuteCommandRequest(command: command.command, arguments: command.arguments))

    try await fulfillmentOfOrThrow([editReceived])
  }

  func testAddDocumentationCodeActionResult() async throws {
    let testClient = try await TestSourceKitLSPClient(capabilities: clientCapabilitiesWithCodeActionSupport)
    let uri = DocumentURI(for: .swift)
    let positions = testClient.openDocument(
      """
      2️⃣func refacto1️⃣r(syntax: DeclSyntax, in context: Void) -> DeclSyntax? { }3️⃣
      """,
      uri: uri
    )

    let testPosition = positions["1️⃣"]
    let request = CodeActionRequest(
      range: Range(testPosition),
      context: .init(),
      textDocument: TextDocumentIdentifier(uri)
    )
    let result = try await testClient.send(request)

    guard case .codeActions(let codeActions) = result else {
      XCTFail("Expected code actions")
      return
    }

    // Make sure we get an add-documentation action.
    let addDocAction = codeActions.first { action in
      return action.title == "Add documentation"
    }
    XCTAssertNotNil(addDocAction)
  }

  func testCodeActionForFixItsProducedBySwiftSyntax() async throws {
    let project = try await MultiFileTestProject(files: [
      "test.swift": "protocol 1️⃣Multi 2️⃣ident 3️⃣{}",
      "compile_commands.json": "[]",
    ])

    let (uri, positions) = try project.openDocument("test.swift")

    let report = try await project.testClient.send(
      DocumentDiagnosticsRequest(textDocument: TextDocumentIdentifier(uri))
    )
    guard case .full(let fullReport) = report else {
      XCTFail("Expected full diagnostics report")
      return
    }

    XCTAssertEqual(fullReport.items.count, 1)
    let diagnostic = try XCTUnwrap(fullReport.items.first)
    let codeActions = try XCTUnwrap(diagnostic.codeActions)

    let expectedCodeActions = [
      CodeAction(
        title: "Join the identifiers together",
        kind: .quickFix,
        edit: WorkspaceEdit(
          changes: [
            uri: [
              TextEdit(range: positions["1️⃣"]..<positions["2️⃣"], newText: "Multiident "),
              TextEdit(range: positions["2️⃣"]..<positions["3️⃣"], newText: ""),
            ]
          ]
        )
      ),
      CodeAction(
        title: "Join the identifiers together with camel-case",
        kind: .quickFix,
        edit: WorkspaceEdit(
          changes: [
            uri: [
              TextEdit(range: positions["1️⃣"]..<positions["2️⃣"], newText: "MultiIdent "),
              TextEdit(range: positions["2️⃣"]..<positions["3️⃣"], newText: ""),
            ]
          ]
        )
      ),
    ]
    XCTAssertEqual(expectedCodeActions, codeActions)
  }

  func testPackageManifestEditingCodeActionResult() async throws {
    let testClient = try await TestSourceKitLSPClient(capabilities: clientCapabilitiesWithCodeActionSupport)
    let uri = DocumentURI(for: .swift)
    let positions = testClient.openDocument(
      """
      // swift-tools-version: 5.5
      let package = Package(
          name: "packages",
          targets: [
              .tar1️⃣get(name: "MyLib"),
          ]
      )
      """,
      uri: uri
    )

    let testPosition = positions["1️⃣"]
    let request = CodeActionRequest(
      range: Range(testPosition),
      context: .init(),
      textDocument: TextDocumentIdentifier(uri)
    )
    let result = try await testClient.send(request)

    guard case .codeActions(let codeActions) = result else {
      XCTFail("Expected code actions")
      return
    }

    // Make sure we get the expected package manifest editing actions.
    let addTestAction = codeActions.first { action in
      return action.title == "Add test target (Swift Testing)"
    }
    XCTAssertNotNil(addTestAction)

    XCTAssertTrue(
      codeActions.contains { action in
        action.title == "Add library target"
      }
    )

    guard let addTestChanges = addTestAction?.edit?.documentChanges else {
      XCTFail("Didn't have changes in the 'Add test target (Swift Testing)' action")
      return
    }

    guard
      let addTestEdit = addTestChanges.lazy.compactMap({ change in
        switch change {
        case .textDocumentEdit(let edit): edit
        default: nil
        }
      }).first
    else {
      XCTFail("Didn't have edits")
      return
    }

    XCTAssertTrue(
      addTestEdit.edits.contains { edit in
        switch edit {
        case .textEdit(let edit): edit.newText.contains("testTarget")
        case .annotatedTextEdit(let edit): edit.newText.contains("testTarget")
        }
      }
    )

    XCTAssertTrue(
      codeActions.contains { action in
        return action.title == "Add product to export this target"
      }
    )
  }

  func testPackageManifestEditingCodeActionNoTestResult() async throws {
    let testClient = try await TestSourceKitLSPClient(capabilities: clientCapabilitiesWithCodeActionSupport)
    let uri = DocumentURI(for: .swift)
    let positions = testClient.openDocument(
      """
      // swift-tools-version: 5.5
      let package = Package(
          name: "packages",
          targets: [
              .testTar1️⃣get(name: "MyLib"),
          ]
      )
      """,
      uri: uri
    )

    let testPosition = positions["1️⃣"]
    let request = CodeActionRequest(
      range: Range(testPosition),
      context: .init(),
      textDocument: TextDocumentIdentifier(uri)
    )
    let result = try await testClient.send(request)

    guard case .codeActions(let codeActions) = result else {
      XCTFail("Expected code actions")
      return
    }

    // Make sure we get the expected package manifest editing actions.
    XCTAssertTrue(
      !codeActions.contains { action in
        return action.title == "Add test target"
      }
    )

    XCTAssertTrue(
      !codeActions.contains { action in
        return action.title == "Add product to export this target"
      }
    )
  }

  func testConvertIntegerLiteral() async throws {
    try await assertCodeActions(
      """
      let x = 1️⃣12️⃣63️⃣
      """,
      ranges: [("1️⃣", "2️⃣"), ("1️⃣", "3️⃣")]
    ) { uri, positions in
      [
        CodeAction(
          title: "Convert 16 to 0b10000",
          kind: .refactorInline,
          diagnostics: nil,
          edit: WorkspaceEdit(
            changes: [uri: [TextEdit(range: positions["1️⃣"]..<positions["3️⃣"], newText: "0b10000")]]
          ),
          command: nil
        ),
        CodeAction(
          title: "Convert 16 to 0o20",
          kind: .refactorInline,
          diagnostics: nil,
          edit: WorkspaceEdit(
            changes: [uri: [TextEdit(range: positions["1️⃣"]..<positions["3️⃣"], newText: "0o20")]]
          ),
          command: nil
        ),
        CodeAction(
          title: "Convert 16 to 0x10",
          kind: .refactorInline,
          diagnostics: nil,
          edit: WorkspaceEdit(
            changes: [uri: [TextEdit(range: positions["1️⃣"]..<positions["3️⃣"], newText: "0x10")]]
          ),
          command: nil
        ),
      ]
    }
  }

  func testFormatRawStringLiteral() async throws {
    try await assertCodeActions(
      """
      let x = 1️⃣#"Hello 2️⃣world"#3️⃣
      """,
      ranges: [("1️⃣", "3️⃣")],
      exhaustive: false
    ) { uri, positions in
      [
        CodeAction(
          title: "Convert string literal to minimal number of \'#\'s",
          kind: .refactorInline,
          diagnostics: nil,
          edit: WorkspaceEdit(
            changes: [uri: [TextEdit(range: positions["1️⃣"]..<positions["3️⃣"], newText: #""Hello world""#)]]
          ),
          command: nil
        )
      ]
    }
  }

  func testFormatRawStringLiteralFromInterpolation() async throws {
    try await assertCodeActions(
      ##"""
      let x = 1️⃣#"Hello 2️⃣\#(name)"#3️⃣
      """##,
      ranges: [("1️⃣", "3️⃣")],
      exhaustive: false
    ) { uri, positions in
      [
        CodeAction(
          title: "Convert string literal to minimal number of \'#\'s",
          kind: .refactorInline,
          diagnostics: nil,
          edit: WorkspaceEdit(
            changes: [
              uri: [
                TextEdit(
                  range: positions["1️⃣"]..<positions["3️⃣"],
                  newText: ##"""
                    ##"Hello \#(name)"##
                    """##
                )
              ]
            ]
          ),
          command: nil
        )
      ]
    }
  }

  func testFormatRawStringLiteralDoesNotShowUpWhenInvokedFromInsideInterpolationSegment() async throws {
    try await assertCodeActions(
      ##"""
      let x = #"Hello \#(n1️⃣ame)"#
      """##
    ) { uri, positions in
      []
    }
  }

  func testMigrateIfLetSyntax() async throws {
    try await assertCodeActions(
      ##"""
      1️⃣if 2️⃣let 3️⃣foo = 4️⃣foo {}5️⃣
      """##,
      markers: ["1️⃣", "2️⃣", "3️⃣", "4️⃣"],
      ranges: [("1️⃣", "4️⃣"), ("1️⃣", "5️⃣")]
    ) { uri, positions in
      [
        CodeAction(
          title: "Migrate to shorthand 'if let' syntax",
          kind: .refactorInline,
          diagnostics: nil,
          edit: WorkspaceEdit(
            changes: [
              uri: [
                TextEdit(
                  range: positions["1️⃣"]..<positions["5️⃣"],
                  newText: "if let foo {}"
                )
              ]
            ]
          ),
          command: nil
        )
      ]
    }
  }

  func testMigrateIfLetSyntaxDoesNotShowUpWhenInvokedFromInsideTheBody() async throws {
    try await assertCodeActions(
      ##"""
      if let foo = foo 1️⃣{
        2️⃣print(foo)
      3️⃣}4️⃣
      """##
    ) { uri, positions in
      []
    }
  }

  func testOpaqueParameterToGeneric() async throws {
    try await assertCodeActions(
      ##"""
      1️⃣func 2️⃣someFunction(_ 3️⃣input: some4️⃣ Value) {}5️⃣
      """##,
      markers: ["1️⃣", "2️⃣", "3️⃣", "4️⃣"],
      ranges: [("1️⃣", "2️⃣"), ("1️⃣", "5️⃣")],
      exhaustive: false
    ) { uri, positions in
      [
        CodeAction(
          title: "Expand 'some' parameters to generic parameters",
          kind: .refactorInline,
          diagnostics: nil,
          edit: WorkspaceEdit(
            changes: [
              uri: [
                TextEdit(
                  range: positions["1️⃣"]..<positions["5️⃣"],
                  newText: "func someFunction<T1: Value>(_ input: T1) {}"
                )
              ]
            ]
          ),
          command: nil
        )
      ]
    }
  }

  func testOpaqueParameterToGenericIsNotShownFromTheBody() async throws {
    try await assertCodeActions(
      ##"""
      func someFunction(_ input: some Value) 1️⃣{
        2️⃣print("x")
      }3️⃣
      """##,
      exhaustive: false
    ) { uri, positions in
      []
    }
  }

  func testConvertJSONToCodable() async throws {
    try await assertCodeActions(
      ##"""
      1️⃣{
        2️⃣"id": 3️⃣1,
        "values": 4️⃣["foo", "bar"]
      }5️⃣

      """##,
      ranges: [("1️⃣", "5️⃣")],
      exhaustive: false
    ) { uri, positions in
      [
        CodeAction(
          title: "Create Codable structs from JSON",
          kind: .refactorInline,
          diagnostics: nil,
          edit: WorkspaceEdit(
            changes: [
              uri: [
                TextEdit(
                  range: positions["1️⃣"]..<positions["5️⃣"],
                  newText: """
                    struct JSONValue: Codable {
                      var id: Double
                      var values: [String]
                    }
                    """
                )
              ]
            ]
          ),
          command: nil
        )
      ]
    }
  }

  func testAddDocumentationRefactorNotAtStartOfFile() async throws {
    try await assertCodeActions(
      """
      struct Foo {
        1️⃣func 2️⃣refactor(3️⃣syntax: 4️⃣Decl5️⃣Syntax)6️⃣ { }7️⃣
      }
      """,
      ranges: [("1️⃣", "2️⃣"), ("1️⃣", "6️⃣"), ("1️⃣", "7️⃣")],
      exhaustive: false
    ) { uri, positions in
      [
        CodeAction(
          title: "Add documentation",
          kind: .refactorInline,
          diagnostics: nil,
          edit: WorkspaceEdit(
            changes: [
              uri: [
                TextEdit(
                  range: Range(positions["1️⃣"]),
                  newText: """
                    /// A description
                      /// - Parameter syntax:
                      \("")
                    """
                )
              ]
            ]
          ),
          command: nil
        )
      ]
    }
  }

  func testAddDocumentationRefactorAtStartOfFile() async throws {
    try await assertCodeActions(
      """
      1️⃣func 2️⃣refactor(3️⃣syntax: 4️⃣Decl5️⃣Syntax)6️⃣ { }7️⃣
      """,
      ranges: [("1️⃣", "2️⃣"), ("1️⃣", "6️⃣"), ("1️⃣", "7️⃣")],
      exhaustive: false
    ) { uri, positions in
      [
        CodeAction(
          title: "Add documentation",
          kind: .refactorInline,
          diagnostics: nil,
          edit: WorkspaceEdit(
            changes: [
              uri: [
                TextEdit(
                  range: Range(positions["1️⃣"]),
                  newText: """
                    /// A description
                    /// - Parameter syntax:
                    \("")
                    """
                )
              ]
            ]
          ),
          command: nil
        )
      ]
    }
  }

  func testAddDocumentationDoesNotShowUpIfItIsNotOnItsOwnLine() async throws {
    try await assertCodeActions(
      """
      var x = 1; var 1️⃣y = 2
      """
    ) { uri, positions in
      []
    }
  }

  func testConvertIUOToProperOptional() async throws {
    try await assertCodeActions(
      """
      func (a: 1️⃣(String, /* tuple */ Int)!2️⃣/*tra3️⃣iling*/4️⃣)
      """,
      markers: ["1️⃣", "2️⃣", "3️⃣"],
      ranges: [("1️⃣", "2️⃣"), ("1️⃣", "3️⃣")],
      exhaustive: false
    ) { uri, positions in
      [
        CodeAction(
          title: "Convert Implicitly Unwrapped Optional to Optional",
          kind: .refactorInline,
          edit: WorkspaceEdit(
            changes: [
              uri: [
                TextEdit(
                  range: positions["1️⃣"]..<positions["4️⃣"],
                  newText: "(String, /* tuple */ Int)?/*trailing*/"
                )
              ]
            ]
          )
        )
      ]
    }
  }

  /// Retrieves the code action at a set of markers and asserts that it matches a list of expected code actions.
  ///
  /// - Parameters:
  ///   - markedText: The source file input to get the code actions for.
  ///   - markers: The list of markers to retrieve code actions at. If `nil` code actions will be retrieved for all
  ///     markers in `markedText`
  ///   - ranges: If specified, code actions are also requested for selection ranges between these markers.
  ///   - exhaustive: Whether `expected` is expected to be a subset of the returned code actions or whether it is
  ///     expected to exhaustively match all code actions.
  ///   - expected: A closure that returns the list of expected code actions, given the URI of the test document and the
  ///     marker positions within.
  private func assertCodeActions(
    _ markedText: String,
    markers: [String]? = nil,
    ranges: [(String, String)] = [],
    exhaustive: Bool = true,
    expected: (_ uri: DocumentURI, _ positions: DocumentPositions) -> [CodeAction],
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let testClient = try await TestSourceKitLSPClient(capabilities: clientCapabilitiesWithCodeActionSupport)
    let uri = DocumentURI(for: .swift)
    let positions = testClient.openDocument(markedText, uri: uri)

    var ranges = ranges
    if let markers {
      ranges += markers.map { ($0, $0) }
    } else {
      ranges += extractMarkers(markedText).markers.map(\.key).map { ($0, $0) }
    }

    for (startMarker, endMarker) in ranges {
      let result = try await testClient.send(
        CodeActionRequest(
          range: positions[startMarker]..<positions[endMarker],
          context: .init(),
          textDocument: TextDocumentIdentifier(uri)
        )
      )
      guard case .codeActions(let codeActions) = result else {
        XCTFail("Expected code actions at range \(startMarker)-\(endMarker)", file: file, line: line)
        return
      }
      if exhaustive {
        XCTAssertEqual(
          codeActions,
          expected(uri, positions),
          "Found unexpected code actions at range \(startMarker)-\(endMarker)",
          file: file,
          line: line
        )
      } else {
        XCTAssert(
          codeActions.contains(expected(uri, positions)),
          """
          Code actions did not contain expected at range \(startMarker)-\(endMarker):
          \(codeActions)
          """,
          file: file,
          line: line
        )
      }
    }
  }
}
