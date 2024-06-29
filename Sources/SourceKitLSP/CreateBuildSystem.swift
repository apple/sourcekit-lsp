//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import LSPLogging
import LanguageServerProtocol
import SKCore
import SKSwiftPMWorkspace

import struct TSCBasic.AbsolutePath
import struct TSCBasic.RelativePath

/// Tries to create a build system for a workspace at the given location, with the given parameters.
func createBuildSystem(
  rootUri: DocumentURI,
  options: SourceKitLSPOptions,
  testHooks: TestHooks,
  toolchainRegistry: ToolchainRegistry,
  reloadPackageStatusCallback: @Sendable @escaping (ReloadPackageStatus) async -> Void
) async -> BuildSystem? {
  guard let rootUrl = rootUri.fileURL, let rootPath = try? AbsolutePath(validating: rootUrl.path) else {
    // We assume that workspaces are directories. This is only true for URLs not for URIs in general.
    // Simply skip setting up the build integration in this case.
    logger.error(
      "Cannot setup build integration at URI \(rootUri.forLogging) because the URI it is not a valid file URL"
    )
    return nil
  }
  func createSwiftPMBuildSystem(rootUri: DocumentURI) async -> SwiftPMBuildSystem? {
    return await SwiftPMBuildSystem(
      uri: rootUri,
      toolchainRegistry: toolchainRegistry,
      options: options,
      reloadPackageStatusCallback: reloadPackageStatusCallback,
      testHooks: testHooks.swiftpmTestHooks
    )
  }

  func createCompilationDatabaseBuildSystem(rootPath: AbsolutePath) -> CompilationDatabaseBuildSystem? {
    return CompilationDatabaseBuildSystem(
      projectRoot: rootPath,
      searchPaths: (options.compilationDatabase.searchPaths ?? []).compactMap { try? RelativePath(validating: $0) }
    )
  }

  func createBuildServerBuildSystem(rootPath: AbsolutePath) async -> BuildServerBuildSystem? {
    return await BuildServerBuildSystem(projectRoot: rootPath)
  }

  let defaultBuildSystem: BuildSystem? =
    switch options.defaultWorkspaceType {
    case .buildServer: await createBuildServerBuildSystem(rootPath: rootPath)
    case .compilationDatabase: createCompilationDatabaseBuildSystem(rootPath: rootPath)
    case .swiftPM: await createSwiftPMBuildSystem(rootUri: rootUri)
    case nil: nil
    }
  if let defaultBuildSystem {
    return defaultBuildSystem
  } else if let buildServer = await createBuildServerBuildSystem(rootPath: rootPath) {
    return buildServer
  } else if let swiftpm = await createSwiftPMBuildSystem(rootUri: rootUri) {
    return swiftpm
  } else if let compdb = createCompilationDatabaseBuildSystem(rootPath: rootPath) {
    return compdb
  } else {
    logger.error("Could not set up a build system at '\(rootUri.forLogging)'")
    return nil
  }
}
