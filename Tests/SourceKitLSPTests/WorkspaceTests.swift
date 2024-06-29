//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import LSPLogging
import LSPTestSupport
import LanguageServerProtocol
@_spi(Testing) import SKCore
import SKTestSupport
import SourceKitLSP
import TSCBasic
import XCTest

final class WorkspaceTests: XCTestCase {

  func testMultipleSwiftPMWorkspaces() async throws {
    // The package manifest is the same for both packages we open.
    let packageManifest = """
      // swift-tools-version: 5.7

      import PackageDescription

      let package = Package(
        name: "MyLibrary",
        targets: [
          .target(name: "MyLibrary"),
          .executableTarget(name: "MyExec", dependencies: ["MyLibrary"])
        ]
      )
      """

    let project = try await MultiFileTestProject(
      files: [
        // PackageA
        "PackageA/Sources/MyLibrary/libA.swift": """
        public struct FancyLib {
          public init() {}
          public func sayHello() {}
        }
        """,

        "PackageA/Sources/MyExec/execA.swift": """
        import MyLibrary

        FancyLib().1️⃣sayHello()
        """,

        "PackageA/Package.swift": packageManifest,

        // PackageB
        "PackageB/Sources/MyLibrary/libB.swift": """
        public struct Lib {
          public init() {}
          public func foo() {}
        }
        """,
        "PackageB/Sources/MyExec/execB.swift": """
        import MyLibrary
        Lib().2️⃣foo()
        """,
        "PackageB/Package.swift": packageManifest,
      ],
      workspaces: { scratchDir in
        return [
          WorkspaceFolder(uri: DocumentURI(scratchDir.appendingPathComponent("PackageA"))),
          WorkspaceFolder(uri: DocumentURI(scratchDir.appendingPathComponent("PackageB"))),
        ]
      },
      enableBackgroundIndexing: true
    )
    _ = try await project.testClient.send(PollIndexRequest())

    let (bUri, bPositions) = try project.openDocument("execB.swift")

    let completions = try await project.testClient.send(
      CompletionRequest(textDocument: TextDocumentIdentifier(bUri), position: bPositions["2️⃣"])
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
            TextEdit(range: Range(bPositions["2️⃣"]), newText: "foo()")
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
            TextEdit(range: Range(bPositions["2️⃣"]), newText: "self")
          )
        ),
      ]
    )

    let (aUri, aPositions) = try project.openDocument("execA.swift")

    let otherCompletions = try await project.testClient.send(
      CompletionRequest(textDocument: TextDocumentIdentifier(aUri), position: aPositions["1️⃣"])
    )

    XCTAssertEqual(
      otherCompletions.items,
      [
        CompletionItem(
          label: "sayHello()",
          kind: .method,
          detail: "Void",
          documentation: nil,
          deprecated: false,
          sortText: nil,
          filterText: "sayHello()",
          insertText: "sayHello()",
          insertTextFormat: .plain,
          textEdit: .textEdit(
            TextEdit(range: Range(aPositions["1️⃣"]), newText: "sayHello()")
          )
        ),
        CompletionItem(
          label: "self",
          kind: LanguageServerProtocol.CompletionItemKind(rawValue: 14),
          detail: "FancyLib",
          documentation: nil,
          deprecated: false,
          sortText: nil,
          filterText: "self",
          insertText: "self",
          insertTextFormat: .plain,
          textEdit: .textEdit(
            TextEdit(range: Range(aPositions["1️⃣"]), newText: "self")
          )
        ),
      ]
    )
  }

  func testOpenPackageManifestInMultiSwiftPMWorkspaceSetup() async throws {
    let project = try await MultiFileTestProject(
      files: [
        // PackageA
        "PackageA/Sources/MyLibrary/libA.swift": "",
        "PackageA/Package.swift": SwiftPMTestProject.defaultPackageManifest,

        // PackageB
        "PackageB/Sources/MyLibrary/libB.swift": "",
        "PackageB/Package.swift": SwiftPMTestProject.defaultPackageManifest,
      ],
      workspaces: { scratchDir in
        return [
          WorkspaceFolder(uri: DocumentURI(scratchDir)),
          WorkspaceFolder(uri: DocumentURI(scratchDir.appendingPathComponent("PackageA"))),
          WorkspaceFolder(uri: DocumentURI(scratchDir.appendingPathComponent("PackageB"))),
        ]
      }
    )

    let bPackageManifestUri = DocumentURI(
      project.scratchDirectory.appendingPathComponent("PackageB").appendingPathComponent("Package.swift")
    )

    project.testClient.openDocument(SwiftPMTestProject.defaultPackageManifest, uri: bPackageManifestUri)

    // Ensure that we get proper build settings for Package.swift and no error about `No such module: PackageDescription`
    let diags = try await project.testClient.send(
      DocumentDiagnosticsRequest(textDocument: TextDocumentIdentifier(bPackageManifestUri))
    )
    XCTAssertEqual(diags, .full(RelatedFullDocumentDiagnosticReport(items: [])))
  }

  func testSwiftPMPackageInSubfolder() async throws {
    let packageManifest = """
      // swift-tools-version: 5.7

      import PackageDescription

      let package = Package(
        name: "MyLibrary",
        targets: [
          .target(name: "MyLibrary"),
          .executableTarget(name: "MyExec", dependencies: ["MyLibrary"])
        ]
      )
      """

    let project = try await MultiFileTestProject(
      files: [
        // PackageA
        "PackageA/Sources/MyLibrary/libA.swift": """
        public struct FancyLib {
          public init() {}
          public func sayHello() {}
        }
        """,

        "PackageA/Sources/MyExec/execA.swift": """
        import MyLibrary

        FancyLib().1️⃣sayHello()
        """,

        "PackageA/Package.swift": packageManifest,
      ],
      enableBackgroundIndexing: true
    )

    let (uri, positions) = try project.openDocument("execA.swift")

    _ = try await project.testClient.send(PollIndexRequest())

    let otherCompletions = try await project.testClient.send(
      CompletionRequest(textDocument: TextDocumentIdentifier(uri), position: positions["1️⃣"])
    )

    XCTAssertEqual(
      otherCompletions.items,
      [
        CompletionItem(
          label: "sayHello()",
          kind: .method,
          detail: "Void",
          documentation: nil,
          deprecated: false,
          sortText: nil,
          filterText: "sayHello()",
          insertText: "sayHello()",
          insertTextFormat: .plain,
          textEdit: .textEdit(
            TextEdit(range: Range(positions["1️⃣"]), newText: "sayHello()")
          )
        ),
        CompletionItem(
          label: "self",
          kind: LanguageServerProtocol.CompletionItemKind(rawValue: 14),
          detail: "FancyLib",
          documentation: nil,
          deprecated: false,
          sortText: nil,
          filterText: "self",
          insertText: "self",
          insertTextFormat: .plain,
          textEdit: .textEdit(
            TextEdit(range: Range(positions["1️⃣"]), newText: "self")
          )
        ),
      ]
    )
  }

  func testNestedSwiftPMWorkspacesWithoutDedicatedWorkspaceFolder() async throws {
    // The package manifest is the same for both packages we open.
    let packageManifest = """
      // swift-tools-version: 5.7

      import PackageDescription

      let package = Package(
        name: "MyLibrary",
        targets: [
          .target(name: "MyLibrary"),
          .executableTarget(name: "MyExec", dependencies: ["MyLibrary"])
        ]
      )
      """

    let project = try await MultiFileTestProject(
      files: [
        // PackageA
        "PackageA/Sources/MyLibrary/libA.swift": """
        public struct FancyLib {
          public init() {}
          public func sayHello() {}
        }
        """,

        "PackageA/Sources/MyExec/execA.swift": """
        import MyLibrary

        FancyLib().1️⃣sayHello()
        """,

        "PackageA/Package.swift": packageManifest,

        // PackageB
        "Sources/MyLibrary/libB.swift": """
        public struct Lib {
          public init() {}
          public func foo() {}
        }
        """,
        "Sources/MyExec/execB.swift": """
        import MyLibrary
        Lib().2️⃣foo()
        """,
        "Package.swift": packageManifest,
      ],
      enableBackgroundIndexing: true
    )

    _ = try await project.testClient.send(PollIndexRequest())

    let (bUri, bPositions) = try project.openDocument("execB.swift")

    let completions = try await project.testClient.send(
      CompletionRequest(textDocument: TextDocumentIdentifier(bUri), position: bPositions["2️⃣"])
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
            TextEdit(range: Range(bPositions["2️⃣"]), newText: "foo()")
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
            TextEdit(range: Range(bPositions["2️⃣"]), newText: "self")
          )
        ),
      ]
    )

    let (aUri, aPositions) = try project.openDocument("execA.swift")

    _ = try await project.testClient.send(PollIndexRequest())

    let otherCompletions = try await project.testClient.send(
      CompletionRequest(textDocument: TextDocumentIdentifier(aUri), position: aPositions["1️⃣"])
    )

    XCTAssertEqual(
      otherCompletions.items,
      [
        CompletionItem(
          label: "sayHello()",
          kind: .method,
          detail: "Void",
          documentation: nil,
          deprecated: false,
          sortText: nil,
          filterText: "sayHello()",
          insertText: "sayHello()",
          insertTextFormat: .plain,
          textEdit: .textEdit(
            TextEdit(range: Range(aPositions["1️⃣"]), newText: "sayHello()")
          )
        ),
        CompletionItem(
          label: "self",
          kind: LanguageServerProtocol.CompletionItemKind(rawValue: 14),
          detail: "FancyLib",
          documentation: nil,
          deprecated: false,
          sortText: nil,
          filterText: "self",
          insertText: "self",
          insertTextFormat: .plain,
          textEdit: .textEdit(
            TextEdit(range: Range(aPositions["1️⃣"]), newText: "self")
          )
        ),
      ]
    )
  }

  func testMultipleClangdWorkspaces() async throws {
    let project = try await MultiFileTestProject(
      files: [
        "WorkspaceA/main.cpp": """
        #if FOO
        void 1️⃣foo2️⃣() {}
        #else
        void foo() {}
        #endif

        int main() {
          3️⃣foo4️⃣();
        }
        """,
        "WorkspaceA/compile_flags.txt": """
        -DFOO
        """,
        "WorkspaceB/test.m": "",
      ],
      workspaces: { scratchDir in
        return [
          WorkspaceFolder(uri: DocumentURI(scratchDir.appendingPathComponent("WorkspaceA"))),
          WorkspaceFolder(uri: DocumentURI(scratchDir.appendingPathComponent("WorkspaceB"))),
        ]
      },
      usePullDiagnostics: false
    )

    _ = try project.openDocument("test.m")

    let diags = try await project.testClient.nextDiagnosticsNotification()
    XCTAssertEqual(diags.diagnostics.count, 0)

    let (mainUri, positions) = try project.openDocument("main.cpp")

    let highlightRequest = DocumentHighlightRequest(
      textDocument: TextDocumentIdentifier(mainUri),
      position: positions["3️⃣"]
    )
    let highlightResponse = try await project.testClient.send(highlightRequest)
    XCTAssertEqual(
      highlightResponse,
      [
        DocumentHighlight(range: positions["1️⃣"]..<positions["2️⃣"], kind: .text),
        DocumentHighlight(range: positions["3️⃣"]..<positions["4️⃣"], kind: .text),
      ]
    )
  }

  func testRecomputeFileWorkspaceMembershipOnPackageSwiftChange() async throws {
    let project = try await MultiFileTestProject(
      files: [
        "PackageA/Sources/MyLibrary/libA.swift": "",
        "PackageA/Package.swift": SwiftPMTestProject.defaultPackageManifest,

        "PackageB/Sources/MyLibrary/libB.swift": """
        public struct Lib {
          public func foo() {}
          public init() {}
        }
        """,
        "PackageB/Sources/MyExec/main.swift": """
        import MyLibrary

        Lib().1️⃣
        """,
        "PackageB/Package.swift": SwiftPMTestProject.defaultPackageManifest,
      ],
      workspaces: { scratchDir in
        return [
          WorkspaceFolder(uri: DocumentURI(scratchDir.appendingPathComponent("PackageA"))),
          WorkspaceFolder(uri: DocumentURI(scratchDir.appendingPathComponent("PackageB"))),
        ]
      }
    )

    let (mainUri, _) = try project.openDocument("main.swift")

    // We open PackageA first. Thus, MyExec/main (which is a file in PackageB that hasn't been added to Package.swift
    // yet) will belong to PackageA by default (because it provides fallback build settings for it).
    assertEqual(
      await project.testClient.server.workspaceForDocument(uri: mainUri)?.rootUri,
      DocumentURI(project.scratchDirectory.appendingPathComponent("PackageA"))
    )

    // Add the MyExec target to PackageB/Package.swift
    let newPackageManifest = """
      // swift-tools-version: 5.7

      import PackageDescription

      let package = Package(
        name: "MyLibrary",
        targets: [
          .target(name: "MyLibrary"),
          .executableTarget(name: "MyExec", dependencies: ["MyLibrary"])
        ]
      )
      """

    let packageBManifestPath = project.scratchDirectory
      .appendingPathComponent("PackageB")
      .appendingPathComponent("Package.swift")
    try newPackageManifest.write(
      to: packageBManifestPath,
      atomically: true,
      encoding: .utf8
    )

    project.testClient.send(
      DidChangeWatchedFilesNotification(changes: [
        FileEvent(uri: DocumentURI(packageBManifestPath), type: .changed)
      ])
    )

    // Ensure that the DidChangeWatchedFilesNotification is handled before we continue.
    _ = try await project.testClient.send(BarrierRequest())

    // After updating PackageB/Package.swift, PackageB can provide proper build settings for MyExec/main.swift and
    // thus workspace membership should switch to PackageB.

    // Updating the build settings takes a few seconds. Send code completion requests every second until we receive correct results.
    var didReceiveCorrectWorkspaceMembership = false

    // Updating the build settings takes a few seconds. Send code completion requests every second until we receive correct results.
    let packageBRootUri = DocumentURI(project.scratchDirectory.appendingPathComponent("PackageB"))
    for _ in 0..<30 {
      let workspace = await project.testClient.server.workspaceForDocument(uri: mainUri)
      if workspace?.rootUri == packageBRootUri {
        didReceiveCorrectWorkspaceMembership = true
        break
      }
      logger.log("Received incorrect workspace \(workspace?.rootUri?.pseudoPath ?? "<nil>"). Trying again in 1s")
      try await Task.sleep(nanoseconds: 1_000_000_000)
    }

    XCTAssert(didReceiveCorrectWorkspaceMembership)
  }

  func testMixedPackage() async throws {
    let project = try await SwiftPMTestProject(
      files: [
        "clib/include/clib.h": """
        #ifndef CLIB_H
        #define CLIB_H

        void clib_func(void);
        void clib_other(void);

        #endif // CLIB_H
        """,
        "clib/clib.c": """
        #include "clib.h"

        void clib_func(void) {1️⃣}
        """,
        "lib/lib.swift": """
        public struct Lib {
          public func foo() {}
          public init() {}
        }
        2️⃣
        """,
      ],
      manifest: """
        let package = Package(
          name: "MyLibrary",
          targets: [
            .target(name: "lib", dependencies: []),
            .target(name: "clib", dependencies: []),
          ]
        )
        """
    )

    let (swiftUri, swiftPositions) = try project.openDocument("lib.swift")
    let (cUri, cPositions) = try project.openDocument("clib.c")

    let cCompletions = try await project.testClient.send(
      CompletionRequest(textDocument: TextDocumentIdentifier(cUri), position: cPositions["1️⃣"])
    )
    XCTAssertGreaterThanOrEqual(cCompletions.items.count, 0)

    let swiftCompletions = try await project.testClient.send(
      CompletionRequest(textDocument: TextDocumentIdentifier(swiftUri), position: swiftPositions["2️⃣"])
    )
    XCTAssertGreaterThanOrEqual(swiftCompletions.items.count, 0)
  }

  func testChangeWorkspaceFolders() async throws {
    let project = try await MultiFileTestProject(
      files: [
        "subdir/Sources/otherPackage/otherPackage.swift": """
        import package

        func test() {
          Package().1️⃣helloWorld()
        }
        """,
        "subdir/Sources/package/package.swift": """
        public struct Package {
          public init() {}

          public func helloWorld() {
            print("Hello world!")
          }
        }
        """,
        "subdir/Package.swift": """
        // swift-tools-version: 5.5

        import PackageDescription

        let package = Package(
          name: "package",
          products: [
            .library(name: "package", targets: ["package"]),
            .library(name: "otherPackage", targets: ["otherPackage"]),
          ],
          targets: [
            .target(
              name: "package",
              dependencies: []
            ),
            .target(
              name: "otherPackage",
              dependencies: ["package"]
            ),
          ]
        )
        """,
      ],
      workspaces: { scratchDir in
        return [
          WorkspaceFolder(uri: DocumentURI(scratchDir.appendingPathComponent("fake")))
        ]
      }
    )

    let packageDir = try project.uri(for: "Package.swift").fileURL!.deletingLastPathComponent()

    try await TSCBasic.Process.checkNonZeroExit(arguments: [
      ToolchainRegistry.forTesting.default!.swift!.pathString,
      "build",
      "--package-path", packageDir.path,
      "-Xswiftc", "-index-ignore-system-modules",
      "-Xcc", "-index-ignore-system-symbols",
    ])

    let (otherPackageUri, positions) = try project.openDocument("otherPackage.swift")
    let testPosition = positions["1️⃣"]

    let preChangeWorkspaceResponse = try await project.testClient.send(
      CompletionRequest(
        textDocument: TextDocumentIdentifier(otherPackageUri),
        position: testPosition
      )
    )

    XCTAssertEqual(
      preChangeWorkspaceResponse.items,
      [],
      "Should not receive cross-module code completion results when opening an unrelated directory as workspace root"
    )

    project.testClient.send(
      DidChangeWorkspaceFoldersNotification(
        event: WorkspaceFoldersChangeEvent(added: [
          WorkspaceFolder(uri: DocumentURI(packageDir))
        ])
      )
    )

    let postChangeWorkspaceResponse = try await project.testClient.send(
      CompletionRequest(
        textDocument: TextDocumentIdentifier(otherPackageUri),
        position: testPosition
      )
    )

    XCTAssertEqual(
      postChangeWorkspaceResponse.items,
      [
        CompletionItem(
          label: "helloWorld()",
          kind: .method,
          detail: "Void",
          documentation: nil,
          deprecated: false,
          sortText: nil,
          filterText: "helloWorld()",
          insertText: "helloWorld()",
          insertTextFormat: .plain,
          textEdit: .textEdit(
            TextEdit(
              range: Range(testPosition),
              newText: "helloWorld()"
            )
          )
        ),
        CompletionItem(
          label: "self",
          kind: .keyword,
          detail: "Package",
          documentation: nil,
          deprecated: false,
          sortText: nil,
          filterText: "self",
          insertText: "self",
          insertTextFormat: .plain,
          textEdit: .textEdit(
            TextEdit(
              range: Range(testPosition),
              newText: "self"
            )
          )
        ),
      ]
    )
  }
  func testIntegrationTest() async throws {
    // This test is doing the same as `test-sourcekit-lsp` in the `swift-integration-tests` repo.

    let project = try await SwiftPMTestProject(
      files: [
        "Sources/clib/include/clib.h": """
        #ifndef CLIB_H
        #define CLIB_H

        void clib_func(void);
        void clib_other(void);

        #endif // CLIB_H
        """,
        "Sources/clib/clib.c": """
        #include "clib.h"

        void 1️⃣clib_func(void) {2️⃣}
        """,
        "Sources/exec/main.swift": """
        import lib
        import clib

        Lib().3️⃣foo()
        4️⃣clib_func()
        """,
        "Sources/lib/lib.swift": """
        public struct Lib {
          public func 5️⃣foo() {}
          public init() {}
        }
        """,
      ],
      manifest: """
        // swift-tools-version:5.5
        import PackageDescription

        let package = Package(
          name: "pkg",
          targets: [
            .target(name: "exec", dependencies: ["lib", "clib"]),
            .target(name: "lib", dependencies: []),
            .target(name: "clib", dependencies: []),
          ]
        )
        """,
      enableBackgroundIndexing: true
    )
    let (mainUri, mainPositions) = try project.openDocument("main.swift")

    let fooDefinitionResponse = try await project.testClient.send(
      DefinitionRequest(textDocument: TextDocumentIdentifier(mainUri), position: mainPositions["3️⃣"])
    )
    XCTAssertEqual(
      fooDefinitionResponse,
      .locations([
        Location(uri: try project.uri(for: "lib.swift"), range: try Range(project.position(of: "5️⃣", in: "lib.swift")))
      ])
    )

    let clibFuncDefinitionResponse = try await project.testClient.send(
      DefinitionRequest(textDocument: TextDocumentIdentifier(mainUri), position: mainPositions["4️⃣"])
    )
    XCTAssertEqual(
      clibFuncDefinitionResponse,
      .locations([
        Location(uri: try project.uri(for: "clib.c"), range: try Range(project.position(of: "1️⃣", in: "clib.c")))
      ])
    )

    let swiftCompletionResponse = try await project.testClient.send(
      CompletionRequest(textDocument: TextDocumentIdentifier(mainUri), position: mainPositions["3️⃣"])
    )
    XCTAssertEqual(
      swiftCompletionResponse.items,
      [
        CompletionItem(
          label: "foo()",
          kind: .method,
          detail: "Void",
          deprecated: false,
          filterText: "foo()",
          insertText: "foo()",
          insertTextFormat: .plain,
          textEdit: .textEdit(TextEdit(range: Range(mainPositions["3️⃣"]), newText: "foo()"))
        ),
        CompletionItem(
          label: "self",
          kind: .keyword,
          detail: "Lib",
          deprecated: false,
          filterText: "self",
          insertText: "self",
          insertTextFormat: .plain,
          textEdit: .textEdit(TextEdit(range: Range(mainPositions["3️⃣"]), newText: "self"))
        ),
      ]
    )

    let (clibcUri, clibcPositions) = try project.openDocument("clib.c")

    let cCompletionResponse = try await project.testClient.send(
      CompletionRequest(textDocument: TextDocumentIdentifier(clibcUri), position: clibcPositions["2️⃣"])
    )
    // rdar://73762053: This should also suggest clib_other
    XCTAssert(cCompletionResponse.items.contains(where: { $0.insertText == "clib_func" }))
  }

  func testWorkspaceOptions() async throws {
    let project = try await SwiftPMTestProject(
      files: [
        "/.sourcekit-lsp/config.json": """
        {
          "swiftPM": {
            "swiftCompilerFlags": ["-D", "TEST"]
          }
        }
        """,
        "Test.swift": """
        func test() {
        #if TEST
          let x: String = 1
        #endif
        }
        """,
      ]
    )

    let (uri, _) = try project.openDocument("Test.swift")
    let diagnostics = try await project.testClient.send(
      DocumentDiagnosticsRequest(textDocument: TextDocumentIdentifier(uri))
    )
    guard case .full(let diagnostics) = diagnostics else {
      XCTFail("Expected full diagnostics")
      return
    }
    XCTAssertEqual(diagnostics.items.map(\.message), ["Cannot convert value of type 'Int' to specified type 'String'"])
  }

  func testOptionsInInitializeRequest() async throws {
    let project = try await SwiftPMTestProject(
      files: [
        "Test.swift": """
        func test() {
        #if TEST
          let x: String = 1
        #endif
        }
        """
      ],
      initializationOptions: SourceKitLSPOptions(
        swiftPM: SourceKitLSPOptions.SwiftPMOptions(swiftCompilerFlags: ["-D", "TEST"])
      ).asLSPAny
    )

    let (uri, _) = try project.openDocument("Test.swift")
    let diagnostics = try await project.testClient.send(
      DocumentDiagnosticsRequest(textDocument: TextDocumentIdentifier(uri))
    )
    guard case .full(let diagnostics) = diagnostics else {
      XCTFail("Expected full diagnostics")
      return
    }
    XCTAssertEqual(diagnostics.items.map(\.message), ["Cannot convert value of type 'Int' to specified type 'String'"])
  }

  func testWorkspaceOptionsOverrideGlobalOptions() async throws {
    let project = try await SwiftPMTestProject(
      files: [
        "/.sourcekit-lsp/config.json": """
        {
          "swiftPM": {
            "swiftCompilerFlags": ["-D", "TEST"]
          }
        }
        """,
        "Test.swift": """
        func test() {
        #if TEST
          let x: String = 1
        #endif
        #if OTHER
          let x: String = 1.0
        #endif
        }
        """,
      ],
      initializationOptions: SourceKitLSPOptions(
        swiftPM: SourceKitLSPOptions.SwiftPMOptions(swiftCompilerFlags: ["-D", "OTHER"])
      ).asLSPAny
    )

    let (uri, _) = try project.openDocument("Test.swift")
    let diagnostics = try await project.testClient.send(
      DocumentDiagnosticsRequest(textDocument: TextDocumentIdentifier(uri))
    )
    guard case .full(let diagnostics) = diagnostics else {
      XCTFail("Expected full diagnostics")
      return
    }
    XCTAssertEqual(diagnostics.items.map(\.message), ["Cannot convert value of type 'Int' to specified type 'String'"])
  }
}
