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
        TestItem(
          id: "MyTests",
          label: "MyTests",
          location: Location(
            uri: try project.uri(for: "MyTests.swift"),
            range: Range(try project.position(of: "1️⃣", in: "MyTests.swift"))
          ),
          children: [
            TestItem(
              id: "MyTests/testMyLibrary()",
              label: "testMyLibrary()",
              location: Location(
                uri: try project.uri(for: "MyTests.swift"),
                range: Range(try project.position(of: "2️⃣", in: "MyTests.swift"))
              ),
              children: [],
              tags: []
            )
          ],
          tags: []
        )
      ]
    )
  }

  func testIndexBasedDocumentTests() async throws {
    try SkipUnless.longTestsEnabled()

    let project = try await SwiftPMTestProject(
      files: [
        "Tests/MyLibraryTests/MyTests.swift": """
        import XCTest

        1️⃣class MyTests: XCTestCase {
          2️⃣func testMyLibrary() {}3️⃣
          func unrelatedFunc() {}
          var testVariable: Int = 0
        }4️⃣
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
        TestItem(
          id: "MyTests",
          label: "MyTests",
          location: Location(uri: uri, range: positions["1️⃣"]..<positions["4️⃣"]),
          children: [
            TestItem(
              id: "MyTests/testMyLibrary()",
              label: "testMyLibrary()",
              location: Location(uri: try project.uri(for: "MyTests.swift"), range: positions["2️⃣"]..<positions["3️⃣"]),
              children: [],
              tags: []
            )
          ],
          tags: []
        )
      ]
    )
  }

  func testSyntacticDocumentTestsSwift() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI.for(.swift)

    let positions = testClient.openDocument(
      """
      import XCTest

      1️⃣class MyTests: XCTestCase {
        2️⃣func testMyLibrary() {}3️⃣
        func unrelatedFunc() {}
        var testVariable: Int = 0
      }4️⃣
      """,
      uri: uri
    )

    let tests = try await testClient.send(DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri)))
    XCTAssertEqual(
      tests,
      [
        TestItem(
          id: "MyTests",
          label: "MyTests",
          location: Location(uri: uri, range: positions["1️⃣"]..<positions["4️⃣"]),
          children: [
            TestItem(
              id: "MyTests/testMyLibrary()",
              label: "testMyLibrary()",
              location: Location(uri: uri, range: positions["2️⃣"]..<positions["3️⃣"]),
              children: [],
              tags: []
            )
          ],
          tags: []
        )
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

        1️⃣class MyTests: LooksLikeTestCaseButIsNot {
          2️⃣func testMyLibrary() {}3️⃣
          func unrelatedFunc() {}
          var testVariable: Int = 0
        }4️⃣
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
        TestItem(
          id: "MyTests",
          label: "MyTests",
          location: Location(uri: uri, range: positions["1️⃣"]..<positions["4️⃣"]),
          children: [
            TestItem(
              id: "MyTests/testMyLibrary()",
              label: "testMyLibrary()",
              location: Location(uri: uri, range: positions["2️⃣"]..<positions["3️⃣"]),
              children: [],
              tags: []
            )
          ],
          tags: []
        )
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
