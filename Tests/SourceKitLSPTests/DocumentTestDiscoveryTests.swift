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
import SourceKitLSP
import XCTest

final class DocumentTestDiscoveryTests: XCTestCase {
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
        let package = Package(
          name: "MyLibrary",
          targets: [.testTarget(name: "MyLibraryTests")]
        )
        """,
      enableBackgroundIndexing: true
    )

    let (uri, positions) = try project.openDocument("MyTests.swift")
    let tests = try await project.testClient.send(DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri)))
    XCTAssertEqual(
      tests,
      [
        TestItem(
          id: "MyTests",
          label: "MyTests",
          disabled: false,
          style: TestStyle.xcTest,
          location: Location(uri: uri, range: positions["1️⃣"]..<positions["4️⃣"]),
          children: [
            TestItem(
              id: "MyTests/testMyLibrary()",
              label: "testMyLibrary()",
              disabled: false,
              style: TestStyle.xcTest,
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
    let uri = DocumentURI(for: .swift)

    let positions = testClient.openDocument(
      """
      import XCTest

      1️⃣class MyTests: XCTestCase {
        2️⃣func testMyLibrary() {}3️⃣
        func testWithAnArgument(x: Int) {}
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
          disabled: false,
          style: TestStyle.xcTest,
          location: Location(uri: uri, range: positions["1️⃣"]..<positions["4️⃣"]),
          children: [
            TestItem(
              id: "MyTests/testMyLibrary()",
              label: "testMyLibrary()",
              disabled: false,
              style: TestStyle.xcTest,
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
          disabled: false,
          style: TestStyle.xcTest,
          location: Location(uri: uri, range: positions["1️⃣"]..<positions["4️⃣"]),
          children: [
            TestItem(
              id: "MyTests/testMyLibrary()",
              label: "testMyLibrary()",
              disabled: false,
              style: TestStyle.xcTest,
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
    _ = try await project.testClient.send(PollIndexRequest())

    // After indexing, we know that `LooksLikeTestCaseButIsNot` does not inherit from `XCTestCase` and we don't report any tests.
    let indexBasedTests = try await project.testClient.send(
      DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri))
    )
    XCTAssertEqual(indexBasedTests, [])
  }

  func testSwiftTestingDocumentTests() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)

    let positions = testClient.openDocument(
      """
      import Testing

      1️⃣struct MyTests {
        2️⃣@Test
        func oneIsTwo() {
          #expect(1 == 2)
        }3️⃣
      }4️⃣
      """,
      uri: uri
    )

    let tests = try await testClient.send(DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri)))
    XCTAssertEqual(
      tests,
      [
        TestItem(
          id: "MyTests/test.swift:2:0",
          label: "MyTests",
          disabled: false,
          style: TestStyle.swiftTesting,
          location: Location(uri: uri, range: positions["1️⃣"]..<positions["4️⃣"]),
          children: [
            TestItem(
              id: "MyTests/oneIsTwo()/test.swift:3:2",
              label: "oneIsTwo()",
              disabled: false,
              style: TestStyle.swiftTesting,
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

  func testSwiftTestingDocumentTestsInIndexedProject() async throws {
    let project = try await IndexedSingleSwiftFileTestProject(
      """
      import Testing

      1️⃣struct MyTests {
        2️⃣@Test
        func oneIsTwo() {
          #expect(1 == 2)
        }3️⃣
      }4️⃣
      """,
      allowBuildFailure: true
    )

    let tests = try await project.testClient.send(
      DocumentTestsRequest(textDocument: TextDocumentIdentifier(project.fileURI))
    )
    XCTAssertEqual(
      tests,
      [
        TestItem(
          id: "MyTests/test.swift:2:0",
          label: "MyTests",
          disabled: false,
          style: TestStyle.swiftTesting,
          location: Location(uri: project.fileURI, range: project.positions["1️⃣"]..<project.positions["4️⃣"]),
          children: [
            TestItem(
              id: "MyTests/oneIsTwo()/test.swift:3:2",
              label: "oneIsTwo()",
              disabled: false,
              style: TestStyle.swiftTesting,
              location: Location(uri: project.fileURI, range: project.positions["2️⃣"]..<project.positions["3️⃣"]),
              children: [],
              tags: []
            )
          ],
          tags: []
        )
      ]
    )
  }

  func testNestedSwiftTestingSuites() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)

    let positions = testClient.openDocument(
      """
      import Testing

      1️⃣struct MyTests {
        2️⃣struct Inner {
          3️⃣@Test
          func oneIsTwo() {
            #expect(1 == 2)
          }4️⃣
        }5️⃣
      }6️⃣
      """,
      uri: uri
    )

    let tests = try await testClient.send(DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri)))
    XCTAssertEqual(
      tests,
      [
        TestItem(
          id: "MyTests/test.swift:2:0",
          label: "MyTests",
          disabled: false,
          style: TestStyle.swiftTesting,
          location: Location(uri: uri, range: positions["1️⃣"]..<positions["6️⃣"]),
          children: [
            TestItem(
              id: "MyTests/Inner/test.swift:3:2",
              label: "Inner",
              disabled: false,
              style: TestStyle.swiftTesting,
              location: Location(uri: uri, range: positions["2️⃣"]..<positions["5️⃣"]),
              children: [
                TestItem(
                  id: "MyTests/Inner/oneIsTwo()/test.swift:4:4",
                  label: "oneIsTwo()",
                  disabled: false,
                  style: TestStyle.swiftTesting,
                  location: Location(uri: uri, range: positions["3️⃣"]..<positions["4️⃣"]),
                  children: [],
                  tags: []
                )
              ],
              tags: []
            )
          ],
          tags: []
        )
      ]
    )
  }

  func testParameterizedSwiftTestingTest() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)

    let positions = testClient.openDocument(
      """
      import Testing

      1️⃣struct MyTests {
        2️⃣@Test(arguments: [0, 1, 2])
        func numbersAreOne(x: Int) {
          #expect(x == 1)
        }3️⃣
      }4️⃣
      """,
      uri: uri
    )

    let tests = try await testClient.send(DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri)))
    XCTAssertEqual(
      tests,
      [
        TestItem(
          id: "MyTests/test.swift:2:0",
          label: "MyTests",
          disabled: false,
          style: TestStyle.swiftTesting,
          location: Location(uri: uri, range: positions["1️⃣"]..<positions["4️⃣"]),
          children: [
            TestItem(
              id: "MyTests/numbersAreOne(x:)/test.swift:3:2",
              label: "numbersAreOne(x:)",
              disabled: false,
              style: TestStyle.swiftTesting,
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

  func testParameterizedSwiftTestingTestWithAnonymousArgument() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)

    let positions = testClient.openDocument(
      """
      import Testing

      1️⃣struct MyTests {
        2️⃣@Test(arguments: [0, 1, 2])
        func numbersAreOne(_ x: Int) {
          #expect(x == 1)
        }3️⃣
      }4️⃣
      """,
      uri: uri
    )

    let tests = try await testClient.send(DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri)))
    XCTAssertEqual(
      tests,
      [
        TestItem(
          id: "MyTests/test.swift:2:0",
          label: "MyTests",
          disabled: false,
          style: TestStyle.swiftTesting,
          location: Location(uri: uri, range: positions["1️⃣"]..<positions["4️⃣"]),
          children: [
            TestItem(
              id: "MyTests/numbersAreOne(_:)/test.swift:3:2",
              label: "numbersAreOne(_:)",
              disabled: false,
              style: TestStyle.swiftTesting,
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

  func testParameterizedSwiftTestingTestWithCommentInSignature() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)

    let positions = testClient.openDocument(
      """
      import Testing

      1️⃣struct MyTests {
        2️⃣@Test(arguments: [0, 1, 2])
        func numbersAreOne(x /* hello */: Int) {
          #expect(x == 1)
        }3️⃣
      }4️⃣
      """,
      uri: uri
    )

    let tests = try await testClient.send(DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri)))
    XCTAssertEqual(
      tests,
      [
        TestItem(
          id: "MyTests/test.swift:2:0",
          label: "MyTests",
          disabled: false,
          style: TestStyle.swiftTesting,
          location: Location(uri: uri, range: positions["1️⃣"]..<positions["4️⃣"]),
          children: [
            TestItem(
              id: "MyTests/numbersAreOne(x:)/test.swift:3:2",
              label: "numbersAreOne(x:)",
              disabled: false,
              style: TestStyle.swiftTesting,
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

  func testSwiftTestingSuiteWithNoTests() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)

    let positions = testClient.openDocument(
      """
      import Testing

      1️⃣@Suite
      struct MyTests {
      }2️⃣
      """,
      uri: uri
    )

    let tests = try await testClient.send(DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri)))
    XCTAssertEqual(
      tests,
      [
        TestItem(
          id: "MyTests/test.swift:2:0",
          label: "MyTests",
          disabled: false,
          style: TestStyle.swiftTesting,
          location: Location(uri: uri, range: positions["1️⃣"]..<positions["2️⃣"]),
          children: [],
          tags: []
        )
      ]
    )
  }

  func testSwiftTestingSuiteWithCustomName() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)

    let positions = testClient.openDocument(
      """
      import Testing

      1️⃣@Suite("My tests")
      struct MyTests {
      }2️⃣
      """,
      uri: uri
    )

    let tests = try await testClient.send(DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri)))
    XCTAssertEqual(
      tests,
      [
        TestItem(
          id: "MyTests/test.swift:2:0",
          label: "My tests",
          disabled: false,
          style: TestStyle.swiftTesting,
          location: Location(uri: uri, range: positions["1️⃣"]..<positions["2️⃣"]),
          children: [],
          tags: []
        )
      ]
    )
  }

  func testSwiftTestingTestWithCustomName() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)

    let positions = testClient.openDocument(
      """
      import Testing

      1️⃣@Test("One is two")
      func oneIsTwo() {
        #expect(1 == 2)
      }2️⃣
      """,
      uri: uri
    )

    let tests = try await testClient.send(DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri)))
    XCTAssertEqual(
      tests,
      [
        TestItem(
          id: "oneIsTwo()/test.swift:2:0",
          label: "One is two",
          disabled: false,
          style: TestStyle.swiftTesting,
          location: Location(uri: uri, range: positions["1️⃣"]..<positions["2️⃣"]),
          children: [],
          tags: []
        )
      ]
    )
  }

  func testSwiftTestingTestWithBackticksInName() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)

    let positions = testClient.openDocument(
      """
      import Testing

      1️⃣struct `MyTests` {
        2️⃣@Test
        func `oneIsTwo`(`foo`: Int) {
          #expect(1 == 2)
        }3️⃣
      }4️⃣

      5️⃣extension `MyTests` {
        6️⃣@Test
        func `twoIsThree`() {
          #expect(2 == 3)
        }7️⃣
      }8️⃣
      """,
      uri: uri
    )

    let tests = try await testClient.send(DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri)))
    XCTAssertEqual(
      tests,
      [
        TestItem(
          id: "MyTests/test.swift:2:0",
          label: "MyTests",
          disabled: false,
          style: TestStyle.swiftTesting,
          location: Location(uri: uri, range: positions["1️⃣"]..<positions["4️⃣"]),
          children: [
            TestItem(
              id: "MyTests/oneIsTwo(foo:)/test.swift:3:2",
              label: "oneIsTwo(foo:)",
              disabled: false,
              style: TestStyle.swiftTesting,
              location: Location(uri: uri, range: positions["2️⃣"]..<positions["3️⃣"]),
              children: [],
              tags: []
            )
          ],
          tags: []
        ),
        TestItem(
          id: "MyTests/test.swift:9:0",
          label: "MyTests",
          disabled: false,
          style: TestStyle.swiftTesting,
          location: Location(uri: uri, range: positions["5️⃣"]..<positions["8️⃣"]),
          children: [
            TestItem(
              id: "MyTests/twoIsThree()/test.swift:10:2",
              label: "twoIsThree()",
              disabled: false,
              style: TestStyle.swiftTesting,
              location: Location(uri: uri, range: positions["6️⃣"]..<positions["7️⃣"]),
              children: [],
              tags: []
            )
          ],
          tags: []
        ),
      ]
    )
  }

  func testDisabledSwiftTestingTest() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)

    let positions = testClient.openDocument(
      """
      import Testing

      1️⃣@Test("One is two", .disabled())
      func oneIsTwo() {
        #expect(1 == 2)
      }2️⃣
      """,
      uri: uri
    )

    let tests = try await testClient.send(DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri)))
    XCTAssertEqual(
      tests,
      [
        TestItem(
          id: "oneIsTwo()/test.swift:2:0",
          label: "One is two",
          disabled: true,
          style: TestStyle.swiftTesting,
          location: Location(uri: uri, range: positions["1️⃣"]..<positions["2️⃣"]),
          children: [],
          tags: []
        )
      ]
    )
  }

  func testSwiftTestingTestInDisabledSuite() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)

    let positions = testClient.openDocument(
      """
      import Testing

      1️⃣@Suite(.disabled())
      struct MyTests {
        2️⃣@Test
        func oneIsTwo() {
          #expect(1 == 2)
        }3️⃣
      }4️⃣
      """,
      uri: uri
    )

    let tests = try await testClient.send(DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri)))
    XCTAssertEqual(
      tests,
      [
        TestItem(
          id: "MyTests/test.swift:2:0",
          label: "MyTests",
          disabled: true,
          style: TestStyle.swiftTesting,
          location: Location(uri: uri, range: positions["1️⃣"]..<positions["4️⃣"]),
          children: [
            TestItem(
              id: "MyTests/oneIsTwo()/test.swift:4:2",
              label: "oneIsTwo()",
              disabled: true,
              style: TestStyle.swiftTesting,
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

  func testHiddenSwiftTestingTest() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)

    testClient.openDocument(
      """
      import Testing

      @Test("One is two", .hidden)
      func oneIsTwo() {
        #expect(1 == 2)
      }
      """,
      uri: uri
    )

    let tests = try await testClient.send(DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri)))
    XCTAssertEqual(
      tests,
      []
    )
  }

  func testSwiftTestingTestWithTags() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)

    let positions = testClient.openDocument(
      """
      import Testing

      1️⃣@Suite(.tags(.green))
      struct MyTests {
        2️⃣@Test(.tags(.red, .blue))
        func oneIsTwo() {
          #expect(1 == 2)
        }3️⃣
      }4️⃣
      """,
      uri: uri
    )

    let tests = try await testClient.send(DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri)))
    XCTAssertEqual(
      tests,
      [
        TestItem(
          id: "MyTests/test.swift:2:0",
          label: "MyTests",
          disabled: false,
          style: TestStyle.swiftTesting,
          location: Location(uri: uri, range: positions["1️⃣"]..<positions["4️⃣"]),
          children: [
            TestItem(
              id: "MyTests/oneIsTwo()/test.swift:4:2",
              label: "oneIsTwo()",
              disabled: false,
              style: TestStyle.swiftTesting,
              location: Location(uri: uri, range: positions["2️⃣"]..<positions["3️⃣"]),
              children: [],
              tags: [TestTag(id: "red"), TestTag(id: "blue")]
            )
          ],
          tags: [TestTag(id: "green")]
        )
      ]
    )
  }

  func testSwiftTestingTestWithCustomTags() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)

    let positions = testClient.openDocument(
      """
      import Testing

      extension Tag {
        @Tag static var suite: Self
        @Tag static var foo: Self
        @Tag static var bar: Self
        @Tag static var baz: Self

        struct Nested {
          @Tag static var foo: Tag
        }
      }

      1️⃣@Suite(.tags(.suite))
      struct MyTests {
        2️⃣@Test(.tags(.foo, Nested.foo, Testing.Tag.bar, Tag.baz))
        func oneIsTwo() {
          #expect(1 == 2)
        }3️⃣
      }4️⃣
      """,
      uri: uri
    )

    let tests = try await testClient.send(DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri)))
    XCTAssertEqual(
      tests,
      [
        TestItem(
          id: "MyTests/test.swift:13:0",
          label: "MyTests",
          disabled: false,
          style: TestStyle.swiftTesting,
          location: Location(uri: uri, range: positions["1️⃣"]..<positions["4️⃣"]),
          children: [
            TestItem(
              id: "MyTests/oneIsTwo()/test.swift:15:2",
              label: "oneIsTwo()",
              disabled: false,
              style: TestStyle.swiftTesting,
              location: Location(uri: uri, range: positions["2️⃣"]..<positions["3️⃣"]),
              children: [],
              tags: [
                TestTag(id: "foo"),
                TestTag(id: "Nested.foo"),
                TestTag(id: "bar"),
                TestTag(id: "baz"),
              ]
            )
          ],
          tags: [TestTag(id: "suite")]
        )
      ]
    )
  }

  func testSwiftTestingTestsWithExtension() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)

    let positions = testClient.openDocument(
      """
      import Testing

      1️⃣struct MyTests {
        2️⃣@Test
        func oneIsTwo() {
          #expect(1 == 2)
        }3️⃣
      }4️⃣

      5️⃣extension MyTests {
        6️⃣@Test
        func twoIsThree() {
          #expect(2 == 3)
        }7️⃣
      }8️⃣
      """,
      uri: uri
    )

    let tests = try await testClient.send(DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri)))
    XCTAssertEqual(
      tests,
      [
        TestItem(
          id: "MyTests/test.swift:2:0",
          label: "MyTests",
          disabled: false,
          style: TestStyle.swiftTesting,
          location: Location(uri: uri, range: positions["1️⃣"]..<positions["4️⃣"]),
          children: [
            TestItem(
              id: "MyTests/oneIsTwo()/test.swift:3:2",
              label: "oneIsTwo()",
              disabled: false,
              style: TestStyle.swiftTesting,
              location: Location(uri: uri, range: positions["2️⃣"]..<positions["3️⃣"]),
              children: [],
              tags: []
            )
          ],
          tags: []
        ),
        TestItem(
          id: "MyTests/test.swift:9:0",
          label: "MyTests",
          disabled: false,
          style: TestStyle.swiftTesting,
          location: Location(uri: uri, range: positions["5️⃣"]..<positions["8️⃣"]),
          children: [
            TestItem(
              id: "MyTests/twoIsThree()/test.swift:10:2",
              label: "twoIsThree()",
              disabled: false,
              style: TestStyle.swiftTesting,
              location: Location(uri: uri, range: positions["6️⃣"]..<positions["7️⃣"]),
              children: [],
              tags: []
            )
          ],
          tags: []
        ),
      ]
    )
  }

  func testSwiftTestingTestSuitesWithExtension() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)

    let positions = testClient.openDocument(
      """
      import XCTest

      1️⃣@Suite struct MyTests {
        2️⃣@Test func oneIsTwo() {}3️⃣
      }4️⃣

      5️⃣extension MyTests {
        6️⃣@Test func twoIsThree() {}7️⃣
      }8️⃣
      """,
      uri: uri
    )

    let tests = try await testClient.send(DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri)))
    XCTAssertEqual(
      tests,
      [
        TestItem(
          id: "MyTests/test.swift:2:0",
          label: "MyTests",
          disabled: false,
          style: TestStyle.swiftTesting,
          location: Location(uri: uri, range: positions["1️⃣"]..<positions["4️⃣"]),
          children: [
            TestItem(
              id: "MyTests/oneIsTwo()/test.swift:3:2",
              label: "oneIsTwo()",
              disabled: false,
              style: TestStyle.swiftTesting,
              location: Location(uri: uri, range: positions["2️⃣"]..<positions["3️⃣"]),
              children: [],
              tags: []
            )
          ],
          tags: []
        ),
        TestItem(
          id: "MyTests/test.swift:6:0",
          label: "MyTests",
          disabled: false,
          style: TestStyle.swiftTesting,
          location: Location(uri: uri, range: positions["5️⃣"]..<positions["8️⃣"]),
          children: [
            TestItem(
              id: "MyTests/twoIsThree()/test.swift:7:2",
              label: "twoIsThree()",
              disabled: false,
              style: TestStyle.swiftTesting,
              location: Location(uri: uri, range: positions["6️⃣"]..<positions["7️⃣"]),
              children: [],
              tags: []
            )
          ],
          tags: []
        ),
      ]
    )
  }

  func testXCTestTestsWithExtension() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)

    let positions = testClient.openDocument(
      """
      import XCTest

      1️⃣final class MyTests: XCTestCase {}2️⃣

      extension MyTests {
        3️⃣func testOneIsTwo() {}4️⃣
      }
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
          disabled: false,
          style: TestStyle.xcTest,
          location: Location(uri: uri, range: positions["1️⃣"]..<positions["2️⃣"]),
          children: [
            TestItem(
              id: "MyTests/testOneIsTwo()",
              label: "testOneIsTwo()",
              disabled: false,
              style: TestStyle.xcTest,
              location: Location(uri: uri, range: positions["3️⃣"]..<positions["4️⃣"]),
              children: [],
              tags: []
            )
          ],
          tags: []
        )
      ]
    )
  }

  func testSwiftTestingNestedTestSuiteWithExtension() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)

    let positions = testClient.openDocument(
      """
      import Testing

      1️⃣@Suite struct Outer {
        3️⃣@Suite struct Inner {
          5️⃣@Test func oneIsTwo {}6️⃣
        }4️⃣
      }2️⃣

      7️⃣extension Outer.Inner {
        8️⃣@Test func twoIsThree() {}9️⃣
      }🔟
      """,
      uri: uri
    )

    let tests = try await testClient.send(DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri)))
    XCTAssertEqual(
      tests,
      [
        TestItem(
          id: "Outer/test.swift:2:0",
          label: "Outer",
          disabled: false,
          style: TestStyle.swiftTesting,
          location: Location(uri: uri, range: positions["1️⃣"]..<positions["2️⃣"]),
          children: [
            TestItem(
              id: "Outer/Inner/test.swift:3:2",
              label: "Inner",
              disabled: false,
              style: TestStyle.swiftTesting,
              location: Location(uri: uri, range: positions["3️⃣"]..<positions["4️⃣"]),
              children: [
                TestItem(
                  id: "Outer/Inner/oneIsTwo()/test.swift:4:4",
                  label: "oneIsTwo()",
                  disabled: false,
                  style: TestStyle.swiftTesting,
                  location: Location(uri: uri, range: positions["5️⃣"]..<positions["6️⃣"]),
                  children: [],
                  tags: []
                )
              ],
              tags: []
            )
          ],
          tags: []
        ),
        TestItem(
          id: "Outer/Inner/test.swift:8:0",
          label: "Inner",
          disabled: false,
          style: TestStyle.swiftTesting,
          location: Location(uri: uri, range: positions["7️⃣"]..<positions["🔟"]),
          children: [
            TestItem(
              id: "Outer/Inner/twoIsThree()/test.swift:9:2",
              label: "twoIsThree()",
              disabled: false,
              style: TestStyle.swiftTesting,
              location: Location(uri: uri, range: positions["8️⃣"]..<positions["9️⃣"]),
              children: [],
              tags: []
            )
          ],
          tags: []
        ),
      ]
    )
  }

  func testSwiftTestingExtensionOfTypeInAnotherFile() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)

    let positions = testClient.openDocument(
      """
      import Testing

      1️⃣extension MyTests {
        2️⃣@Test
        func oneIsTwo() {
          #expect(1 == 2)
        }3️⃣
      }4️⃣
      """,
      uri: uri
    )

    let tests = try await testClient.send(DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri)))
    XCTAssertEqual(
      tests,
      [
        TestItem(
          id: "MyTests/test.swift:2:0",
          label: "MyTests",
          disabled: false,
          style: TestStyle.swiftTesting,
          location: Location(uri: uri, range: positions["1️⃣"]..<positions["4️⃣"]),
          children: [
            TestItem(
              id: "MyTests/oneIsTwo()/test.swift:3:2",
              label: "oneIsTwo()",
              disabled: false,
              style: TestStyle.swiftTesting,
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

  func testSwiftTestingExtensionOfNestedType() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)

    let positions = testClient.openDocument(
      """
      import Testing

      struct MyTests {
        struct Inner {}
      }

      1️⃣extension MyTests.Inner {
        2️⃣@Test
        func oneIsTwo() {
          #expect(1 == 2)
        }3️⃣
      }4️⃣
      """,
      uri: uri
    )

    let tests = try await testClient.send(DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri)))
    XCTAssertEqual(
      tests,
      [
        TestItem(
          id: "MyTests/Inner/test.swift:6:0",
          label: "Inner",
          disabled: false,
          style: TestStyle.swiftTesting,
          location: Location(uri: uri, range: positions["1️⃣"]..<positions["4️⃣"]),
          children: [
            TestItem(
              id: "MyTests/Inner/oneIsTwo()/test.swift:7:2",
              label: "oneIsTwo()",
              disabled: false,
              style: TestStyle.swiftTesting,
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

  func testSwiftTestingTwoExtensionsNoDeclaration() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)

    let positions = testClient.openDocument(
      """
      import Testing

      1️⃣extension MyTests {
        3️⃣@Test func oneIsTwo() {}4️⃣
      }2️⃣

      5️⃣extension MyTests {
        6️⃣@Test func twoIsThree() {}7️⃣
      }8️⃣
      """,
      uri: uri
    )

    let tests = try await testClient.send(DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri)))
    XCTAssertEqual(
      tests,
      [
        TestItem(
          id: "MyTests/test.swift:2:0",
          label: "MyTests",
          disabled: false,
          style: TestStyle.swiftTesting,
          location: Location(uri: uri, range: positions["1️⃣"]..<positions["2️⃣"]),
          children: [
            TestItem(
              id: "MyTests/oneIsTwo()/test.swift:3:2",
              label: "oneIsTwo()",
              disabled: false,
              style: TestStyle.swiftTesting,
              location: Location(uri: uri, range: positions["3️⃣"]..<positions["4️⃣"]),
              children: [],
              tags: []
            )
          ],
          tags: []
        ),
        TestItem(
          id: "MyTests/test.swift:6:0",
          label: "MyTests",
          disabled: false,
          style: TestStyle.swiftTesting,
          location: Location(uri: uri, range: positions["5️⃣"]..<positions["8️⃣"]),
          children: [
            TestItem(
              id: "MyTests/twoIsThree()/test.swift:7:2",
              label: "twoIsThree()",
              disabled: false,
              style: TestStyle.swiftTesting,
              location: Location(uri: uri, range: positions["6️⃣"]..<positions["7️⃣"]),
              children: [],
              tags: []
            )
          ],
          tags: []
        ),
      ]
    )
  }

  func testFullyQualifySwiftTestingTestAttribute() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI(for: .swift)

    let positions = testClient.openDocument(
      """
      import Testing

      1️⃣@Testing.Suite("My Tests")
      struct MyTests {
        2️⃣@Testing.Test("one is two")
        func oneIsTwo() {
          #expect(1 == 2)
        }3️⃣
      }4️⃣
      """,
      uri: uri
    )

    let tests = try await testClient.send(DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri)))
    XCTAssertEqual(
      tests,
      [
        TestItem(
          id: "MyTests/test.swift:2:0",
          label: "My Tests",
          disabled: false,
          style: TestStyle.swiftTesting,
          location: Location(uri: uri, range: positions["1️⃣"]..<positions["4️⃣"]),
          children: [
            TestItem(
              id: "MyTests/oneIsTwo()/test.swift:4:2",
              label: "one is two",
              disabled: false,
              style: TestStyle.swiftTesting,
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

  func testAddNewMethodToNotQuiteTestCase() async throws {
    let project = try await IndexedSingleSwiftFileTestProject(
      """
      import XCTest

      class NotQuiteTest: SomeClass {
        func testMyLibrary() {}
      2️⃣
      }
      """,
      allowBuildFailure: true
    )

    let testsBeforeEdit = try await project.testClient.send(
      DocumentTestsRequest(textDocument: TextDocumentIdentifier(project.fileURI))
    )
    XCTAssertEqual(testsBeforeEdit, [])
    project.testClient.send(
      DidChangeTextDocumentNotification(
        textDocument: VersionedTextDocumentIdentifier(project.fileURI, version: 2),
        contentChanges: [
          TextDocumentContentChangeEvent(range: Range(project.positions["2️⃣"]), text: "func testSomethingElse() {}")
        ]
      )
    )
    let testsAfterEdit = try await project.testClient.send(
      DocumentTestsRequest(textDocument: TextDocumentIdentifier(project.fileURI))
    )
    XCTAssertEqual(testsAfterEdit, [])
  }

  func testAddNewClassToNotQuiteTestCase() async throws {
    let project = try await IndexedSingleSwiftFileTestProject(
      """
      import XCTest

      class NotQuiteTest: SomeClass {
        func testMyLibrary() {}
      }
      2️⃣
      """,
      allowBuildFailure: true
    )

    let testsBeforeEdit = try await project.testClient.send(
      DocumentTestsRequest(textDocument: TextDocumentIdentifier(project.fileURI))
    )
    XCTAssertEqual(testsBeforeEdit, [])
    project.testClient.send(
      DidChangeTextDocumentNotification(
        textDocument: VersionedTextDocumentIdentifier(project.fileURI, version: 2),
        contentChanges: [
          TextDocumentContentChangeEvent(
            range: Range(project.positions["2️⃣"]),
            text: """
              class OtherNotQuiteTest: SomeClass {
                func testSomethingElse() {}
              }
              """
          )
        ]
      )
    )
    let testsAfterEdit = try await project.testClient.send(
      DocumentTestsRequest(textDocument: TextDocumentIdentifier(project.fileURI))
    )
    // We know from the semantic index that NotQuiteTest does not inherit from XCTestCase, so we should not include it.
    // We don't have any semantic knowledge about `OtherNotQuiteTest`, so we are conservative and should include it.
    XCTAssertFalse(testsAfterEdit.contains { $0.label == "NotQuiteTest" })
    XCTAssertTrue(testsAfterEdit.contains { $0.label == "OtherNotQuiteTest" })
  }

  func testObjectiveCTestFromSemanticIndex() async throws {
    try SkipUnless.platformIsDarwin("Non-Darwin platforms don't support Objective-C")

    let project = try await SwiftPMTestProject(
      files: [
        "Tests/MyLibraryTests/Test.m": """
        #import <XCTest/XCTest.h>

        @interface MyTests : XCTestCase
        @end

        1️⃣@implementation MyTests
        2️⃣- (void)testSomething {
        }3️⃣
        @4️⃣end
        """
      ],
      manifest: """
        let package = Package(
          name: "MyLibrary",
          targets: [.testTarget(name: "MyLibraryTests")]
        )
        """,
      enableBackgroundIndexing: true
    )

    let (uri, positions) = try project.openDocument("Test.m")

    let tests = try await project.testClient.send(DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri)))

    XCTAssertEqual(
      tests,
      [
        TestItem(
          id: "MyTests",
          label: "MyTests",
          disabled: false,
          style: TestStyle.xcTest,
          location: Location(uri: uri, range: positions["1️⃣"]..<positions["4️⃣"]),
          children: [
            TestItem(
              id: "MyTests/testSomething",
              label: "testSomething",
              disabled: false,
              style: TestStyle.xcTest,
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

  func testObjectiveCTestsAfterInMemoryEdit() async throws {
    try SkipUnless.platformIsDarwin("Non-Darwin platforms don't support Objective-C")
    let project = try await SwiftPMTestProject(
      files: [
        "Tests/MyLibraryTests/Test.m": """
        #import <XCTest/XCTest.h>

        @interface MyTests : XCTestCase
        @end

        1️⃣@implementation MyTests
        2️⃣- (void)testSomething {}3️⃣
        0️⃣
        @4️⃣end
        """
      ],
      manifest: """
        let package = Package(
          name: "MyLibrary",
          targets: [.testTarget(name: "MyLibraryTests")]
        )
        """,
      enableBackgroundIndexing: true
    )

    let (uri, positions) = try project.openDocument("Test.m")

    project.testClient.send(
      DidChangeTextDocumentNotification(
        textDocument: VersionedTextDocumentIdentifier(uri, version: 2),
        contentChanges: [
          TextDocumentContentChangeEvent(
            range: Range(positions["0️⃣"]),
            text: """
              - (void)testSomethingElse {}
              """
          )
        ]
      )
    )

    let tests = try await project.testClient.send(DocumentTestsRequest(textDocument: TextDocumentIdentifier(uri)))
    // Since we don't have syntactic test discovery for clang-languages, we don't discover `testSomethingElse` as a
    // test method until we perform a build
    XCTAssertEqual(
      tests,
      [
        TestItem(
          id: "MyTests",
          label: "MyTests",
          disabled: false,
          style: TestStyle.xcTest,
          location: Location(uri: uri, range: positions["1️⃣"]..<positions["4️⃣"]),
          children: [
            TestItem(
              id: "MyTests/testSomething",
              label: "testSomething",
              disabled: false,
              style: TestStyle.xcTest,
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
}
