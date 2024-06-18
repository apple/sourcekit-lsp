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

import Foundation
import XCTest

import struct TSCBasic.AbsolutePath
import class TSCBasic.Process
import enum TSCBasic.ProcessEnv
import struct TSCBasic.ProcessResult

/// Returns the path to the given tool, as found by `xcrun --find` on macOS, or `which` on Linux.
fileprivate func findTool(name: String) async -> URL? {
  #if os(macOS)
  let cmd = ["/usr/bin/xcrun", "--find", name]
  #elseif os(Windows)
  var buf = [WCHAR](repeating: 0, count: Int(MAX_PATH))
  GetWindowsDirectoryW(&buf, DWORD(MAX_PATH))
  var wherePath = String(decodingCString: &buf, as: UTF16.self)
    .appendingPathComponent("system32")
    .appendingPathComponent("where.exe")
  let cmd = [wherePath, name]
  #elseif os(Android)
  let cmd = ["/system/bin/which", name]
  #else
  let cmd = ["/usr/bin/which", name]
  #endif

  guard let result = try? await Process.run(arguments: cmd, workingDirectory: nil) else {
    return nil
  }
  guard var path = try? String(bytes: result.output.get(), encoding: .utf8) else {
    return nil
  }
  #if os(Windows)
  path = String((path.split { $0.isNewline })[0])
  #endif
  path = path.trimmingCharacters(in: .whitespacesAndNewlines)
  return URL(fileURLWithPath: path, isDirectory: false)
}

/// A SwiftPM package that gets written to disk and for which a Git repository is initialized with a commit tagged
/// `1.0.0`. This repository can then be used as a dependency for another package, usually a `SwiftPMTestProject`.
public class SwiftPMDependencyProject {
  /// The scratch directory created for the dependency project.
  public let scratchDirectory: URL

  /// The directory in which the repository lives.
  public var packageDirectory: URL {
    return scratchDirectory.appendingPathComponent("MyDependency")
  }

  private func runGitCommand(_ arguments: [String], workingDirectory: URL) async throws {
    enum Error: Swift.Error {
      case cannotFindGit
      case processedTerminatedWithNonZeroExitCode(ProcessResult)
    }
    guard let toolUrl = await findTool(name: "git") else {
      if ProcessEnv.block["SWIFTCI_USE_LOCAL_DEPS"] == nil {
        // Never skip the test in CI, similar to what SkipUnless does.
        throw XCTSkip("git cannot be found")
      }
      throw Error.cannotFindGit
    }
    // We can't use `workingDirectory` because Amazon Linux doesn't support working directories (or at least
    // TSCBasic.Process doesn't support working directories on Amazon Linux)
    let process = TSCBasic.Process(
      arguments: [toolUrl.path, "-C", workingDirectory.path] + arguments
    )
    try process.launch()
    let processResult = try await process.waitUntilExit()
    guard processResult.exitStatus == .terminated(code: 0) else {
      throw Error.processedTerminatedWithNonZeroExitCode(processResult)
    }
  }

  public static let defaultPackageManifest: String = """
    // swift-tools-version: 5.7

    import PackageDescription

    let package = Package(
      name: "MyDependency",
      products: [.library(name: "MyDependency", targets: ["MyDependency"])],
      targets: [.target(name: "MyDependency")]
    )
    """

  public init(
    files: [RelativeFileLocation: String],
    manifest: String = defaultPackageManifest,
    testName: String = #function
  ) async throws {
    scratchDirectory = try testScratchDir(testName: testName)

    var files = files
    files["Package.swift"] = manifest

    for (fileLocation, markedContents) in files {
      let fileURL = fileLocation.url(relativeTo: packageDirectory)
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try extractMarkers(markedContents).textWithoutMarkers.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    try await runGitCommand(["init"], workingDirectory: packageDirectory)
    try await runGitCommand(
      ["add"] + files.keys.map { $0.url(relativeTo: packageDirectory).path },
      workingDirectory: packageDirectory
    )
    try await runGitCommand(
      ["-c", "user.name=Dummy", "-c", "user.email=noreply@swift.org", "commit", "-m", "Initial commit"],
      workingDirectory: packageDirectory
    )
    try await runGitCommand(["tag", "1.0.0"], workingDirectory: packageDirectory)
  }

  deinit {
    if cleanScratchDirectories {
      try? FileManager.default.removeItem(at: scratchDirectory)
    }
  }

  /// Function that makes sure the project stays alive until this is called. Otherwise, the `SwiftPMDependencyProject`
  /// might get deinitialized, which deletes the package on disk.
  public func keepAlive() {
    withExtendedLifetime(self) { _ in }
  }
}
