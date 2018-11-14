//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import LanguageServerProtocol
import SKCore
import SKSupport
import IndexStoreDB
import Basic
import SKSwiftPMWorkspace

/// Represents the configuration and sate of a project or combination of projects being worked on
/// together.
///
/// In LSP, this represents the per-workspace state that is typically only available after the
/// "initialize" request has been made.
///
/// Typically a workspace is contained in a root directory, and may be represented by an
/// `ExternalWorkspace` if this workspace is part of a workspace in another tool such as a swiftpm
/// package.
public final class Workspace {

  /// The root directory of the workspace.
  public let rootPath: AbsolutePath?

  public let clientCapabilities: ClientCapabilities

  /// The external workspace connection, if any.
  public let external: ExternalWorkspace?

  /// The build settings provider to use for documents in this workspace.
  ///
  /// If `external` is not `nil`, this will typically include `external.buildSystem`. It may also
  /// provide settings for files outside the workspace using additional providers.
  public let buildSettings: BuildSettingsProvider

  /// The source code index, if available.
  public var index: IndexStoreDB? = nil

  /// Open documents.
  let documentManager = DocumentManager()

  /// Language service for an open document, if available.
  var documentService: [URL: Connection] = [:]

  public init(
    rootPath: AbsolutePath?,
    clientCapabilities: ClientCapabilities,
    external: ExternalWorkspace?,
    buildSettings: BuildSettingsProvider,
    index: IndexStoreDB?)
  {
    self.rootPath = rootPath
    self.clientCapabilities = clientCapabilities
    self.external = external
    self.buildSettings = buildSettings
    self.index = index
  }

  /// Creates a workspace for a given root `URL`, inferring the `ExternalWorkspace` if possible.
  ///
  /// - Parameters:
  ///   - url: The root directory of the workspace, which must be a valid path.
  ///   - clientCapabilities: The client capabilities provided during server initialization.
  ///   - toolchainRegistry: The toolchain registry.
  public init(
    url: URL,
    clientCapabilities: ClientCapabilities,
    toolchainRegistry: ToolchainRegistry
  ) throws {

    self.rootPath = try AbsolutePath(validating: url.path)
    self.clientCapabilities = clientCapabilities
    self.external = SwiftPMWorkspace(url: url, toolchainRegistry: toolchainRegistry)

    let settings = BuildSettingsProviderList()
    self.buildSettings = settings

    settings.providers.insert(CompilationDatabaseBuildSystem(projectRoot: rootPath), at: 0)

    guard let external = self.external else {
      return
    }

    settings.providers.insert(external.buildSystem, at: 0)

    if let storePath = external.indexStorePath,
       let dbPath = external.indexDatabasePath,
       let libPath = toolchainRegistry.default?.libIndexStore
    {
      do {
        let lib = try IndexStoreLibrary(dylibPath: libPath.asString)
        self.index = try IndexStoreDB(storePath: storePath.asString, databasePath: dbPath.asString, library: lib)
        log("opened IndexStoreDB at \(dbPath.asString) with store path \(storePath.asString)")
      } catch {
        log("failed to open IndexStoreDB: \(error.localizedDescription)", level: .error)
      }
    }
  }
}
