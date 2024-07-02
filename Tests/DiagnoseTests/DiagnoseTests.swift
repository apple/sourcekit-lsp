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

@_spi(Testing) import Diagnose
import Foundation
import LSPLogging
import LSPTestSupport
@_spi(Testing) import SKCore
import SKTestSupport
import SourceKitD
import XCTest

import struct TSCBasic.AbsolutePath

/// If a default SDK is present on the test machine, return the `-sdk` argument that can be placed in the request
/// YAML. Otherwise, return an empty string.
private let sdkArg: String = {
  if let sdk = defaultSDKPath {
    return """
      "-sdk", "\(sdk)",
      """
  } else {
    return ""
  }
}()

/// If a default SDK is present on the test machine, return the `-sdk` argument that can be placed in the request
/// YAML. Otherwise, return an empty string.
private let sdkArgs: [String] = {
  if let sdk = defaultSDKPath {
    return ["-sdk", "\(sdk)"]
  } else {
    return []
  }
}()

final class DiagnoseTests: XCTestCase {
  func testRemoveCodeItemsAndMembers() async throws {
    // We consider the test case reproducing if cursor info returns the two ambiguous results including their doc
    // comments.
    // We should strip away unrelated declarations and statements.
    try await assertReduceSourceKitD(
      """
      func test() {
        let foo = Foo()
        print("test")
        foo.1️⃣ambiguous()
      }

      struct Foo {
        /// Returns an integer
        func ambiguous() -> Int {
          return 1 + 2
        }

        /// Returns a string
        func ambiguous() -> String {
          // a unrelated comment
          return "abc"
        }

        func unrelated() {}
      }

      struct UnrelatedStruct {}
      """,
      request: """
        {
          key.request: source.request.cursorinfo,
          key.compilerargs: [
            "$FILE",
            \(sdkArg)
          ],
          key.offset: $OFFSET,
          key.sourcefile: "$FILE"
        }
        """,
      reproducerPredicate: { $0.contains("Returns an integer") && $0.contains("Returns a string") },
      expectedReducedFileContents: """
        func test() {
          let foo = Foo()
          foo.ambiguous()
        }

        struct Foo {
          /// Returns an integer
          func ambiguous() -> Int {
          }

          /// Returns a string
          func ambiguous() -> String {
          }
        }
        """
    )
  }

  func testRemoveComments() async throws {
    try await assertReduceSourceKitD(
      """
      /// Doc comment
      func test() {
        // Comment
        let foo = 1️⃣Foo()
      }

      /*
       Block comment
       With another line
      */
      struct Foo {

      }
      """,
      request: """
        {
          key.request: source.request.cursorinfo,
          key.compilerargs: [
            "$FILE",
            \(sdkArg)
          ],
          key.offset: $OFFSET,
          key.sourcefile: "$FILE"
        }
        """,
      reproducerPredicate: { $0.contains("Foo") },
      expectedReducedFileContents: """
        func test() {
            let foo = Foo()
        }

        struct Foo {

        }
        """
    )
  }

  @MainActor
  func testReduceFrontend() async throws {
    try await withTestScratchDir { scratchDir in
      let fileAContents = """
        func makeThing() -> Int { 1 }

        func test() { let b = makeThing() }
        func unrelatedA() {}
        """

      let fileBContents = """
        func makeThing() -> String { "" }

        func unrelatedB() {}
        """

      let fileAPath = scratchDir.appending(component: "a.swift").pathString
      let fileBPath = scratchDir.appending(component: "b.swift").pathString

      try fileAContents.write(toFile: fileAPath, atomically: true, encoding: .utf8)
      try fileBContents.write(toFile: fileBPath, atomically: true, encoding: .utf8)

      let toolchain = try await unwrap(ToolchainRegistry.forTesting.default)

      let requestExecutor = try InProcessSourceKitRequestExecutor(
        toolchain: toolchain,
        reproducerPredicate: NSPredicate(block: { (result, _) -> Bool in
          guard let dict = (result as? [String: Any]) else {
            return false
          }
          guard let stderr = dict["stderr"] as? String else {
            return false
          }
          return stderr.contains("ambiguous use of 'makeThing()'")
        })
      )

      var lastProgress = 0.0
      // '-swift-version 5' is irrelevant and should get removed by the reducer.
      let frontendArgs = ["-typecheck", fileAPath, fileBPath, "-swift-version", "5"] + sdkArgs
      let reduced = try await reduceFrontendIssue(
        frontendArgs: frontendArgs,
        using: requestExecutor,
        progressUpdate: { progress, _ in
          XCTAssertLessThanOrEqual(lastProgress, progress)
          lastProgress = progress
        }
      )

      XCTAssertEqual(
        reduced.fileContents,
        """
        func makeThing() -> Int { }

        func test() { let b = makeThing() }



        func makeThing() -> String { }
        """
      )

      // When running swift-frontend from an Xcode toolchain, the -sdk argument is required to find the stdlib.
      // When running using an open source toolchain snapshot or on Linux, the SDK is found next to the compiler and the
      // -sdk argument is not required.
      XCTAssert(
        reduced.compilerArgs == ["-typecheck", "$FILE"] || reduced.compilerArgs == ["-typecheck"] + sdkArgs + ["$FILE"]
      )
    }
  }
}

/// Check that reducing `request` with the given file contents results in `expectedReducedFileContents`.
///
/// - Parameters:
///   - markedFileContents: The contents of the files that should be reduced. Must contain a 1️⃣ location marker, which
///     will be used to substitute `$OFFSET` in `request`.
///   - request: The YAML sourcekitd request that should be reduced. May contain the following placeholders:
///     - `$FILE`: The path of the input file
///     - `$OFFSET`: The UTF-8 offset of the 1️⃣ location marker in `markedFileContents`
///   - reproducerPredicate: A predicate that indicates whether a run request reproduces the issue.
///   - expectedReducedFileContents: The contents of the file that the reducer is expected to produce.
@MainActor
private func assertReduceSourceKitD(
  _ markedFileContents: String,
  request: String,
  reproducerPredicate: @Sendable @escaping (String) -> Bool,
  expectedReducedFileContents: String,
  file: StaticString = #filePath,
  line: UInt = #line
) async throws {
  let (markers, fileContents) = extractMarkers(markedFileContents)

  let toolchain = try await unwrap(ToolchainRegistry.forTesting.default)
  logger.debug("Using \(toolchain.path?.pathString ?? "<nil>") to reduce source file")

  let markerOffset = try XCTUnwrap(markers["1️⃣"], "Failed to find position marker 1️⃣ in file contents")

  try await withTestScratchDir { scratchDir in
    let requestExecutor = try InProcessSourceKitRequestExecutor(
      toolchain: toolchain,
      reproducerPredicate: NSPredicate(block: { (requestResponse, _) -> Bool in
        reproducerPredicate(requestResponse as! String)
      })
    )
    let testFilePath = scratchDir.appending(component: "test.swift").pathString
    try fileContents.write(toFile: testFilePath, atomically: false, encoding: .utf8)

    let request =
      request
      .replacingOccurrences(of: "$FILE", with: testFilePath)
      .replacingOccurrences(of: "$OFFSET", with: String(markerOffset))

    let requestInfo = try RequestInfo(request: request)
    var lastProgress = 0.0
    let reduced = try await requestInfo.reduceInputFile(
      using: requestExecutor,
      progressUpdate: { progress, _ in
        XCTAssertLessThanOrEqual(lastProgress, progress, file: file, line: line)
        lastProgress = progress
      }
    )

    XCTAssertEqual(reduced.fileContents, expectedReducedFileContents, file: file, line: line)
  }
}

/// We can't run the `OutOfProcessSourceKitRequestExecutor` in tests because that runs the sourcekit-lsp executable,
/// which isn't built when running tests.
private class InProcessSourceKitRequestExecutor: SourceKitRequestExecutor {
  /// The path to `sourcekitd.framework/sourcekitd`.
  private let sourcekitd: URL

  /// The path to `swift-frontend`.
  private let swiftFrontend: URL

  /// The file to which we write the reduce source file.
  private let temporarySourceFile: URL

  /// The file to which we write the AYML request that we want to run.
  private let temporaryRequestFile: URL

  /// If this predicate evaluates to true on the sourcekitd response, the request is
  /// considered to reproduce the issue.
  private let reproducerPredicate: NSPredicate

  init(toolchain: Toolchain, reproducerPredicate: NSPredicate) throws {
    self.sourcekitd = try XCTUnwrap(toolchain.sourcekitd?.asURL)
    self.swiftFrontend = try XCTUnwrap(toolchain.swiftFrontend)
    self.reproducerPredicate = reproducerPredicate
    temporaryRequestFile = FileManager.default.temporaryDirectory.appendingPathComponent("request-\(UUID()).yml")
    temporarySourceFile = FileManager.default.temporaryDirectory.appendingPathComponent("reduce-\(UUID()).swift")
  }

  deinit {
    try? FileManager.default.removeItem(at: temporaryRequestFile)
    try? FileManager.default.removeItem(at: temporarySourceFile)
  }

  func runSwiftFrontend(request: RequestInfo) async throws -> SourceKitDRequestResult {
    return try await OutOfProcessSourceKitRequestExecutor(
      sourcekitd: sourcekitd,
      swiftFrontend: swiftFrontend,
      reproducerPredicate: reproducerPredicate
    ).runSwiftFrontend(request: request)
  }

  func runSourceKitD(request: RequestInfo) async throws -> SourceKitDRequestResult {
    try request.fileContents.write(to: temporarySourceFile, atomically: true, encoding: .utf8)
    let requestString = try request.request(for: temporarySourceFile)
    logger.info("Sending request: \(requestString)")

    let sourcekitd = try await DynamicallyLoadedSourceKitD.getOrCreate(
      dylibPath: try! AbsolutePath(validating: sourcekitd.path)
    )
    let response = try await sourcekitd.run(requestYaml: requestString)

    logger.info("Received response: \(response.description)")

    switch response.error {
    case .requestFailed, .requestInvalid, .requestCancelled, .timedOut, .missingRequiredSymbol, .connectionInterrupted:
      return .error
    case nil:
      if reproducerPredicate.evaluate(with: response.description) {
        return .reproducesIssue
      }
      return .success(response: response.description)
    }
  }
}
