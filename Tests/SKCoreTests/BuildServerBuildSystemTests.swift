//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
import XCTest
import SKCore
import TSCBasic
import LanguageServerProtocol
import Foundation
import BuildServerProtocol

final class BuildServerBuildSystemTests: XCTestCase {

  func testServerInitialize() throws {
    let root = AbsolutePath(
      inputsDirectory().appendingPathComponent(testDirectoryName, isDirectory: true).path)
    let buildFolder = AbsolutePath(NSTemporaryDirectory())

    let buildSystem = try BuildServerBuildSystem(projectRoot: root, buildFolder: buildFolder)

    XCTAssertEqual(buildSystem.indexStorePath, AbsolutePath("some/index/store/path", relativeTo: root))
  }

  func testSettings() throws {
    let root = AbsolutePath(
      inputsDirectory().appendingPathComponent(testDirectoryName, isDirectory: true).path)
    let buildFolder = AbsolutePath(NSTemporaryDirectory())
    let buildSystem = try BuildServerBuildSystem(projectRoot: root, buildFolder: buildFolder)

    // test settings with a response
    let fileURL = URL(fileURLWithPath: "/path/to/some/file.swift")
    let settings = buildSystem.settings(for: fileURL, Language.swift)
    XCTAssertNotNil(settings)
    XCTAssertEqual(settings?.compilerArguments, ["-a", "-b"])
    XCTAssertEqual(settings?.workingDirectory, fileURL.deletingLastPathComponent().path)

    // test error
    let missingFileURL = URL(fileURLWithPath: "/path/to/some/missingfile.missing")
    XCTAssertNil(buildSystem.settings(for: missingFileURL, Language.swift))
  }

  func testFileRegistration() throws {
    let root = AbsolutePath(
      inputsDirectory().appendingPathComponent(testDirectoryName, isDirectory: true).path)
    let buildFolder = AbsolutePath(NSTemporaryDirectory())
    let buildSystem = try BuildServerBuildSystem(projectRoot: root, buildFolder: buildFolder)

    let fileUrl = URL(fileURLWithPath: "/some/file/path")
    let expectation = XCTestExpectation(description: "\(fileUrl) settings updated")
    let buildSystemDelegate = TestDelegate(expectations: [fileUrl: expectation])
    buildSystem.delegate = buildSystemDelegate
    buildSystem.registerForChangeNotifications(for: fileUrl, language: .swift)

    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed)
  }

  func testBuildTargets() throws {
    let root = AbsolutePath(
      inputsDirectory().appendingPathComponent(testDirectoryName, isDirectory: true).path)
    let buildFolder = AbsolutePath(NSTemporaryDirectory())
    let buildSystem = try BuildServerBuildSystem(projectRoot: root, buildFolder: buildFolder)

    let expectation = XCTestExpectation(description: "build target expectation")

    buildSystem.buildTargets(reply: { response in
      switch(response) {
      case .success(let targets):
        XCTAssertEqual(targets, [
                       BuildTarget(id: BuildTargetIdentifier(uri: URL(string: "first_target")!),
                                   displayName: "First Target",
                                   baseDirectory: URL(fileURLWithPath: "/some/dir"),
                                   tags: [BuildTargetTag.library, BuildTargetTag.test],
                                   capabilities: BuildTargetCapabilities(canCompile: true, canTest: true, canRun: false),
                                   languageIds: [Language.objective_c, Language.swift],
                                   dependencies: []),
                       BuildTarget(id: BuildTargetIdentifier(uri: URL(string: "second_target")!),
                                   displayName: "Second Target",
                                   baseDirectory: URL(fileURLWithPath: "/some/dir"),
                                   tags: [BuildTargetTag.library, BuildTargetTag.test],
                                   capabilities: BuildTargetCapabilities(canCompile: true, canTest: false, canRun: false),
                                   languageIds: [Language.objective_c, Language.swift],
                                   dependencies: [BuildTargetIdentifier(uri: URL(string: "first_target")!)]),
                       ])
        expectation.fulfill()
      case .failure(let error):
        XCTFail(error.message)
      }
    })
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed)
  }

  func testBuildTargetSources() throws {
    let root = AbsolutePath(
      inputsDirectory().appendingPathComponent(testDirectoryName, isDirectory: true).path)
    let buildFolder = AbsolutePath(NSTemporaryDirectory())
    let buildSystem = try BuildServerBuildSystem(projectRoot: root, buildFolder: buildFolder)

    let expectation = XCTestExpectation(description: "build target sources expectation")
    let targets = [
      BuildTargetIdentifier(uri: URL(string: "build://target/a")!),
      BuildTargetIdentifier(uri: URL(string: "build://target/b")!),
    ]
    buildSystem.buildTargetSources(targets: targets, reply: { response in
      switch(response) {
      case .success(let items):
        XCTAssertNotNil(items)
        XCTAssertEqual(items[0].target.uri, targets[0].uri)
        XCTAssertEqual(items[1].target.uri, targets[1].uri)
        XCTAssertEqual(items[0].sources[0].uri, URL(fileURLWithPath: "/path/to/a/file"))
        XCTAssertEqual(items[0].sources[0].kind, SourceItemKind.file)
        XCTAssertEqual(items[0].sources[1].uri, URL(fileURLWithPath: "/path/to/a/folder/"))
        XCTAssertEqual(items[0].sources[1].kind, SourceItemKind.directory)
        XCTAssertEqual(items[1].sources[0].uri, URL(fileURLWithPath: "/path/to/b/file"))
        XCTAssertEqual(items[1].sources[0].kind, SourceItemKind.file)
        XCTAssertEqual(items[1].sources[1].uri, URL(fileURLWithPath: "/path/to/b/folder/"))
        XCTAssertEqual(items[1].sources[1].kind, SourceItemKind.directory)
        expectation.fulfill()
      case .failure(let error):
        XCTFail(error.message)
      }
    })
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed)
  }

  func testBuildTargetOutputs() throws {
    let root = AbsolutePath(
      inputsDirectory().appendingPathComponent(testDirectoryName, isDirectory: true).path)
    let buildFolder = AbsolutePath(NSTemporaryDirectory())
    let buildSystem = try BuildServerBuildSystem(projectRoot: root, buildFolder: buildFolder)

    let expectation = XCTestExpectation(description: "build target output expectation")
    let targets = [
      BuildTargetIdentifier(uri: URL(string: "build://target/a")!),
    ]
    buildSystem.buildTargetOutputPaths(targets: targets, reply: { response in
      switch(response) {
      case .success(let items):
        XCTAssertNotNil(items)
        XCTAssertEqual(items[0].target.uri, targets[0].uri)
        XCTAssertEqual(items[0].outputPaths, [
          URL(fileURLWithPath: "/path/to/a/file"),
          URL(fileURLWithPath: "/path/to/a/file2"),
        ])
        expectation.fulfill()
      case .failure(let error):
        XCTFail(error.message)
      }
    })
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed)
  }
}

final class TestDelegate: BuildSystemDelegate {

  let expectations: [URL: XCTestExpectation]

  public init(expectations: [URL: XCTestExpectation]) {
    self.expectations = expectations
  }

  func fileBuildSettingsChanged(_ changes: [URL: FileBuildSettingsChange]) {
    for url in changes.keys {
      expectations[url]?.fulfill()
    }
  }
}
