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

#if canImport(SPMBuildCore)
import SPMBuildCore
#endif
import Build
import BuildServerProtocol
import LanguageServerProtocol
import LSPLogging
import PackageGraph
import PackageLoading
import PackageModel
import SourceControl
import SKCore
import SKSupport
import Workspace
import Dispatch
import Foundation

/// Swift Package Manager build system and workspace support.
///
/// This class implements the `BuildSystem` interface to provide the build settings for a Swift
/// Package Manager (SwiftPM) package. The settings are determined by loading the Package.swift
/// manifest using `libSwiftPM` and constructing a build plan using the default (debug) parameters.
public final class SwiftPMWorkspace {

  public enum Error: Swift.Error {

    /// Could not find a manifest (Package.swift file). This is not a package.
    case noManifest(workspacePath: AbsolutePath)

    /// Could not determine an appropriate toolchain for swiftpm to use for manifest loading.
    case cannotDetermineHostToolchain
  }

  /// Delegate to handle any build system events.
  public weak var delegate: SKCore.BuildSystemDelegate? = nil

  let workspacePath: AbsolutePath
  let packageRoot: AbsolutePath
  var packageGraph: PackageGraph
  let workspace: Workspace
  public let buildParameters: BuildParameters
  let fileSystem: FileSystem

  var fileToTarget: [AbsolutePath: TargetBuildDescription] = [:]
  var sourceDirToTarget: [AbsolutePath: TargetBuildDescription] = [:]

  /// Creates a build system using the Swift Package Manager, if this workspace is a package.
  ///
  /// - Parameters:
  ///   - workspace: The workspace root path.
  ///   - toolchainRegistry: The toolchain registry to use to provide the Swift compiler used for
  ///     manifest parsing and runtime support.
  /// - Throws: If there is an error loading the package, or no manifest is found.
  public init(
    workspacePath: AbsolutePath,
    toolchainRegistry: ToolchainRegistry,
    fileSystem: FileSystem = localFileSystem,
    buildSetup: BuildSetup) throws
  {
    self.workspacePath = workspacePath
    self.fileSystem = fileSystem

    guard let packageRoot = findPackageDirectory(containing: workspacePath, fileSystem) else {
      throw Error.noManifest(workspacePath: workspacePath)
    }

    self.packageRoot = resolveSymlinks(packageRoot)

    guard let destinationToolchainBinDir = toolchainRegistry.default?.swiftc?.parentDirectory else {
        throw Error.cannotDetermineHostToolchain
    }

    let destination = try Destination.hostDestination(destinationToolchainBinDir)
    let toolchain = try UserToolchain(destination: destination)
    let manifestResources = manifestResources(for: toolchain)

    let buildPath: AbsolutePath = buildSetup.path ?? packageRoot.appending(component: ".build")

    let workspaceConfiguration = try Workspace.Configuration(path: packageRoot.appending(components: ".swiftpm", "config"), fs: fileSystem)

    self.workspace = Workspace(
        dataPath: buildPath,
        editablesPath: packageRoot.appending(component: "Packages"),
        pinsFile: packageRoot.appending(component: "Package.resolved"),
        manifestLoader: ManifestLoader(manifestResources: manifestResources, cacheDir: buildPath),
        config: workspaceConfiguration,
        fileSystem: fileSystem,
        skipUpdate: true)

    let triple = toolchain.triple

    let buildConfiguration: PackageModel.BuildConfiguration
    switch buildSetup.configuration {
    case .debug:
      buildConfiguration = .debug
    case .release:
      buildConfiguration = .release
    }

    self.buildParameters = BuildParameters(
      dataPath: buildPath.appending(component: triple.tripleString),
      configuration: buildConfiguration,
      toolchain: toolchain,
      flags: buildSetup.flags)

    self.packageGraph = try PackageGraph(rootPackages: [], dependencies: [])

    try reloadPackage()
  }

  /// Creates a build system using the Swift Package Manager, if this workspace is a package.
  ///
  /// - Returns: nil if `workspacePath` is not part of a package or there is an error.
  public convenience init?(url: Foundation.URL,
                           toolchainRegistry: ToolchainRegistry,
                           buildSetup: BuildSetup)
  {
    do {
      try self.init(
        workspacePath: try AbsolutePath(validating: url.path),
        toolchainRegistry: toolchainRegistry,
        fileSystem: localFileSystem,
        buildSetup: buildSetup)
    } catch Error.noManifest(let path) {
      log("could not find manifest, or not a SwiftPM package: \(path)", level: .warning)
      return nil
    } catch {
      log("failed to create \(SwiftPMWorkspace.self): \(error)", level: .error)
      return nil
    }
  }
}

extension SwiftPMWorkspace {

  /// (Re-)load the package settings by parsing the manifest and resolving all the targets and
  /// dependencies.
  func reloadPackage() throws {

    let diags = DiagnosticsEngine(handlers: [{ diag in
      log(diag.localizedDescription, level: diag.behavior.asLogLevel)
    }])

    self.packageGraph = try self.workspace.loadPackageGraph(
      rootInput: PackageGraphRootInput(packages: [packageRoot]),
      diagnostics: diags)

    let plan = try BuildPlan(
      buildParameters: buildParameters,
      graph: packageGraph,
      diagnostics: diags,
      fileSystem: fileSystem)

    self.fileToTarget = [AbsolutePath: TargetBuildDescription](
      packageGraph.allTargets.flatMap { target in
        return target.sources.paths.compactMap {
          guard let td = plan.targetMap[target] else {
            return nil
          }
          return (key: $0, value: td)
        }
      }, uniquingKeysWith: { td, _ in
        // FIXME: is there  a preferred target?
        return td
    })

    self.sourceDirToTarget = [AbsolutePath: TargetBuildDescription](
      packageGraph.allTargets.compactMap { target in
        guard let td = plan.targetMap[target] else {
          return nil
        }
        return (key: target.sources.root, value: td)
      }, uniquingKeysWith: { td, _ in
        // FIXME: is there  a preferred target?
        return td
    })
  }
}

extension SwiftPMWorkspace: SKCore.BuildSystem {

  public var buildPath: AbsolutePath {
    return buildParameters.buildPath
  }

  public var indexStorePath: AbsolutePath? {
    return buildParameters.indexStoreMode == .off ? nil : buildParameters.indexStore
  }

  public var indexDatabasePath: AbsolutePath? {
    return buildPath.appending(components: "index", "db")
  }

  public func settings(
    for uri: DocumentURI,
    _ language: Language) -> FileBuildSettings?
  {
    guard let url = uri.fileURL else {
      // We can't determine build settings for non-file URIs.
      return nil
    }
    guard let path = try? AbsolutePath(validating: url.path) else {
      return nil
    }

    if let td = targetDescription(for: path) {
      return settings(for: path, language, td)
    }

    if path.basename == "Package.swift" {
      return settings(forPackageManifest: path)
    }

    if path.extension == "h" {
      return settings(forHeader: path, language)
    }

    return nil
  }

  public func registerForChangeNotifications(for uri: DocumentURI, language: Language) {
    guard let delegate = self.delegate else { return }

    // TODO: Support for change detection (via file watching)
    let settings = self.settings(for: uri, language)
    DispatchQueue.global().async {
      delegate.fileBuildSettingsChanged([uri: FileBuildSettingsChange(settings)])
    }
  }

  /// Unregister the given file for build-system level change notifications, such as command
  /// line flag changes, dependency changes, etc.
  public func unregisterForChangeNotifications(for uri: DocumentURI) {
    // TODO: Support for change detection (via file watching)
  }

  public func buildTargets(reply: @escaping (LSPResult<[BuildTarget]>) -> Void) {
    // TODO: Support for build targets
    reply(.failure(buildTargetsNotSupported))
  }

  public func buildTargetSources(targets: [BuildTargetIdentifier], reply: @escaping (LSPResult<[SourcesItem]>) -> Void) {
    reply(.failure(buildTargetsNotSupported))
  }

  public func buildTargetOutputPaths(targets: [BuildTargetIdentifier], reply: @escaping (LSPResult<[OutputsItem]>) -> Void) {
    reply(.failure(buildTargetsNotSupported))
  }

  /// Returns the resolved target description for the given file, if one is known.
  func targetDescription(for file: AbsolutePath) -> TargetBuildDescription? {
    if let td = fileToTarget[file] {
      return td
    }

    let realpath = resolveSymlinks(file)
    if realpath != file, let td = fileToTarget[realpath] {
      fileToTarget[file] = td
      return td
    }

    return nil
  }
}

extension SwiftPMWorkspace {

  // MARK: Implementation details

  /// Retrieve settings for the given file, which is part of a known target build description.
  public func settings(
    for path: AbsolutePath,
    _ language: Language,
    _ td: TargetBuildDescription) -> FileBuildSettings?
  {
    switch (td, language) {
    case (.swift(let td), .swift):
      return settings(forSwiftFile: path, td)
    case (.clang, .swift):
      return nil
    case (.clang(let td), _):
      return settings(forClangFile: path, language, td)
    default:
      return nil
    }
  }

  /// Retrieve settings for a package manifest (Package.swift).
  func settings(forPackageManifest path: AbsolutePath) -> FileBuildSettings? {
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

    let canonicalPath = resolveSymlinks(path)
    return canonicalPath == path ? nil : impl(canonicalPath)
  }

  /// Retrieve settings for a given header file.
  public func settings(forHeader path: AbsolutePath, _ language: Language) -> FileBuildSettings? {
    func impl(_ path: AbsolutePath) -> FileBuildSettings? {
      var dir = path.parentDirectory
      while !dir.isRoot {
        if let td = sourceDirToTarget[dir] {
          return settings(for: path, language, td)
        }
        dir = dir.parentDirectory
      }
      return nil
    }
    
    if let result = impl(path) { 
      return result
    }

    let canonicalPath = resolveSymlinks(path)
    return canonicalPath == path ? nil : impl(canonicalPath)
  }

  /// Retrieve settings for the given swift file, which is part of a known target build description.
  public func settings(
    forSwiftFile path: AbsolutePath,
    _ td: SwiftTargetBuildDescription) -> FileBuildSettings?
  {
    // FIXME: this is re-implementing llbuild's constructCommandLineArgs.
    var args: [String] = [
      "-module-name",
      td.target.c99name,
      "-incremental",
      "-emit-dependencies",
      "-emit-module",
      "-emit-module-path",
      buildPath.appending(component: "\(td.target.c99name).swiftmodule").pathString
      // -output-file-map <path>
    ]
    if td.target.type == .library || td.target.type == .test {
      args += ["-parse-as-library"]
    }
    args += ["-c"]
    args += td.sources.map { $0.pathString }
    args += ["-I", buildPath.pathString]
    args += td.compileArguments()

    return FileBuildSettings(
      compilerArguments: args,
      workingDirectory: workspacePath.pathString)
  }

  /// Retrieve settings for the given C-family language file, which is part of a known target build
  /// description.
  ///
  /// - Note: language must be a C-family language.
  public func settings(
    forClangFile path: AbsolutePath,
    _ language: Language,
    _ td: ClangTargetBuildDescription) -> FileBuildSettings?
  {
    // FIXME: this is re-implementing things from swiftpm's createClangCompileTarget

    var args = td.basicArguments()

    let nativePath: AbsolutePath =
        URL(fileURLWithPath: path.pathString).withUnsafeFileSystemRepresentation {
          AbsolutePath(String(cString: $0!))
        }
    let compilePath = td.compilePaths().first(where: { $0.source == nativePath })
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
        compilePath.object.pathString
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
      workingDirectory: workspacePath.pathString)
  }
}

/// Find a Swift Package root directory that contains the given path, if any.
private func findPackageDirectory(
  containing path: AbsolutePath,
  _ fileSystem: FileSystem) -> AbsolutePath? {
  var path = path
  while !fileSystem.isFile(path.appending(component: "Package.swift")) {
    if path.isRoot {
      return nil
    }
    path = path.parentDirectory
  }
  return path
}

extension TSCBasic.Diagnostic.Behavior {
  var asLogLevel: LogLevel {
    switch self {
    case .error: return .error
    case .warning: return .warning
    default: return .info
    }
  }
}

private func manifestResources(for toolchain: UserToolchain) -> ManifestResourceProvider {
  #if USE_LOCAL_PACKAGE_DESCRIPTION_MODULE
  var buildURL = Bundle(for: SwiftPMWorkspace.self).bundleURL
  if buildURL.pathExtension == "xctest" {
    // If we are statically linked into a test bundle, look in the parent.
    buildURL.deleteLastPathComponent()
  }
  // Look for a local copy of PackageDescription -- either as a bare module, or
  // a framework when building with Xcode. If we find a local PackageDescription
  // module, override the manifest resources `binDir` so that it will be used
  // instead of the toolchain's own manifest resources.
  let fileManager = FileManager.default
  let bareModule = buildURL
    .appendingPathComponent("PackageDescription.swiftmodule")
  let frameworkModule = buildURL
    .appendingPathComponent("PackageFrameworks")
    .appendingPathComponent("PackageDescription.framework")
  if fileManager.fileExists(atPath: bareModule.path) || fileManager.fileExists(atPath: frameworkModule.path) {
    let manifestResources = toolchain.manifestResources
    return UserManifestResources(
      swiftCompiler: manifestResources.swiftCompiler,
      swiftCompilerFlags: manifestResources.swiftCompilerFlags,
      libDir: manifestResources.libDir,
      sdkRoot: manifestResources.sdkRoot,
      xctestLocation: manifestResources.xctestLocation,
      binDir: AbsolutePath(buildURL.path))
  } else {
    log("requested USE_LOCAL_PACKAGE_DESCRIPTION_MODULE but did not find PackageDescription in \(buildURL); falling back to toolchain resources", level: .error)
  }
  #endif

  return toolchain.manifestResources
}
