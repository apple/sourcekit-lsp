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
import LanguageServerProtocol
@_spi(Testing) import SKCore
import SourceKitLSP
import TSCBasic

public struct IndexedSingleSwiftFileTestProject {
  enum Error: Swift.Error {
    case swiftcNotFound
  }

  public let testClient: TestSourceKitLSPClient
  public let fileURI: DocumentURI
  public let positions: DocumentPositions
  public let indexDBURL: URL

  /// Writes a single file to a temporary directory on disk and compiles it to index it.
  ///
  /// - Parameters:
  ///   - markedText: The contents of the source file including location markers.
  ///   - allowBuildFailure: Whether to fail if the input source file fails to build or whether to continue the test
  ///     even if the input source is invalid.
  ///   - workspaceDirectory: If specified, the temporary files will be put in this directory. If `nil` a temporary
  ///     scratch directory will be created based on `testName`.
  ///   - cleanUp: Whether to remove the temporary directory when the SourceKit-LSP server shuts down.
  public init(
    _ markedText: String,
    indexSystemModules: Bool = false,
    allowBuildFailure: Bool = false,
    workspaceDirectory: URL? = nil,
    cleanUp: Bool = cleanScratchDirectories,
    testName: String = #function
  ) async throws {
    let testWorkspaceDirectory = try workspaceDirectory ?? testScratchDir(testName: testName)

    let testFileURL = testWorkspaceDirectory.appendingPathComponent("test.swift")
    let indexURL = testWorkspaceDirectory.appendingPathComponent("index")
    self.indexDBURL = testWorkspaceDirectory.appendingPathComponent("index-db")
    guard let swiftc = await ToolchainRegistry.forTesting.default?.swiftc?.asURL else {
      throw Error.swiftcNotFound
    }

    // Create workspace with source file and compile_commands.json

    try extractMarkers(markedText).textWithoutMarkers.write(to: testFileURL, atomically: false, encoding: .utf8)

    var compilerArguments: [String] = [
      testFileURL.path,
      "-index-store-path", indexURL.path,
      "-typecheck",
    ]
    if let globalModuleCache {
      compilerArguments += [
        "-module-cache-path", globalModuleCache.path,
      ]
    }
    if !indexSystemModules {
      compilerArguments.append("-index-ignore-system-modules")
    }

    if let sdk = defaultSDKPath {
      compilerArguments += ["-sdk", sdk]

      // The following are needed so we can import XCTest
      let sdkUrl = URL(fileURLWithPath: sdk)
      let usrLibDir =
        sdkUrl
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("usr")
        .appendingPathComponent("lib")
      let frameworksDir =
        sdkUrl
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Library")
        .appendingPathComponent("Frameworks")
      compilerArguments += [
        "-I", usrLibDir.path,
        "-F", frameworksDir.path,
      ]
    }

    let compilationDatabase = JSONCompilationDatabase(
      [
        JSONCompilationDatabase.Command(
          directory: testWorkspaceDirectory.path,
          filename: testFileURL.path,
          commandLine: [swiftc.path] + compilerArguments
        )
      ]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    try encoder.encode(compilationDatabase).write(
      to: testWorkspaceDirectory.appendingPathComponent("compile_commands.json")
    )

    // Run swiftc to build the index store
    do {
      try await Process.checkNonZeroExit(arguments: [swiftc.path] + compilerArguments)
    } catch {
      if !allowBuildFailure {
        throw error
      }
    }

    // Create the test client
    var options = SourceKitLSPOptions.testDefault()
    options.index = SourceKitLSPOptions.IndexOptions(indexStorePath: indexURL.path, indexDatabasePath: indexDBURL.path)
    self.testClient = try await TestSourceKitLSPClient(
      options: options,
      workspaceFolders: [
        WorkspaceFolder(uri: DocumentURI(testWorkspaceDirectory))
      ],
      cleanUp: {
        if cleanUp {
          try? FileManager.default.removeItem(at: testWorkspaceDirectory)
        }
      }
    )

    // Wait for the indexstore-db to finish indexing
    _ = try await testClient.send(PollIndexRequest())

    // Open the document
    self.fileURI = DocumentURI(testFileURL)
    self.positions = testClient.openDocument(markedText, uri: fileURI)
  }
}
