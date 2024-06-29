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
import SKTestSupport
import XCTest

final class SwiftPMIntegrationTests: XCTestCase {

  func testSwiftPMIntegration() async throws {
    let project = try await SwiftPMTestProject(
      files: [
        "Lib.swift": """
        struct Lib {
          func 1️⃣foo() {}
        }
        """,
        "Other.swift": """
        func test() {
          Lib().2️⃣foo()
        }
        """,
      ],
      enableBackgroundIndexing: true
    )

    let (otherUri, otherPositions) = try project.openDocument("Other.swift")
    let callPosition = otherPositions["2️⃣"]

    let refs = try await project.testClient.send(
      ReferencesRequest(
        textDocument: TextDocumentIdentifier(otherUri),
        position: callPosition,
        context: ReferencesContext(includeDeclaration: true)
      )
    )

    XCTAssertEqual(
      Set(refs),
      [
        Location(uri: otherUri, range: Range(callPosition)),
        Location(uri: try project.uri(for: "Lib.swift"), range: Range(try project.position(of: "1️⃣", in: "Lib.swift"))),
      ]
    )

    let completions = try await project.testClient.send(
      CompletionRequest(textDocument: TextDocumentIdentifier(otherUri), position: callPosition)
    )

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
            TextEdit(range: Range(callPosition), newText: "foo()")
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
            TextEdit(range: Range(callPosition), newText: "self")
          )
        ),
      ]
    )
  }

  func testAddFile() async throws {
    let project = try await SwiftPMTestProject(
      files: [
        "Lib.swift": """
        struct Lib {
          func foo() {
            1️⃣
          }
        }
        """
      ],
      enableBackgroundIndexing: true
    )

    let newFileUrl = project.scratchDirectory
      .appendingPathComponent("Sources")
      .appendingPathComponent("MyLibrary")
      .appendingPathComponent("Other.swift")
    let newFileUri = DocumentURI(newFileUrl)

    let newFileContents = """
      func baz(l: Lib)  {
        l.2️⃣foo()
      }
      """
    try extractMarkers(newFileContents).textWithoutMarkers.write(to: newFileUrl, atomically: false, encoding: .utf8)

    // Check that we don't get cross-file code completion before we send a `DidChangeWatchedFilesNotification` to make
    // sure we didn't include the file in the initial retrieval of build settings.
    let (oldFileUri, oldFilePositions) = try project.openDocument("Lib.swift")
    let newFilePositions = project.testClient.openDocument(newFileContents, uri: newFileUri)

    let completionsBeforeDidChangeNotification = try await project.testClient.send(
      CompletionRequest(textDocument: TextDocumentIdentifier(newFileUri), position: newFilePositions["2️⃣"])
    )
    XCTAssertEqual(completionsBeforeDidChangeNotification.items, [])

    // Send a `DidChangeWatchedFilesNotification` and verify that we now get cross-file code completion.
    project.testClient.send(
      DidChangeWatchedFilesNotification(changes: [
        FileEvent(uri: newFileUri, type: .created)
      ])
    )

    // Ensure that the DidChangeWatchedFilesNotification is handled before we continue.
    _ = try await project.testClient.send(BarrierRequest())

    let completions = try await project.testClient.send(
      CompletionRequest(textDocument: TextDocumentIdentifier(newFileUri), position: newFilePositions["2️⃣"])
    )

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
            TextEdit(range: Range(newFilePositions["2️⃣"]), newText: "foo()")
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
            TextEdit(range: Range(newFilePositions["2️⃣"]), newText: "self")
          )
        ),
      ]
    )

    // Check that we get code completion for `baz` (defined in the new file) in the old file.
    // I.e. check that the existing file's build settings have been updated to include the new file.

    let oldFileCompletions = try await project.testClient.send(
      CompletionRequest(textDocument: TextDocumentIdentifier(oldFileUri), position: oldFilePositions["1️⃣"])
    )
    XCTAssert(oldFileCompletions.items.contains(where: { $0.label == "baz(l: Lib)" }))
  }

  func testNestedPackage() async throws {
    let project = try await MultiFileTestProject(files: [
      "pkg/Sources/lib/lib.swift": "",
      "pkg/Package.swift": """
      // swift-tools-version:4.2
      import PackageDescription
      let package = Package(name: "a", products: [], dependencies: [],
      targets: [.target(name: "lib", dependencies: [])])
      """,
      "nested/pkg/Sources/lib/a.swift.swift": """
      struct Foo {
        func bar() {}
      }
      """,
      "nested/pkg/Sources/lib/b.swift": """
      func test(foo: Foo) {
        foo.1️⃣
      }
      """,
      "nested/pkg/Package.swift": """
      // swift-tools-version:4.2
      import PackageDescription
      let package = Package(name: "a", products: [], dependencies: [],
      targets: [.target(name: "lib", dependencies: [])])
      """,
    ])

    let (uri, positions) = try project.openDocument("b.swift")

    let result = try await project.testClient.send(
      CompletionRequest(textDocument: TextDocumentIdentifier(uri), position: positions["1️⃣"])
    )

    XCTAssertEqual(
      result.items,
      [
        CompletionItem(
          label: "bar()",
          kind: .method,
          detail: "Void",
          deprecated: false,
          filterText: "bar()",
          insertText: "bar()",
          insertTextFormat: .plain,
          textEdit: .textEdit(TextEdit(range: positions["1️⃣"]..<positions["1️⃣"], newText: "bar()"))
        ),
        CompletionItem(
          label: "self",
          kind: .keyword,
          detail: "Foo",
          deprecated: false,
          filterText: "self",
          insertText: "self",
          insertTextFormat: .plain,
          textEdit: .textEdit(TextEdit(range: positions["1️⃣"]..<positions["1️⃣"], newText: "self"))
        ),
      ]
    )
  }

  func testWasm() async throws {
    try await SkipUnless.canCompileForWasm()

    let project = try await SwiftPMTestProject(
      files: [
        "/.sourcekit-lsp/config.json": """
        {
          "swiftPM": {
            "triple": "wasm32-unknown-none-wasm"
          }
        }
        """,
        "Test.swift": """
        #if arch(wasm32)
        let _: UnsafeRawPointer = 1
        #endif
        """,
      ],
      manifest: """
        let package = Package(
          name: "WasmTest",
          targets: [
            .executableTarget(
              name: "wasmTest",
              cSettings: [.unsafeFlags(["-fdeclspec"])],
              swiftSettings: [
                .enableExperimentalFeature("Embedded"),
                .interoperabilityMode(.Cxx),
                .unsafeFlags(["-wmo", "-disable-cmo", "-Xfrontend", "-gnone"]),
              ],
              linkerSettings: [.unsafeFlags(["-Xclang-linker", "-nostdlib", "-Xlinker", "--no-entry"])]
            )
          ]
        )
        """
    )

    let (uri, _) = try project.openDocument("Test.swift")
    let diagnostics = try await project.testClient.send(
      DocumentDiagnosticsRequest(textDocument: TextDocumentIdentifier(uri))
    )
    guard case .full(let diagnostics) = diagnostics else {
      XCTFail("Expected full diagnostics report")
      return
    }
    XCTAssertEqual(
      diagnostics.items.map(\.message),
      ["Cannot convert value of type 'Int' to specified type 'UnsafeRawPointer'"]
    )
  }
}
