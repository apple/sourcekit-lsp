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

import BuildServerProtocol
import Dispatch
import Foundation
import LanguageServerProtocol
import SKSupport

import enum PackageLoading.Platform
import struct TSCBasic.AbsolutePath
import class TSCBasic.Process

/// A simple BuildSystem suitable as a fallback when accurate settings are unknown.
public actor FallbackBuildSystem {
  private let options: SourceKitLSPOptions.FallbackBuildSystemOptions

  public init(options: SourceKitLSPOptions.FallbackBuildSystemOptions) {
    self.options = options
  }

  /// The path to the SDK.
  public lazy var sdkpath: AbsolutePath? = {
    guard Platform.current == .darwin else { return nil }
    return try? AbsolutePath(
      validating: Process.checkNonZeroExit(args: "/usr/bin/xcrun", "--show-sdk-path", "--sdk", "macosx")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }()

  @_spi(Testing) public func setSdkPath(_ newValue: AbsolutePath?) {
    self.sdkpath = newValue
  }

  /// Delegate to handle any build system events.
  public weak var delegate: BuildSystemDelegate? = nil

  public func setDelegate(_ delegate: BuildSystemDelegate?) async {
    self.delegate = delegate
  }

  public var indexStorePath: AbsolutePath? { return nil }

  public var indexDatabasePath: AbsolutePath? { return nil }

  public var indexPrefixMappings: [PathPrefixMapping] { return [] }

  public func buildSettings(for uri: DocumentURI, language: Language) -> FileBuildSettings? {
    var fileBuildSettings: FileBuildSettings?
    switch language {
    case .swift:
      fileBuildSettings = settingsSwift(uri.pseudoPath)
    case .c, .cpp, .objective_c, .objective_cpp:
      fileBuildSettings = settingsClang(uri.pseudoPath, language)
    default:
      fileBuildSettings = nil
    }
    fileBuildSettings?.isFallback = true
    return fileBuildSettings
  }

  func settingsSwift(_ file: String) -> FileBuildSettings {
    var args: [String] = []
    args.append(contentsOf: self.options.swiftCompilerFlags ?? [])
    if let sdkpath = sdkpath, !args.contains("-sdk") {
      args += [
        "-sdk",
        sdkpath.pathString,
      ]
    }
    args.append(file)
    return FileBuildSettings(compilerArguments: args)
  }

  func settingsClang(_ file: String, _ language: Language) -> FileBuildSettings {
    var args: [String] = []
    switch language {
    case .c:
      args.append(contentsOf: self.options.cCompilerFlags ?? [])
    case .cpp:
      args.append(contentsOf: self.options.cxxCompilerFlags ?? [])
    default:
      break
    }
    if let sdkpath = sdkpath, !args.contains("-isysroot") {
      args += [
        "-isysroot",
        sdkpath.pathString,
      ]
    }
    args.append(file)
    return FileBuildSettings(compilerArguments: args)
  }
}
