//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Build
import BuildServerProtocol
import Dispatch
import LSPLogging
import LanguageServerProtocol
import PackageGraph
import PackageLoading
import PackageModel
import SKCore
import SKSupport
import SourceControl
import Workspace

import struct Basics.AbsolutePath
import struct Basics.TSCAbsolutePath
import struct Foundation.URL
import protocol TSCBasic.FileSystem
import var TSCBasic.localFileSystem
import func TSCBasic.resolveSymlinks

#if canImport(SPMBuildCore)
import SPMBuildCore
#endif

/// Parameter of `reloadPackageStatusCallback` in ``SwiftPMWorkspace``.
///
/// Informs the callback about whether `reloadPackage` started or finished executing.
public enum ReloadPackageStatus {
  case start
  case end
}

/// Same as `toolchainRegistry.default`.
///
/// Needed to work around a compiler crash that prevents us from accessing `toolchainRegistry.default` in
/// `SwiftPMWorkspace.init`.
private func getDefaultToolchain(_ toolchainRegistry: ToolchainRegistry) async -> SKCore.Toolchain? {
  return await toolchainRegistry.default
}

/// Swift Package Manager build system and workspace support.
///
/// This class implements the `BuildSystem` interface to provide the build settings for a Swift
/// Package Manager (SwiftPM) package. The settings are determined by loading the Package.swift
/// manifest using `libSwiftPM` and constructing a build plan using the default (debug) parameters.
public actor SwiftPMWorkspace {

  public enum Error: Swift.Error {

    /// Could not find a manifest (Package.swift file). This is not a package.
    case noManifest(workspacePath: TSCAbsolutePath)

    /// Could not determine an appropriate toolchain for swiftpm to use for manifest loading.
    case cannotDetermineHostToolchain
  }

  /// Delegate to handle any build system events.
  public weak var delegate: SKCore.BuildSystemDelegate? = nil

  public func setDelegate(_ delegate: SKCore.BuildSystemDelegate?) async {
    self.delegate = delegate
  }

  let workspacePath: TSCAbsolutePath
  let packageRoot: TSCAbsolutePath
  /// *Public for testing*
  public var _packageRoot: TSCAbsolutePath { packageRoot }
  var packageGraph: PackageGraph
  let workspace: Workspace
  public let buildParameters: BuildParameters
  let fileSystem: FileSystem

  var fileToTarget: [AbsolutePath: TargetBuildDescription] = [:]
  var sourceDirToTarget: [AbsolutePath: TargetBuildDescription] = [:]

  /// The URIs for which the delegate has registered for change notifications,
  /// mapped to the language the delegate specified when registering for change notifications.
  var watchedFiles: Set<DocumentURI> = []

  /// This callback is informed when `reloadPackage` starts and ends executing.
  var reloadPackageStatusCallback: (ReloadPackageStatus) async -> Void

  /// Creates a build system using the Swift Package Manager, if this workspace is a package.
  ///
  /// - Parameters:
  ///   - workspace: The workspace root path.
  ///   - toolchainRegistry: The toolchain registry to use to provide the Swift compiler used for
  ///     manifest parsing and runtime support.
  ///   - reloadPackageStatusCallback: Will be informed when `reloadPackage` starts and ends executing.
  /// - Throws: If there is an error loading the package, or no manifest is found.
  public init(
    workspacePath: TSCAbsolutePath,
    toolchainRegistry: ToolchainRegistry,
    fileSystem: FileSystem = localFileSystem,
    buildSetup: BuildSetup,
    reloadPackageStatusCallback: @escaping (ReloadPackageStatus) async -> Void = { _ in }
  ) async throws {
    self.workspacePath = workspacePath
    self.fileSystem = fileSystem

    guard let packageRoot = findPackageDirectory(containing: workspacePath, fileSystem) else {
      throw Error.noManifest(workspacePath: workspacePath)
    }

    self.packageRoot = try resolveSymlinks(packageRoot)

    guard let destinationToolchainBinDir = await getDefaultToolchain(toolchainRegistry)?.swiftc?.parentDirectory else {
      throw Error.cannotDetermineHostToolchain
    }

    let swiftSDK = try SwiftSDK.hostSwiftSDK(AbsolutePath(destinationToolchainBinDir))
    let toolchain = try UserToolchain(swiftSDK: swiftSDK)

    var location = try Workspace.Location(
      forRootPackage: AbsolutePath(packageRoot),
      fileSystem: fileSystem
    )
    if let scratchDirectory = buildSetup.path {
      location.scratchDirectory = AbsolutePath(scratchDirectory)
    }

    var configuration = WorkspaceConfiguration.default
    configuration.skipDependenciesUpdates = true

    self.workspace = try Workspace(
      fileSystem: fileSystem,
      location: location,
      configuration: configuration,
      customHostToolchain: toolchain
    )

    let buildConfiguration: PackageModel.BuildConfiguration
    switch buildSetup.configuration {
    case .debug, nil:
      buildConfiguration = .debug
    case .release:
      buildConfiguration = .release
    }

    self.buildParameters = try BuildParameters(
      dataPath: location.scratchDirectory.appending(component: toolchain.targetTriple.platformBuildPathComponent),
      configuration: buildConfiguration,
      toolchain: toolchain,
      flags: buildSetup.flags
    )

    self.packageGraph = try PackageGraph(rootPackages: [], dependencies: [], binaryArtifacts: [:])
    self.reloadPackageStatusCallback = reloadPackageStatusCallback

    try await reloadPackage()
  }

  /// Creates a build system using the Swift Package Manager, if this workspace is a package.
  ///
  /// - Parameters:
  ///   - reloadPackageStatusCallback: Will be informed when `reloadPackage` starts and ends executing.
  /// - Returns: nil if `workspacePath` is not part of a package or there is an error.
  public init?(
    url: URL,
    toolchainRegistry: ToolchainRegistry,
    buildSetup: BuildSetup,
    reloadPackageStatusCallback: @escaping (ReloadPackageStatus) async -> Void
  ) async {
    do {
      try await self.init(
        workspacePath: try TSCAbsolutePath(validating: url.path),
        toolchainRegistry: toolchainRegistry,
        fileSystem: localFileSystem,
        buildSetup: buildSetup,
        reloadPackageStatusCallback: reloadPackageStatusCallback
      )
    } catch Error.noManifest(let path) {
      logger.error("could not find manifest, or not a SwiftPM package: \(path)")
      return nil
    } catch {
      logger.error("failed to create SwiftPMWorkspace at \(url.path): \(error.forLogging)")
      return nil
    }
  }
}

extension SwiftPMWorkspace {

  /// (Re-)load the package settings by parsing the manifest and resolving all the targets and
  /// dependencies.
  func reloadPackage() async throws {
    await reloadPackageStatusCallback(.start)

    let observabilitySystem = ObservabilitySystem({ scope, diagnostic in
      logger.log(level: diagnostic.severity.asLogLevel, "SwiftPM log: \(diagnostic.description)")
    })

    let packageGraph = try self.workspace.loadPackageGraph(
      rootInput: PackageGraphRootInput(packages: [AbsolutePath(packageRoot)]),
      forceResolvedVersions: true,
      observabilityScope: observabilitySystem.topScope
    )

    let plan = try BuildPlan(
      buildParameters: buildParameters,
      graph: packageGraph,
      fileSystem: fileSystem,
      observabilityScope: observabilitySystem.topScope
    )

    /// Make sure to execute any throwing statements before setting any
    /// properties because otherwise we might end up in an inconsistent state
    /// with only some properties modified.
    self.packageGraph = packageGraph

    self.fileToTarget = [AbsolutePath: TargetBuildDescription](
      packageGraph.allTargets.flatMap { target in
        return target.sources.paths.compactMap {
          guard let td = plan.targetMap[target] else {
            return nil
          }
          return (key: $0, value: td)
        }
      },
      uniquingKeysWith: { td, _ in
        // FIXME: is there  a preferred target?
        return td
      }
    )

    self.sourceDirToTarget = [AbsolutePath: TargetBuildDescription](
      packageGraph.allTargets.compactMap { target in
        guard let td = plan.targetMap[target] else {
          return nil
        }
        return (key: target.sources.root, value: td)
      },
      uniquingKeysWith: { td, _ in
        // FIXME: is there  a preferred target?
        return td
      }
    )

    guard let delegate = self.delegate else {
      await reloadPackageStatusCallback(.end)
      return
    }
    await delegate.fileBuildSettingsChanged(self.watchedFiles)
    await delegate.fileHandlingCapabilityChanged()
    await reloadPackageStatusCallback(.end)
  }
}

extension SwiftPMWorkspace: SKCore.BuildSystem {

  public var buildPath: TSCAbsolutePath {
    return TSCAbsolutePath(buildParameters.buildPath)
  }

  public var indexStorePath: TSCAbsolutePath? {
    return buildParameters.indexStoreMode == .off ? nil : TSCAbsolutePath(buildParameters.indexStore)
  }

  public var indexDatabasePath: TSCAbsolutePath? {
    return buildPath.appending(components: "index", "db")
  }

  public var indexPrefixMappings: [PathPrefixMapping] { return [] }

  /// **Public for testing only**
  public func _settings(
    for uri: DocumentURI,
    _ language: Language
  ) throws -> FileBuildSettings? {
    try self.buildSettings(for: uri, language: language)
  }

  public func buildSettings(for uri: DocumentURI, language: Language) throws -> FileBuildSettings? {
    guard let url = uri.fileURL else {
      // We can't determine build settings for non-file URIs.
      return nil
    }
    guard let path = try? AbsolutePath(validating: url.path) else {
      return nil
    }

    if let td = try targetDescription(for: path) {
      return try settings(for: path, language, td)
    }

    if path.basename == "Package.swift" {
      return try settings(forPackageManifest: path)
    }

    if path.extension == "h" {
      return try settings(forHeader: path, language)
    }

    return nil
  }

  public func registerForChangeNotifications(for uri: DocumentURI) async {
    self.watchedFiles.insert(uri)
  }

  /// Unregister the given file for build-system level change notifications, such as command
  /// line flag changes, dependency changes, etc.
  public func unregisterForChangeNotifications(for uri: DocumentURI) {
    self.watchedFiles.remove(uri)
  }

  /// Returns the resolved target description for the given file, if one is known.
  private func targetDescription(for file: AbsolutePath) throws -> TargetBuildDescription? {
    if let td = fileToTarget[file] {
      return td
    }

    let realpath = try resolveSymlinks(file)
    if realpath != file, let td = fileToTarget[realpath] {
      fileToTarget[file] = td
      return td
    }

    return nil
  }

  /// An event is relevant if it modifies a file that matches one of the file rules used by the SwiftPM workspace.
  private func fileEventShouldTriggerPackageReload(event: FileEvent) -> Bool {
    guard let fileURL = event.uri.fileURL else {
      return false
    }
    switch event.type {
    case .created, .deleted:
      guard let path = try? AbsolutePath(validating: fileURL.path) else {
        return false
      }

      return self.workspace.fileAffectsSwiftOrClangBuildSettings(
        filePath: path,
        packageGraph: self.packageGraph
      )
    case .changed:
      return fileURL.lastPathComponent == "Package.swift"
    default:  // Unknown file change type
      return false
    }
  }

  public func filesDidChange(_ events: [FileEvent]) async {
    if events.contains(where: { self.fileEventShouldTriggerPackageReload(event: $0) }) {
      await orLog("Reloading package") {
        // TODO: It should not be necessary to reload the entire package just to get build settings for one file.
        try await self.reloadPackage()
      }
    }
  }

  public func fileHandlingCapability(for uri: DocumentURI) -> FileHandlingCapability {
    guard let fileUrl = uri.fileURL else {
      return .unhandled
    }
    if (try? targetDescription(for: AbsolutePath(validating: fileUrl.path))) != nil {
      return .handled
    } else {
      return .unhandled
    }
  }
}

extension SwiftPMWorkspace {

  // MARK: Implementation details

  /// Retrieve settings for the given file, which is part of a known target build description.
  public func settings(
    for path: AbsolutePath,
    _ language: Language,
    _ td: TargetBuildDescription
  ) throws -> FileBuildSettings? {
    switch (td, language) {
    case (.swift(let td), .swift):
      return try settings(forSwiftFile: path, td)
    case (.clang, .swift):
      return nil
    case (.clang(let td), _):
      return try settings(forClangFile: path, language, td)
    default:
      return nil
    }
  }

  /// Retrieve settings for a package manifest (Package.swift).
  private func settings(forPackageManifest path: AbsolutePath) throws -> FileBuildSettings? {
    func impl(_ path: AbsolutePath) -> FileBuildSettings? {
      for package in packageGraph.packages where path == package.manifest.path {
        let compilerArgs = workspace.interpreterFlags(for: package.path) + [path.pathString]
        return FileBuildSettings(compilerArguments: compilerArgs)
      }
      return nil
    }

    if let result = impl(path) {
      return result
    }

    let canonicalPath = try resolveSymlinks(path)
    return canonicalPath == path ? nil : impl(canonicalPath)
  }

  /// Retrieve settings for a given header file.
  private func settings(forHeader path: AbsolutePath, _ language: Language) throws -> FileBuildSettings? {
    func impl(_ path: AbsolutePath) throws -> FileBuildSettings? {
      var dir = path.parentDirectory
      while !dir.isRoot {
        if let td = sourceDirToTarget[dir] {
          return try settings(for: path, language, td)
        }
        dir = dir.parentDirectory
      }
      return nil
    }

    if let result = try impl(path) {
      return result
    }

    let canonicalPath = try resolveSymlinks(path)
    return try canonicalPath == path ? nil : impl(canonicalPath)
  }

  /// Retrieve settings for the given swift file, which is part of a known target build description.
  public func settings(
    forSwiftFile path: AbsolutePath,
    _ td: SwiftTargetBuildDescription
  ) throws -> FileBuildSettings {
    // FIXME: this is re-implementing llbuild's constructCommandLineArgs.
    var args: [String] = [
      "-module-name",
      td.target.c99name,
      "-incremental",
      "-emit-dependencies",
      "-emit-module",
      "-emit-module-path",
      td.modulesPath.appending(component: "\(td.target.c99name).swiftmodule").pathString,
      // -output-file-map <path>
    ]
    if td.target.type == .library || td.target.type == .test {
      args += ["-parse-as-library"]
    }
    args += ["-c"]
    args += td.sources.map { $0.pathString }
    args += ["-I", td.modulesPath.pathString]
    args += try td.compileArguments()

    return FileBuildSettings(
      compilerArguments: args,
      workingDirectory: workspacePath.pathString
    )
  }

  /// Retrieve settings for the given C-family language file, which is part of a known target build
  /// description.
  ///
  /// - Note: language must be a C-family language.
  public func settings(
    forClangFile path: AbsolutePath,
    _ language: Language,
    _ td: ClangTargetBuildDescription
  ) throws -> FileBuildSettings {
    // FIXME: this is re-implementing things from swiftpm's createClangCompileTarget

    var args = try td.basicArguments()

    let nativePath: AbsolutePath =
      try URL(fileURLWithPath: path.pathString).withUnsafeFileSystemRepresentation {
        try AbsolutePath(validating: String(cString: $0!))
      }
    let compilePath = try td.compilePaths().first(where: { $0.source == nativePath })
    if let compilePath = compilePath {
      args += [
        "-MD",
        "-MT",
        "dependencies",
        "-MF",
        compilePath.deps.pathString,
      ]
    }

    switch language {
    case .c:
      if let std = td.clangTarget.cLanguageStandard {
        args += ["-std=\(std)"]
      }
    case .cpp:
      if let std = td.clangTarget.cxxLanguageStandard {
        args += ["-std=\(std)"]
      }
    default:
      break
    }

    if let compilePath = compilePath {
      args += [
        "-c",
        compilePath.source.pathString,
        "-o",
        compilePath.object.pathString,
      ]
    } else if path.extension == "h" {
      args += ["-c"]
      if let xflag = language.xflagHeader {
        args += ["-x", xflag]
      }
      args += [path.pathString]
    } else {
      args += [
        "-c",
        path.pathString,
      ]
    }

    return FileBuildSettings(
      compilerArguments: args,
      workingDirectory: workspacePath.pathString
    )
  }
}

/// Find a Swift Package root directory that contains the given path, if any.
private func findPackageDirectory(
  containing path: TSCAbsolutePath,
  _ fileSystem: FileSystem
) -> TSCAbsolutePath? {
  var path = path
  while true {
    let packagePath = path.appending(component: "Package.swift")
    if fileSystem.isFile(packagePath) {
      let contents = try? fileSystem.readFileContents(packagePath)
      if contents?.cString.contains("PackageDescription") == true {
        return path
      }
    }

    if path.isRoot {
      return nil
    }
    path = path.parentDirectory
  }
  return path
}

extension Basics.Diagnostic.Severity {
  var asLogLevel: LogLevel {
    switch self {
    case .error, .warning: return .default
    case .info: return .info
    case .debug: return .debug
    }
  }
}
