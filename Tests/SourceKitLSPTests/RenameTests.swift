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

final class RenameTests: XCTestCase {
  func testRenameVariableBaseName() async throws {
    try await assertSingleFileRename(
      """
      let 1️⃣foo = 1
      print(2️⃣foo)
      """,
      newName: "bar",
      expectedPrepareRenamePlaceholder: "foo",
      expected: """
        let bar = 1
        print(bar)
        """
    )
  }

  func testRenameFunctionBaseName() async throws {
    try await assertSingleFileRename(
      """
      func 1️⃣foo() {}
      2️⃣foo()
      _ = 3️⃣foo
      """,
      newName: "bar()",
      expectedPrepareRenamePlaceholder: "foo()",
      expected: """
        func bar() {}
        bar()
        _ = bar
        """
    )
  }

  func testRenameFunctionParameter() async throws {
    try await assertSingleFileRename(
      """
      func 1️⃣foo(5️⃣x: Int) {}
      2️⃣foo(6️⃣x: 1)
      _ = 3️⃣foo(7️⃣x:)
      _ = 4️⃣foo
      """,
      newName: "bar(y:)",
      expectedPrepareRenamePlaceholder: "foo(x:)",
      expected: """
        func bar(y: Int) {}
        bar(y: 1)
        _ = bar(y:)
        _ = bar
        """
    )
  }

  func testFoo() async throws {
    try await assertSingleFileRename(
      """
      func foo(5️⃣x: Int) {}
      foo(x: 1)
      _ = foo(x:)
      _ = foo
      """,
      newName: "bar(y:)",
      expectedPrepareRenamePlaceholder: "foo(x:)",
      expected: """
        func bar(y: Int) {}
        bar(y: 1)
        _ = bar(y:)
        _ = bar
        """
    )
  }

  func testSecondParameterNameIfMatches() async throws {
    try await assertSingleFileRename(
      """
      func 1️⃣foo(4️⃣x y: Int) {}
      2️⃣foo(5️⃣x: 1)
      _ = 3️⃣foo(6️⃣x:)
      """,
      newName: "foo(y:)",
      expectedPrepareRenamePlaceholder: "foo(x:)",
      expected: """
        func foo(y: Int) {}
        foo(y: 1)
        _ = foo(y:)
        """
    )
  }

  func testIntroduceLabel() async throws {
    try await assertSingleFileRename(
      """
      func 1️⃣foo(4️⃣_ y: Int) {}
      2️⃣foo(1)
      _ = 3️⃣foo(5️⃣_:)
      """,
      newName: "foo(y:)",
      expectedPrepareRenamePlaceholder: "foo(_:)",
      expected: """
        func foo(y: Int) {}
        foo(y: 1)
        _ = foo(y:)
        """
    )
  }

  func testRemoveLabel() async throws {
    try await assertSingleFileRename(
      """
      func 1️⃣foo(4️⃣x: Int) {}
      2️⃣foo(5️⃣x: 1)
      _ = 3️⃣foo(6️⃣x:)
      """,
      newName: "foo(_:)",
      expectedPrepareRenamePlaceholder: "foo(x:)",
      expected: """
        func foo(_ x: Int) {}
        foo(1)
        _ = foo(_:)
        """
    )
  }

  func testRemoveLabelWithExistingInternalName() async throws {
    try await assertSingleFileRename(
      """
      func 1️⃣foo(4️⃣x a: Int) {}
      2️⃣foo(5️⃣x: 1)
      _ = 3️⃣foo(6️⃣x:)
      """,
      newName: "foo(_:)",
      expectedPrepareRenamePlaceholder: "foo(x:)",
      expected: """
        func foo(_ a: Int) {}
        foo(1)
        _ = foo(_:)
        """
    )
  }

  func testRenameSubscript() async throws {
    try await assertSingleFileRename(
      """
      struct Foo {
        1️⃣subscript(3️⃣x x: Int) -> Int { x }
      }
      Foo()2️⃣[4️⃣x: 1]
      """,
      newName: "subscript(y:)",
      expectedPrepareRenamePlaceholder: "subscript(x:)",
      expected: """
        struct Foo {
          subscript(y x: Int) -> Int { x }
        }
        Foo()[y: 1]
        """
    )
  }

  func testRemoveExternalLabelFromSubscript() async throws {
    try await assertSingleFileRename(
      """
      struct Foo {
        1️⃣subscript(3️⃣x x: Int) -> Int { x }
      }
      Foo()2️⃣[4️⃣x: 1]
      """,
      newName: "subscript(_:)",
      expectedPrepareRenamePlaceholder: "subscript(x:)",
      expected: """
        struct Foo {
          subscript(_ x: Int) -> Int { x }
        }
        Foo()[1]
        """
    )
  }

  func testIntroduceExternalLabelFromSubscript() async throws {
    try await assertSingleFileRename(
      """
      struct Foo {
        1️⃣subscript(3️⃣x: Int) -> Int { x }
      }
      Foo()2️⃣[1]
      """,
      newName: "subscript(x:)",
      expectedPrepareRenamePlaceholder: "subscript(_:)",
      expected: """
        struct Foo {
          subscript(x x: Int) -> Int { x }
        }
        Foo()[x: 1]
        """
    )
  }

  func testIgnoreRenameSubscriptBaseName() async throws {
    try await assertSingleFileRename(
      """
      struct Foo {
        1️⃣subscript(3️⃣x: Int) -> Int { x }
      }
      Foo()2️⃣[1]
      """,
      newName: "arrayAccess(x:)",
      expectedPrepareRenamePlaceholder: "subscript(_:)",
      expected: """
        struct Foo {
          subscript(x x: Int) -> Int { x }
        }
        Foo()[x: 1]
        """
    )
  }

  func testRenameInitializerLabels() async throws {
    try await assertSingleFileRename(
      """
      struct Foo {
        1️⃣init(4️⃣x: Int) {}
      }
      Foo(x: 1)
      Foo.2️⃣init(5️⃣x: 1)
      _ = Foo.3️⃣init(6️⃣x:)
      """,
      newName: "init(y:)",
      expectedPrepareRenamePlaceholder: "init(x:)",
      expected: """
        struct Foo {
          init(y: Int) {}
        }
        Foo(y: 1)
        Foo.init(y: 1)
        _ = Foo.init(y:)
        """
    )
  }

  func testIgnoreRenameOfInitBaseName() async throws {
    try await assertSingleFileRename(
      """
      struct Foo {
        1️⃣init(4️⃣x: Int) {}
      }
      Foo(5️⃣x: 1)
      Foo.2️⃣init(6️⃣x: 1)
      _ = Foo.3️⃣init(7️⃣x:)
      """,
      newName: "create(y:)",
      expectedPrepareRenamePlaceholder: "init(x:)",
      expected: """
        struct Foo {
          init(y: Int) {}
        }
        Foo(y: 1)
        Foo.init(y: 1)
        _ = Foo.init(y:)
        """
    )
  }

  func testRenameMultipleParameters() async throws {
    try await assertSingleFileRename(
      """
      func 1️⃣foo(4️⃣a: Int, 5️⃣b: Int) {}
      2️⃣foo(6️⃣a: 1, 7️⃣b: 1)
      _ = 3️⃣foo(8️⃣a:9️⃣b:)
      """,
      newName: "foo(x:y:)",
      expectedPrepareRenamePlaceholder: "foo(a:b:)",
      expected: """
        func foo(x: Int, y: Int) {}
        foo(x: 1, y: 1)
        _ = foo(x:y:)
        """
    )
  }

  func testDontRenameParametersOmittedFromNewName() async throws {
    try await assertSingleFileRename(
      """
      func 1️⃣foo(4️⃣a: Int, 5️⃣b: Int) {}
      2️⃣foo(6️⃣a: 1, 7️⃣b: 1)
      _ = 3️⃣foo(8️⃣a:9️⃣b:)
      """,
      newName: "foo(x:)",
      expectedPrepareRenamePlaceholder: "foo(a:b:)",
      expected: """
        func foo(x: Int, b: Int) {}
        foo(x: 1, b: 1)
        _ = foo(x:b:)
        """
    )
  }

  func testIgnoreAdditionalParametersInNewName() async throws {
    try await assertSingleFileRename(
      """
      func 1️⃣foo(4️⃣a: Int) {}
      2️⃣foo(5️⃣a: 1)
      _ = 3️⃣foo(6️⃣a:)
      """,
      newName: "foo(x:y:)",
      expectedPrepareRenamePlaceholder: "foo(a:)",
      expected: """
        func foo(x: Int) {}
        foo(x: 1)
        _ = foo(x:)
        """
    )
  }

  func testOnlySpecifyBaseNameWhenRenamingFunction() async throws {
    try await assertSingleFileRename(
      """
      func 1️⃣foo(4️⃣a: Int) {}
      2️⃣foo(5️⃣a: 1)
      _ = 3️⃣foo(6️⃣a:)
      """,
      newName: "bar",
      expectedPrepareRenamePlaceholder: "foo(a:)",
      expected: """
        func bar(a: Int) {}
        bar(a: 1)
        _ = bar(a:)
        """
    )
  }

  func testIgnoreParametersInNewNameWhenRenamingVariable() async throws {
    try await assertSingleFileRename(
      """
      let 1️⃣foo = 1
      _ = 2️⃣foo
      """,
      newName: "bar(x:y:)",
      expectedPrepareRenamePlaceholder: "foo",
      expected: """
        let bar = 1
        _ = bar
        """
    )
  }

  func testNewNameDoesntContainClosingParenthesis() async throws {
    try await assertSingleFileRename(
      """
      func 1️⃣foo(3️⃣a: Int) {}
      2️⃣foo(4️⃣a: 1)
      """,
      newName: "bar(x:",
      expectedPrepareRenamePlaceholder: "foo(a:)",
      expected: """
        func bar(x: Int) {}
        bar(x: 1)
        """
    )
  }

  func testNewNameContainsTextAfterParenthesis() async throws {
    try await assertSingleFileRename(
      """
      func 1️⃣foo(3️⃣a: Int) {}
      2️⃣foo(4️⃣a: 1)
      """,
      newName: "bar(x:)other:",
      expectedPrepareRenamePlaceholder: "foo(a:)",
      expected: """
        func bar(x: Int) {}
        bar(x: 1)
        """
    )
  }

  func testSpacesInNewParameterNames() async throws {
    try await assertSingleFileRename(
      """
      func 1️⃣foo(4️⃣a: Int) {}
      2️⃣foo(5️⃣a: 1)
      _ = 3️⃣foo(6️⃣a:)
      """,
      newName: "bar ( x : )",
      expectedPrepareRenamePlaceholder: "foo(a:)",
      expected: """
        func bar ( x : Int) {}
        bar ( x : 1)
        _ = bar ( x :)
        """
    )
  }

  func testRenameOperator() async throws {
    try await assertSingleFileRename(
      """
      struct Foo {}
      func 1️⃣+(x: Foo, y: Foo) {}
      Foo() 2️⃣+ Foo()
      """,
      newName: "-",
      expectedPrepareRenamePlaceholder: "+(_:_:)",
      expected: """
        struct Foo {}
        func -(x: Foo, y: Foo) {}
        Foo() - Foo()
        """
    )
  }

  func testRenameParameterToEmptyName() async throws {
    try await assertSingleFileRename(
      """
      func 1️⃣foo(3️⃣x: Int) {}
      2️⃣foo(4️⃣x: 1)
      """,
      newName: "bar(:)",
      expectedPrepareRenamePlaceholder: "foo(x:)",
      expected: """
        func bar(_ x: Int) {}
        bar(1)
        """
    )
  }

  func testRenameInsidePoundSelector() async throws {
    try SkipUnless.platformIsDarwin("#selector in test case doesn't compile without Objective-C runtime.")
    try await assertSingleFileRename(
      """
      import Foundation
      class Foo: NSObject {
        @objc public func 1️⃣bar(x: Int) {}
      }
      _ = #selector(Foo.2️⃣bar(x:))
      """,
      newName: "foo(y:)",
      expectedPrepareRenamePlaceholder: "bar(x:)",
      expected: """
        import Foundation
        class Foo: NSObject {
          @objc public func foo(y: Int) {}
        }
        _ = #selector(Foo.foo(y:))
        """
    )
  }

  func testCrossFileSwiftRename() async throws {
    try await assertMultiFileRename(
      files: [
        "a.swift": """
        func 1️⃣foo() {}
        """,
        "b.swift": """
        func test() {
          2️⃣foo()
        }
        """,
      ],
      newName: "bar",
      expectedPrepareRenamePlaceholder: "foo()",
      expected: [
        "a.swift": """
        func bar() {}
        """,
        "b.swift": """
        func test() {
          bar()
        }
        """,
      ]
    )
  }

  func testSwiftCrossModuleRename() async throws {
    try await assertMultiFileRename(
      files: [
        "LibA/LibA.swift": """
        public func 1️⃣foo(2️⃣argLabel: Int) {}
        """,
        "LibB/LibB.swift": """
        import LibA
        public func test() {
          3️⃣foo(4️⃣argLabel: 1)
        }
        """,
      ],
      newName: "bar(new:)",
      expectedPrepareRenamePlaceholder: "foo(argLabel:)",
      expected: [
        "LibA/LibA.swift": """
        public func bar(new: Int) {}
        """,
        "LibB/LibB.swift": """
        import LibA
        public func test() {
          bar(new: 1)
        }
        """,
      ],
      manifest: """
        // swift-tools-version: 5.7

        import PackageDescription

        let package = Package(
          name: "MyLibrary",
          targets: [
          .target(name: "LibA"),
          .target(name: "LibB", dependencies: ["LibA"]),
          ]
        )
        """
    )
  }

  func testTryIndexLocationsDontMatchInMemoryLocations() async throws {
    try await assertMultiFileRename(
      files: [
        "a.swift": """
        func 1️⃣foo() {}
        """,
        "b.swift": """
        0️⃣func test() {
          foo()
        }
        """,
      ],
      newName: "bar",
      expectedPrepareRenamePlaceholder: "foo()",
      expected: [
        "a.swift": """
        func bar() {}
        """,
        "b.swift": """
        func test() {
          foo()
        }
        """,
      ],
      manifest: """
        // swift-tools-version: 5.7

        import PackageDescription

        let package = Package(
          name: "MyLibrary",
          targets: [
            .target(
              name: "MyLibrary", 
              swiftSettings: [.unsafeFlags(["-Xfrontend", "-disable-objc-attr-requires-foundation-module"])]
            )
          ]
        )
        """,
      preRenameActions: { ws in
        let (bUri, bPositions) = try ws.openDocument("b.swift")
        ws.testClient.send(
          DidChangeTextDocumentNotification(
            textDocument: VersionedTextDocumentIdentifier(bUri, version: 1),
            contentChanges: [TextDocumentContentChangeEvent(range: Range(bPositions["0️⃣"]), text: "\n")]
          )
        )
      }
    )
  }

  func testTryIndexLocationsDontMatchInMemoryLocationsByLineColumnButNotOffset() async throws {
    try await assertMultiFileRename(
      files: [
        "a.swift": """
        func 1️⃣foo() {}
        """,
        "b.swift": """
        0️⃣func test() {
          foo()
        }
        """,
      ],
      newName: "bar",
      expectedPrepareRenamePlaceholder: "foo()",
      expected: [
        "a.swift": """
        func bar() {}
        """,
        "b.swift": """
        func test() {
          bar()
        }
        """,
      ],
      manifest: """
        // swift-tools-version: 5.7

        import PackageDescription

        let package = Package(
          name: "MyLibrary",
          targets: [
            .target(
              name: "MyLibrary", 
              swiftSettings: [.unsafeFlags(["-Xfrontend", "-disable-objc-attr-requires-foundation-module"])]
            )
          ]
        )
        """,
      preRenameActions: { ws in
        let (bUri, bPositions) = try ws.openDocument("b.swift")
        ws.testClient.send(
          DidChangeTextDocumentNotification(
            textDocument: VersionedTextDocumentIdentifier(bUri, version: 1),
            contentChanges: [
              TextDocumentContentChangeEvent(range: Range(bPositions["0️⃣"]), text: "/* this is just a comment */")
            ]
          )
        )
      }
    )
  }

  func testPrepeareRenameOnDefinition() async throws {
    try await SkipUnless.sourcekitdSupportsRename()
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI.for(.swift)
    let positions = testClient.openDocument(
      """
      func 1️⃣foo2️⃣(3️⃣a: Int) {}
      """,
      uri: uri
    )
    let response = try await testClient.send(
      PrepareRenameRequest(textDocument: TextDocumentIdentifier(uri), position: positions["1️⃣"])
    )
    let range = try XCTUnwrap(response?.range)
    let placeholder = try XCTUnwrap(response?.placeholder)
    XCTAssertEqual(range, positions["1️⃣"]..<positions["2️⃣"])
    XCTAssertEqual(placeholder, "foo(a:)")
  }

  func testPrepeareRenameOnReference() async throws {
    try await SkipUnless.sourcekitdSupportsRename()
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI.for(.swift)
    let positions = testClient.openDocument(
      """
      func foo(a: Int, b: Int = 1) {}
      1️⃣foo2️⃣(a: 1)
      """,
      uri: uri
    )
    let response = try await testClient.send(
      PrepareRenameRequest(textDocument: TextDocumentIdentifier(uri), position: positions["1️⃣"])
    )
    let range = try XCTUnwrap(response?.range)
    let placeholder = try XCTUnwrap(response?.placeholder)
    XCTAssertEqual(range, positions["1️⃣"]..<positions["2️⃣"])
    XCTAssertEqual(placeholder, "foo(a:b:)")
  }

  func testGlobalRenameC() async throws {
    try await SkipUnless.clangdSupportsIndexBasedRename()
    try await assertMultiFileRename(
      files: [
        "Sources/MyLibrary/include/lib.h": """
        void 1️⃣do2️⃣Stuff();
        """,
        "lib.c": """
        #include "lib.h"

        void 3️⃣doStuff() {
          4️⃣doStuff();
        }
        """,
      ],
      headerFileLanguage: .c,
      newName: "doRecursiveStuff",
      expectedPrepareRenamePlaceholder: "doStuff",
      expected: [
        "Sources/MyLibrary/include/lib.h": """
        void doRecursiveStuff();
        """,
        "lib.c": """
        #include "lib.h"

        void doRecursiveStuff() {
          doRecursiveStuff();
        }
        """,
      ]
    )
  }

  func testGlobalRenameObjC() async throws {
    try await SkipUnless.clangdSupportsIndexBasedRename()
    try await assertMultiFileRename(
      files: [
        "Sources/MyLibrary/include/lib.h": """
        @interface Foo
        - (int)1️⃣perform2️⃣Action:(int)action 3️⃣wi4️⃣th:(int)value;
        @end
        """,
        "lib.m": """
        #include "lib.h"

        @implementation Foo
        - (int)5️⃣performAction:(int)action 6️⃣with:(int)value {
          return [self 7️⃣performAction:action 8️⃣with:value];
        }
        @end
        """,
      ],
      headerFileLanguage: .objective_c,
      newName: "performNewAction:by:",
      expectedPrepareRenamePlaceholder: "performAction:with:",
      expected: [
        "Sources/MyLibrary/include/lib.h": """
        @interface Foo
        - (int)performNewAction:(int)action by:(int)value;
        @end
        """,
        "lib.m": """
        #include "lib.h"

        @implementation Foo
        - (int)performNewAction:(int)action by:(int)value {
          return [self performNewAction:action by:value];
        }
        @end
        """,
      ]
    )
  }
}
