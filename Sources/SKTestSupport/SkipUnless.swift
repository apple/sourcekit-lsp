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

import Foundation
import LSPLogging
import LSPTestSupport
import LanguageServerProtocol
import RegexBuilder
@_spi(Testing) import SKCore
import SourceKitLSP
import XCTest

import enum PackageLoading.Platform
import struct TSCBasic.AbsolutePath
import class TSCBasic.Process
import enum TSCBasic.ProcessEnv

// MARK: - Skip checks

/// Namespace for functions that are used to skip unsupported tests.
public actor SkipUnless {
  private enum FeatureCheckResult {
    case featureSupported
    case featureUnsupported(skipMessage: String)
  }

  private static let shared = SkipUnless()

  /// For any feature that has already been evaluated, the result of whether or not it should be skipped.
  private var checkCache: [String: FeatureCheckResult] = [:]

  /// Throw an `XCTSkip` if any of the following conditions hold
  ///  - The Swift version of the toolchain used for testing (`ToolchainRegistry.forTesting.default`) is older than
  ///    `swiftVersion`
  ///  - The Swift version of the toolchain used for testing is equal to `swiftVersion` and `featureCheck` returns
  ///    `false`. This is used for features that are introduced in `swiftVersion` but are not present in all toolchain
  ///    snapshots.
  ///
  /// Having the version check indicates when the check tests can be removed (namely when the minimum required version
  /// to test sourcekit-lsp is above `swiftVersion`) and it ensures that tests can’t stay in the skipped state over
  /// multiple releases.
  ///
  /// Independently of these checks, the tests are never skipped in Swift CI (identified by the presence of the `SWIFTCI_USE_LOCAL_DEPS` environment). Swift CI is assumed to always build its own toolchain, which is thus
  /// guaranteed to be up-to-date.
  private func skipUnlessSupportedByToolchain(
    swiftVersion: SwiftVersion,
    featureName: String = #function,
    file: StaticString,
    line: UInt,
    featureCheck: () async throws -> Bool
  ) async throws {
    return try await skipUnlessSupported(featureName: featureName, file: file, line: line) {
      let toolchainSwiftVersion = try await unwrap(ToolchainRegistry.forTesting.default).swiftVersion
      let requiredSwiftVersion = SwiftVersion(swiftVersion.major, swiftVersion.minor)
      if toolchainSwiftVersion < requiredSwiftVersion {
        return .featureUnsupported(
          skipMessage: """
            Skipping because toolchain has Swift version \(toolchainSwiftVersion) \
            but test requires at least \(requiredSwiftVersion)
            """
        )
      } else if toolchainSwiftVersion == requiredSwiftVersion {
        logger.info("Checking if feature '\(featureName)' is supported")
        defer {
          logger.info("Done checking if feature '\(featureName)' is supported")
        }
        if try await !featureCheck() {
          return .featureUnsupported(skipMessage: "Skipping because toolchain doesn't contain \(featureName)")
        } else {
          return .featureSupported
        }
      } else {
        return .featureSupported
      }
    }
  }

  private func skipUnlessSupported(
    featureName: String = #function,
    file: StaticString,
    line: UInt,
    featureCheck: () async throws -> FeatureCheckResult
  ) async throws {
    let checkResult: FeatureCheckResult
    if let cachedResult = checkCache[featureName] {
      checkResult = cachedResult
    } else if ProcessEnv.block["SWIFTCI_USE_LOCAL_DEPS"] != nil {
      // Never skip tests in CI. Toolchain should be up-to-date
      checkResult = .featureSupported
    } else {
      checkResult = try await featureCheck()
    }
    checkCache[featureName] = checkResult

    if case .featureUnsupported(let skipMessage) = checkResult {
      throw XCTSkip(skipMessage, file: file, line: line)
    }
  }

  public static func sourcekitdHasSemanticTokensRequest(
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    try await shared.skipUnlessSupportedByToolchain(swiftVersion: SwiftVersion(5, 11), file: file, line: line) {
      let testClient = try await TestSourceKitLSPClient()
      let uri = DocumentURI(for: .swift)
      testClient.openDocument("0.bitPattern", uri: uri)
      let response = try unwrap(
        await testClient.send(DocumentSemanticTokensRequest(textDocument: TextDocumentIdentifier(uri)))
      )

      let tokens = SyntaxHighlightingTokens(lspEncodedTokens: response.data)

      // If we don't have semantic token support in sourcekitd, the second token is an identifier based on the syntax
      // tree, not a property.
      return tokens.tokens != [
        SyntaxHighlightingToken(
          range: Position(line: 0, utf16index: 0)..<Position(line: 0, utf16index: 1),
          kind: .number,
          modifiers: []
        ),
        SourceKitLSP.SyntaxHighlightingToken(
          range: Position(line: 0, utf16index: 2)..<Position(line: 0, utf16index: 12),
          kind: .identifier,
          modifiers: []
        ),
      ]
    }
  }

  public static func sourcekitdSupportsRename(
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    try await shared.skipUnlessSupportedByToolchain(swiftVersion: SwiftVersion(5, 11), file: file, line: line) {
      let testClient = try await TestSourceKitLSPClient()
      let uri = DocumentURI(for: .swift)
      let positions = testClient.openDocument("func 1️⃣test() {}", uri: uri)
      do {
        _ = try await testClient.send(
          RenameRequest(textDocument: TextDocumentIdentifier(uri), position: positions["1️⃣"], newName: "test2")
        )
      } catch let error as ResponseError {
        return error.message != "Running sourcekit-lsp with a version of sourcekitd that does not support rename"
      }
      return true
    }
  }

  /// Checks whether the sourcekitd contains a fix to rename labels of enum cases correctly
  /// (https://github.com/apple/swift/pull/74241).
  public static func sourcekitdCanRenameEnumCaseLabels(
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    return try await shared.skipUnlessSupportedByToolchain(swiftVersion: SwiftVersion(6, 0), file: file, line: line) {
      let testClient = try await TestSourceKitLSPClient()
      let uri = DocumentURI(for: .swift)
      let positions = testClient.openDocument(
        """
        enum MyEnum {
          case 1️⃣myCase(2️⃣String)
        }
        """,
        uri: uri
      )

      let renameResult = try await testClient.send(
        RenameRequest(textDocument: TextDocumentIdentifier(uri), position: positions["1️⃣"], newName: "myCase(label:)")
      )
      return renameResult?.changes == [uri: [TextEdit(range: Range(positions["2️⃣"]), newText: "label: ")]]
    }
  }

  /// Whether clangd has support for the `workspace/indexedRename` request.
  public static func clangdSupportsIndexBasedRename(
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    try await shared.skipUnlessSupportedByToolchain(swiftVersion: SwiftVersion(5, 11), file: file, line: line) {
      let testClient = try await TestSourceKitLSPClient()
      let uri = DocumentURI(for: .c)
      let positions = testClient.openDocument("void 1️⃣test() {}", uri: uri)
      do {
        _ = try await testClient.send(
          IndexedRenameRequest(
            textDocument: TextDocumentIdentifier(uri),
            oldName: "test",
            newName: "test2",
            positions: [uri: [positions["1️⃣"]]]
          )
        )
      } catch let error as ResponseError {
        return error.message != "method not found"
      }
      return true
    }
  }

  /// SwiftPM moved the location where it stores Swift modules to a subdirectory in
  /// https://github.com/swiftlang/swift-package-manager/pull/7103.
  public static func swiftpmStoresModulesInSubdirectory(
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    try await shared.skipUnlessSupportedByToolchain(swiftVersion: SwiftVersion(5, 11), file: file, line: line) {
      let workspace = try await SwiftPMTestProject(files: ["test.swift": ""])
      try await SwiftPMTestProject.build(at: workspace.scratchDirectory)
      let modulesDirectory = workspace.scratchDirectory
        .appendingPathComponent(".build")
        .appendingPathComponent("debug")
        .appendingPathComponent("Modules")
        .appendingPathComponent("MyLibrary.swiftmodule")
      return FileManager.default.fileExists(atPath: modulesDirectory.path)
    }
  }

  public static func toolchainContainsSwiftFormat(
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    try await shared.skipUnlessSupportedByToolchain(swiftVersion: SwiftVersion(5, 11), file: file, line: line) {
      return await ToolchainRegistry.forTesting.default?.swiftFormat != nil
    }
  }

  /// Checks if the toolchain contains https://github.com/apple/swift/pull/74080.
  public static func sourcekitdReportsOverridableFunctionDefinitionsAsDynamic(
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    struct ExpectedLocationsResponse: Error {}

    return try await shared.skipUnlessSupportedByToolchain(swiftVersion: SwiftVersion(6, 0), file: file, line: line) {
      let project = try await IndexedSingleSwiftFileTestProject(
        """
        protocol TestProtocol {
          func 1️⃣doThing()
        }

        struct TestImpl: TestProtocol {}
        extension TestImpl {
          func 2️⃣doThing() { }
        }
        """
      )

      let response = try await project.testClient.send(
        DefinitionRequest(textDocument: TextDocumentIdentifier(project.fileURI), position: project.positions["1️⃣"])
      )
      guard case .locations(let locations) = response else {
        throw ExpectedLocationsResponse()
      }
      return locations.contains { $0.range == Range(project.positions["2️⃣"]) }
    }
  }

  public static func sourcekitdReturnsRawDocumentationResponse(
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    struct ExpectedMarkdownContentsError: Error {}

    return try await shared.skipUnlessSupportedByToolchain(swiftVersion: SwiftVersion(6, 0), file: file, line: line) {
      // The XML-based doc comment conversion did not preserve `Precondition`.
      let testClient = try await TestSourceKitLSPClient()
      let uri = DocumentURI(for: .swift)
      let positions = testClient.openDocument(
        """
        /// - Precondition: Must have an apple
        func 1️⃣test() {}
        """,
        uri: uri
      )
      let response = try await testClient.send(
        HoverRequest(textDocument: TextDocumentIdentifier(uri), position: positions["1️⃣"])
      )
      let hover = try XCTUnwrap(response, file: file, line: line)
      XCTAssertNil(hover.range, file: file, line: line)
      guard case .markupContent(let content) = hover.contents else {
        throw ExpectedMarkdownContentsError()
      }
      return content.value.contains("Precondition")
    }
  }

  /// Checks whether the index contains a fix that prevents it from adding relations to non-indexed locals
  /// (https://github.com/apple/swift/pull/72930).
  public static func indexOnlyHasContainedByRelationsToIndexedDecls(
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    return try await shared.skipUnlessSupportedByToolchain(swiftVersion: SwiftVersion(6, 0), file: file, line: line) {
      let project = try await IndexedSingleSwiftFileTestProject(
        """
        func foo() {}

        func 1️⃣testFunc(x: String) {
          let myVar = foo
        }
        """
      )
      let prepare = try await project.testClient.send(
        CallHierarchyPrepareRequest(
          textDocument: TextDocumentIdentifier(project.fileURI),
          position: project.positions["1️⃣"]
        )
      )
      let initialItem = try XCTUnwrap(prepare?.only)
      let calls = try await project.testClient.send(CallHierarchyOutgoingCallsRequest(item: initialItem))
      return calls != []
    }
  }

  public static func swiftPMSupportsExperimentalPrepareForIndexing(
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    struct NoSwiftInToolchain: Error {}

    return try await shared.skipUnlessSupportedByToolchain(swiftVersion: SwiftVersion(6, 0), file: file, line: line) {
      guard let swift = await ToolchainRegistry.forTesting.default?.swift else {
        throw NoSwiftInToolchain()
      }

      let result = try await Process.run(
        arguments: [swift.pathString, "build", "--help-hidden"],
        workingDirectory: nil
      )
      guard let output = String(bytes: try result.output.get(), encoding: .utf8) else {
        return false
      }
      return output.contains("--experimental-prepare-for-indexing")
    }
  }

  public static func swiftPMStoresModulesForTargetAndHostInSeparateFolders(
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    struct NoSwiftInToolchain: Error {}

    return try await shared.skipUnlessSupportedByToolchain(swiftVersion: SwiftVersion(6, 0), file: file, line: line) {
      guard let swift = await ToolchainRegistry.forTesting.default?.swift else {
        throw NoSwiftInToolchain()
      }

      let project = try await SwiftPMTestProject(
        files: [
          "Lib/MyFile.swift": """
          public func foo() {}
          """,
          "MyExec/MyExec.swift": """
          import Lib
          func bar() {
            foo()
          }
          """,
          "Plugins/MyPlugin/MyPlugin.swift": "",
        ],
        manifest: """
          let package = Package(
            name: "MyLibrary",
            targets: [
             .target(name: "Lib"),
             .executableTarget(name: "MyExec", dependencies: ["Lib"]),
             .plugin(
               name: "MyPlugin",
               capability: .command(
                 intent: .sourceCodeFormatting(),
                 permissions: []
               ),
               dependencies: ["MyExec"]
             )
            ]
          )
          """
      )
      do {
        // In older version of SwiftPM building `MyPlugin` followed by `Lib` resulted in an error about a redefinition
        // of Lib when building Lib.
        for target in ["MyPlugin", "Lib"] {
          var arguments = [
            swift.pathString, "build", "--package-path", project.scratchDirectory.path, "--target", target,
          ]
          if let globalModuleCache {
            arguments += ["-Xswiftc", "-module-cache-path", "-Xswiftc", globalModuleCache.path]
          }
          try await Process.run(arguments: arguments, workingDirectory: nil)
        }
        return true
      } catch {
        return false
      }
    }
  }

  /// A long test is a test that takes longer than 1-2s to execute.
  public static func longTestsEnabled() throws {
    if let value = ProcessInfo.processInfo.environment["SKIP_LONG_TESTS"], value == "1" || value == "YES" {
      throw XCTSkip("Long tests disabled using the `SKIP_LONG_TESTS` environment variable")
    }
  }

  public static func platformIsDarwin(_ message: String) throws {
    try XCTSkipUnless(Platform.current == .darwin, message)
  }

  public static func platformSupportsTaskPriorityElevation() throws {
    #if os(macOS)
    guard #available(macOS 14.0, *) else {
      // Priority elevation was implemented by https://github.com/apple/swift/pull/63019, which is available in the
      // Swift 5.9 runtime included in macOS 14.0+
      throw XCTSkip("Priority elevation of tasks is only supported on macOS 14 and above")
    }
    #endif
  }

  /// Check if we can use the build artifacts in the sourcekit-lsp build directory to build a macro package without
  /// re-building swift-syntax.
  public static func canBuildMacroUsingSwiftSyntaxFromSourceKitLSPBuild(
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    return try await shared.skipUnlessSupported(file: file, line: line) {
      do {
        let project = try await SwiftPMTestProject(
          files: [
            "MyMacros/MyMacros.swift": #"""
            import SwiftParser

            func test() {
              _ = Parser.parse(source: "let a")
            }
            """#,
            "MyMacroClient/MyMacroClient.swift": """
            """,
          ],
          manifest: SwiftPMTestProject.macroPackageManifest
        )
        try await SwiftPMTestProject.build(at: project.scratchDirectory)
        return .featureSupported
      } catch {
        return .featureUnsupported(
          skipMessage: """
            Skipping because macro could not be built using build artifacts in the sourcekit-lsp build directory. \
            This usually happens if sourcekit-lsp was built using a different toolchain than the one used at test-time.

            Reason:
            \(error)
            """
        )
      }
    }
  }

  public static func canCompileForWasm(
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    return try await shared.skipUnlessSupportedByToolchain(swiftVersion: SwiftVersion(6, 0), file: file, line: line) {
      let swiftFrontend = try await unwrap(ToolchainRegistry.forTesting.default?.swift).parentDirectory
        .appending(component: "swift-frontend")
      return try await withTestScratchDir { scratchDirectory in
        let input = scratchDirectory.appending(component: "Input.swift")
        FileManager.default.createFile(atPath: input.pathString, contents: nil)
        // If we can't compile for wasm, this fails complaining that it can't find the stdlib for wasm.
        let process = Process(
          args: swiftFrontend.pathString,
          "-typecheck",
          input.pathString,
          "-triple",
          "wasm32-unknown-none-wasm",
          "-enable-experimental-feature",
          "Embedded",
          "-Xcc",
          "-fdeclspec"
        )
        try process.launch()
        let result = try await process.waitUntilExit()
        return result.exitStatus == .terminated(code: 0)
      }
    }
  }
}

// MARK: - Parsing Swift compiler version

fileprivate extension String {
  init?(bytes: [UInt8], encoding: Encoding) {
    self = bytes.withUnsafeBytes { buffer in
      guard let baseAddress = buffer.baseAddress else {
        return ""
      }
      let data = Data(bytes: baseAddress, count: buffer.count)
      return String(data: data, encoding: encoding)!
    }
  }
}
