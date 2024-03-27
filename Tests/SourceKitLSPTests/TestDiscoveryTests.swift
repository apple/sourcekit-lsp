//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import LanguageServerProtocol
import SKTestSupport
import XCTest

final class TestDiscoveryTests: XCTestCase {
  func testWorkspaceTests() async throws {
    try SkipUnless.longTestsEnabled()

    let project = try await SwiftPMTestProject(
      files: [
        "Tests/MyLibraryTests/MyTests.swift": """
        import XCTest

        class 1️⃣MyTests: XCTestCase {
          func 2️⃣testMyLibrary() {}
          func unrelatedFunc() {}
          var testVariable: Int = 0
        }
        """
      ],
      manifest: """
        // swift-tools-version: 5.7

        import PackageDescription

        let package = Package(
          name: "MyLibrary",
          targets: [.testTarget(name: "MyLibraryTests")]
        )
        """,
      build: true
    )

    let tests = try await project.testClient.send(WorkspaceTestsRequest())
    XCTAssertEqual(
      tests,
      [
        WorkspaceSymbolItem.symbolInformation(
          SymbolInformation(
            name: "MyTests",
            kind: .class,
            location: Location(
              uri: try project.uri(for: "MyTests.swift"),
              range: Range(try project.position(of: "1️⃣", in: "MyTests.swift"))
            )
          )
        ),
        WorkspaceSymbolItem.symbolInformation(
          SymbolInformation(
            name: "testMyLibrary()",
            kind: .method,
            location: Location(
              uri: try project.uri(for: "MyTests.swift"),
              range: Range(try project.position(of: "2️⃣", in: "MyTests.swift"))
            ),
            containerName: "MyTests"
          )
        ),
      ]
    )
  }

  func testIndexBasedDocumentTests() async throws {
    try SkipUnless.longTestsEnabled()

    let project = try await SwiftPMTestProject(
      files: [
        "Tests/MyLibraryTests/MyTests.swift": """
        import XCTest

        class 1️⃣MyTests: XCTestCase {
          func 2️⃣testMyLibrary() {}
          func unrelatedFunc() {}
          var testVariable: Int = 0
        }
        """,
        "Tests/MyLibraryTests/MoreTests.swift": """
        import XCTest

        class MoreTests: XCTestCase {
          func testSomeMore() {}
        }
        """,
      ],
      manifest: """
        // swift-tools-version: 5.7

        import PackageDescription

        let package = Package(
          name: "MyLibrary",
          targets: [.testTarget(name: "MyLibraryTests")]
        )
        """,
      build: true
    )

    let (uri, positions) = try project.openDocument("MyTests.swift")
    let tests = try await project.testClient.send(DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri)))
    XCTAssertEqual(
      tests,
      [
        WorkspaceSymbolItem.symbolInformation(
          SymbolInformation(
            name: "MyTests",
            kind: .class,
            location: Location(
              uri: uri,
              range: Range(positions["1️⃣"])
            )
          )
        ),
        WorkspaceSymbolItem.symbolInformation(
          SymbolInformation(
            name: "testMyLibrary()",
            kind: .method,
            location: Location(
              uri: try project.uri(for: "MyTests.swift"),
              range: Range(positions["2️⃣"])
            ),
            containerName: "MyTests"
          )
        ),
      ]
    )
  }

  func testSyntacticDocumentTestsSwift() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI.for(.swift)

    let positions = testClient.openDocument(
      """
      import XCTest

      class 1️⃣MyTests: XCTestCase {
        func 2️⃣testMyLibrary() {}
        func unrelatedFunc() {}
        var testVariable: Int = 0
      }
      """,
      uri: uri
    )

    let tests = try await testClient.send(DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri)))
    XCTAssertEqual(
      tests,
      [
        WorkspaceSymbolItem.symbolInformation(
          SymbolInformation(
            name: "MyTests",
            kind: .class,
            location: Location(
              uri: uri,
              range: Range(positions["1️⃣"])
            )
          )
        ),
        WorkspaceSymbolItem.symbolInformation(
          SymbolInformation(
            name: "testMyLibrary",
            kind: .method,
            location: Location(
              uri: uri,
              range: Range(positions["2️⃣"])
            ),
            containerName: "MyTests"
          )
        ),
      ]
    )
  }

  func testDocumentTestsGetRefinedWithIndexedFile() async throws {
    try SkipUnless.longTestsEnabled()

    let project = try await SwiftPMTestProject(
      files: [
        "Tests/MyLibraryTests/MyTests.swift": """
        import XCTest

        class LooksLikeTestCaseButIsNot {}

        class 1️⃣MyTests: LooksLikeTestCaseButIsNot {
          func 2️⃣testMyLibrary() {}
          func unrelatedFunc() {}
          var testVariable: Int = 0
        }
        """
      ],
      manifest: """
        // swift-tools-version: 5.7

        import PackageDescription

        let package = Package(
          name: "MyLibrary",
          targets: [.testTarget(name: "MyLibraryTests")]
        )
        """
    )

    let (uri, positions) = try project.openDocument("MyTests.swift")

    // Syntactically we can't tell that `LooksLikeTestCaseButIsNot` is not a subclass of `XCTestCase`.
    // We are thus conservative and report it as tests.
    let syntacticTests = try await project.testClient.send(
      DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri))
    )
    XCTAssertEqual(
      syntacticTests,
      [
        WorkspaceSymbolItem.symbolInformation(
          SymbolInformation(
            name: "MyTests",
            kind: .class,
            location: Location(
              uri: uri,
              range: Range(positions["1️⃣"])
            )
          )
        ),
        WorkspaceSymbolItem.symbolInformation(
          SymbolInformation(
            name: "testMyLibrary",
            kind: .method,
            location: Location(
              uri: try project.uri(for: "MyTests.swift"),
              range: Range(positions["2️⃣"])
            ),
            containerName: "MyTests"
          )
        ),
      ]
    )

    try await SwiftPMTestProject.build(at: project.scratchDirectory)

    // After indexing, we know that `LooksLikeTestCaseButIsNot` does not inherit from `XCTestCase` and we don't report any tests.
    let indexBasedTests = try await project.testClient.send(
      DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri))
    )
    XCTAssertEqual(indexBasedTests, [])
  }
}
