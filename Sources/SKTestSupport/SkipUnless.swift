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
public enum SkipUnless {
  private enum FeatureCheckResult {
    case featureSupported
    case featureUnsupported(skipMessage: String)
  }

  /// For any feature that has already been evaluated, the result of whether or not it should be skipped.
  private static var checkCache: [String: FeatureCheckResult] = [:]

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
  private static func skipUnlessSupportedByToolchain(
    swiftVersion: SwiftVersion,
    featureName: String = #function,
    file: StaticString,
    line: UInt,
    featureCheck: () async throws -> Bool
  ) async throws {
    let checkResult: FeatureCheckResult
    if let cachedResult = checkCache[featureName] {
      checkResult = cachedResult
    } else if ProcessEnv.block["SWIFTCI_USE_LOCAL_DEPS"] != nil {
      // Never skip tests in CI. Toolchain should be up-to-date
      checkResult = .featureSupported
    } else {
      guard let swiftc = await ToolchainRegistry.forTesting.default?.swiftc else {
        throw SwiftVersionParsingError.failedToFindSwiftc
      }

      let toolchainSwiftVersion = try await getSwiftVersion(swiftc)
      let requiredSwiftVersion = SwiftVersion(swiftVersion.major, swiftVersion.minor)
      if toolchainSwiftVersion < requiredSwiftVersion {
        checkResult = .featureUnsupported(
          skipMessage: """
            Skipping because toolchain has Swift version \(toolchainSwiftVersion) \
            but test requires at least \(requiredSwiftVersion)
            """
        )
      } else if toolchainSwiftVersion == requiredSwiftVersion {
        logger.info("Checking if feature '\(featureName)' is supported")
        if try await !featureCheck() {
          checkResult = .featureUnsupported(skipMessage: "Skipping because toolchain doesn't contain \(featureName)")
        } else {
          checkResult = .featureSupported
        }
        logger.info("Done checking if feature '\(featureName)' is supported")
      } else {
        checkResult = .featureSupported
      }
    }
    checkCache[featureName] = checkResult

    if case .featureUnsupported(let skipMessage) = checkResult {
      throw XCTSkip(skipMessage, file: file, line: line)
    }
  }

  public static func sourcekitdHasSemanticTokensRequest(
    file: StaticString = #file,
    line: UInt = #line
  ) async throws {
    try await skipUnlessSupportedByToolchain(swiftVersion: SwiftVersion(5, 11), file: file, line: line) {
      let testClient = try await TestSourceKitLSPClient()
      let uri = DocumentURI.for(.swift)
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
    file: StaticString = #file,
    line: UInt = #line
  ) async throws {
    try await skipUnlessSupportedByToolchain(swiftVersion: SwiftVersion(5, 11), file: file, line: line) {
      let testClient = try await TestSourceKitLSPClient()
      let uri = DocumentURI.for(.swift)
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

  /// Whether clangd has support for the `workspace/indexedRename` request.
  public static func clangdSupportsIndexBasedRename(
    file: StaticString = #file,
    line: UInt = #line
  ) async throws {
    try await skipUnlessSupportedByToolchain(swiftVersion: SwiftVersion(5, 11), file: file, line: line) {
      let testClient = try await TestSourceKitLSPClient()
      let uri = DocumentURI.for(.c)
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
  /// https://github.com/apple/swift-package-manager/pull/7103.
  ///
  /// sourcekit-lsp uses the built-in SwiftPM to synthesize compiler arguments and cross-module tests fail if the host
  /// toolchain’s SwiftPM stores the Swift modules on the top level but we synthesize compiler arguments expecting the
  /// modules to be in a `Modules` subdirectory.
  public static func swiftpmStoresModulesInSubdirectory(
    file: StaticString = #file,
    line: UInt = #line
  ) async throws {
    try await skipUnlessSupportedByToolchain(swiftVersion: SwiftVersion(5, 11), file: file, line: line) {
      let workspace = try await SwiftPMTestProject(
        files: ["test.swift": ""],
        build: true
      )
      let modulesDirectory = workspace.scratchDirectory
        .appendingPathComponent(".build")
        .appendingPathComponent("debug")
        .appendingPathComponent("Modules")
        .appendingPathComponent("MyLibrary.swiftmodule")
      return FileManager.default.fileExists(atPath: modulesDirectory.path)
    }
  }

  public static func toolchainContainsSwiftFormat(
    file: StaticString = #file,
    line: UInt = #line
  ) async throws {
    try await skipUnlessSupportedByToolchain(swiftVersion: SwiftVersion(5, 11), file: file, line: line) {
      return await ToolchainRegistry.forTesting.default?.swiftFormat != nil
    }
  }

  public static func sourcekitdReturnsRawDocumentationResponse(
    file: StaticString = #file,
    line: UInt = #line
  ) async throws {
    struct ExpectedMarkdownContentsError: Error {}

    return try await skipUnlessSupportedByToolchain(swiftVersion: SwiftVersion(6, 0), file: file, line: line) {
      // The XML-based doc comment conversion did not preserve `Precondition`.
      let testClient = try await TestSourceKitLSPClient()
      let uri = DocumentURI.for(.swift)
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

  public static func longTestsEnabled() throws {
    if let value = ProcessInfo.processInfo.environment["SKIP_LONG_TESTS"], value == "1" || value == "YES" {
      throw XCTSkip("Long tests disabled using the `SKIP_LONG_TESTS` environment variable")
    }
  }

  public static func platformIsDarwin(_ message: String) throws {
    try XCTSkipUnless(Platform.current == .darwin, message)
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

/// A Swift version consisting of the major and minor component.
fileprivate struct SwiftVersion: Comparable, CustomStringConvertible {
  let major: Int
  let minor: Int

  static func < (lhs: SwiftVersion, rhs: SwiftVersion) -> Bool {
    return (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
  }

  init(_ major: Int, _ minor: Int) {
    self.major = major
    self.minor = minor
  }

  var description: String {
    return "\(major).\(minor)"
  }
}

fileprivate enum SwiftVersionParsingError: Error, CustomStringConvertible {
  case failedToFindSwiftc
  case failedToParseOutput(output: String?)

  var description: String {
    switch self {
    case .failedToFindSwiftc:
      return "Default toolchain does not contain a swiftc executable"
    case .failedToParseOutput(let output):
      return """
        Failed to parse Swift version. Output of swift --version:
        \(output ?? "<empty>")
        """
    }
  }
}

/// Return the major and minor version of Swift for a `swiftc` compiler at `swiftcPath`.
private func getSwiftVersion(_ swiftcPath: AbsolutePath) async throws -> SwiftVersion {
  let process = Process(args: swiftcPath.pathString, "--version")
  try process.launch()
  let result = try await process.waitUntilExit()
  let output = String(bytes: try result.output.get(), encoding: .utf8)
  let regex = Regex {
    "Swift version "
    Capture { OneOrMore(.digit) }
    "."
    Capture { OneOrMore(.digit) }
  }
  guard let match = output?.firstMatch(of: regex) else {
    throw SwiftVersionParsingError.failedToParseOutput(output: output)
  }
  guard let major = Int(match.1), let minor = Int(match.2) else {
    throw SwiftVersionParsingError.failedToParseOutput(output: output)
  }
  return SwiftVersion(major, minor)
}
