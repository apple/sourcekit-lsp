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

import BuildServerProtocol
import LSPTestSupport
import LanguageServerProtocol
@_spi(Testing) import SKCore
import TSCBasic
import XCTest

final class BuildSystemManagerTests: XCTestCase {

  func testMainFiles() async throws {
    let a = try DocumentURI(string: "bsm:a")
    let b = try DocumentURI(string: "bsm:b")
    let c = try DocumentURI(string: "bsm:c")
    let d = try DocumentURI(string: "bsm:d")

    let mainFiles = ManualMainFilesProvider(
      [
        a: [c],
        b: [c, d],
        c: [c],
        d: [d],
      ]
    )

    let bsm = await BuildSystemManager(
      buildSystem: nil,
      fallbackBuildSystem: FallbackBuildSystem(options: SourceKitLSPOptions.FallbackBuildSystemOptions()),
      mainFilesProvider: mainFiles,
      toolchainRegistry: ToolchainRegistry.forTesting
    )
    defer { withExtendedLifetime(bsm) {} }  // Keep BSM alive for callbacks.

    await assertEqual(bsm.cachedMainFile(for: a), nil)
    await assertEqual(bsm.cachedMainFile(for: b), nil)
    await assertEqual(bsm.cachedMainFile(for: c), nil)
    await assertEqual(bsm.cachedMainFile(for: d), nil)

    await bsm.registerForChangeNotifications(for: a, language: .c)
    await bsm.registerForChangeNotifications(for: b, language: .c)
    await bsm.registerForChangeNotifications(for: c, language: .c)
    await bsm.registerForChangeNotifications(for: d, language: .c)
    await assertEqual(bsm.cachedMainFile(for: a), c)
    let bMain = await bsm.cachedMainFile(for: b)
    XCTAssert(Set([c, d]).contains(bMain))
    await assertEqual(bsm.cachedMainFile(for: c), c)
    await assertEqual(bsm.cachedMainFile(for: d), d)

    await mainFiles.updateMainFiles(for: a, to: [a])
    await mainFiles.updateMainFiles(for: b, to: [c, d, a])

    await assertEqual(bsm.cachedMainFile(for: a), c)
    await assertEqual(bsm.cachedMainFile(for: b), bMain)
    await assertEqual(bsm.cachedMainFile(for: c), c)
    await assertEqual(bsm.cachedMainFile(for: d), d)

    await bsm.mainFilesChanged()

    await assertEqual(bsm.cachedMainFile(for: a), a)
    await assertEqual(bsm.cachedMainFile(for: b), a)
    await assertEqual(bsm.cachedMainFile(for: c), c)
    await assertEqual(bsm.cachedMainFile(for: d), d)

    await bsm.unregisterForChangeNotifications(for: a)
    await assertEqual(bsm.cachedMainFile(for: a), nil)
    await assertEqual(bsm.cachedMainFile(for: b), a)
    await assertEqual(bsm.cachedMainFile(for: c), c)
    await assertEqual(bsm.cachedMainFile(for: d), d)

    await bsm.unregisterForChangeNotifications(for: b)
    await bsm.mainFilesChanged()
    await bsm.unregisterForChangeNotifications(for: c)
    await bsm.unregisterForChangeNotifications(for: d)
    await assertEqual(bsm.cachedMainFile(for: a), nil)
    await assertEqual(bsm.cachedMainFile(for: b), nil)
    await assertEqual(bsm.cachedMainFile(for: c), nil)
    await assertEqual(bsm.cachedMainFile(for: d), nil)
  }

  @MainActor
  func testSettingsMainFile() async throws {
    let a = try DocumentURI(string: "bsm:a.swift")
    let mainFiles = ManualMainFilesProvider([a: [a]])
    let bs = ManualBuildSystem()
    let bsm = await BuildSystemManager(
      buildSystem: bs,
      fallbackBuildSystem: nil,
      mainFilesProvider: mainFiles,
      toolchainRegistry: ToolchainRegistry.forTesting
    )
    defer { withExtendedLifetime(bsm) {} }  // Keep BSM alive for callbacks.
    let del = await BSMDelegate(bsm)

    bs.map[a] = FileBuildSettings(compilerArguments: ["x"])
    await bsm.registerForChangeNotifications(for: a, language: .swift)
    assertEqual(await bsm.buildSettingsInferredFromMainFile(for: a, language: .swift), bs.map[a]!)

    bs.map[a] = nil
    let changed = expectation(description: "changed settings")
    await del.setExpected([(a, .swift, nil, changed, #file, #line)])
    await bsm.fileBuildSettingsChanged([a])
    try await fulfillmentOfOrThrow([changed])
  }

  @MainActor
  func testSettingsMainFileInitialNil() async throws {
    let a = try DocumentURI(string: "bsm:a.swift")
    let mainFiles = ManualMainFilesProvider([a: [a]])
    let bs = ManualBuildSystem()
    let bsm = await BuildSystemManager(
      buildSystem: bs,
      fallbackBuildSystem: nil,
      mainFilesProvider: mainFiles,
      toolchainRegistry: ToolchainRegistry.forTesting
    )
    defer { withExtendedLifetime(bsm) {} }  // Keep BSM alive for callbacks.
    let del = await BSMDelegate(bsm)
    await bsm.registerForChangeNotifications(for: a, language: .swift)
    assertNil(await bsm.buildSettingsInferredFromMainFile(for: a, language: .swift))

    bs.map[a] = FileBuildSettings(compilerArguments: ["x"])
    let changed = expectation(description: "changed settings")
    await del.setExpected([(a, .swift, bs.map[a]!, changed, #file, #line)])
    await bsm.fileBuildSettingsChanged([a])
    try await fulfillmentOfOrThrow([changed])
  }

  @MainActor
  func testSettingsMainFileWithFallback() async throws {
    let a = try DocumentURI(string: "bsm:a.swift")
    let mainFiles = ManualMainFilesProvider([a: [a]])
    let bs = ManualBuildSystem()
    let fallback = FallbackBuildSystem(options: SourceKitLSPOptions.FallbackBuildSystemOptions())
    let bsm = await BuildSystemManager(
      buildSystem: bs,
      fallbackBuildSystem: fallback,
      mainFilesProvider: mainFiles,
      toolchainRegistry: ToolchainRegistry.forTesting
    )
    defer { withExtendedLifetime(bsm) {} }  // Keep BSM alive for callbacks.
    let del = await BSMDelegate(bsm)
    let fallbackSettings = await fallback.buildSettings(for: a, language: .swift)
    await bsm.registerForChangeNotifications(for: a, language: .swift)
    assertEqual(await bsm.buildSettingsInferredFromMainFile(for: a, language: .swift), fallbackSettings)

    bs.map[a] = FileBuildSettings(compilerArguments: ["non-fallback", "args"])
    let changed = expectation(description: "changed settings")
    await del.setExpected([(a, .swift, bs.map[a]!, changed, #file, #line)])
    await bsm.fileBuildSettingsChanged([a])
    try await fulfillmentOfOrThrow([changed])

    bs.map[a] = nil
    let revert = expectation(description: "revert to fallback settings")
    await del.setExpected([(a, .swift, fallbackSettings, revert, #file, #line)])
    await bsm.fileBuildSettingsChanged([a])
    try await fulfillmentOfOrThrow([revert])
  }

  @MainActor
  func testSettingsMainFileInitialIntersect() async throws {
    let a = try DocumentURI(string: "bsm:a.swift")
    let b = try DocumentURI(string: "bsm:b.swift")
    let mainFiles = ManualMainFilesProvider([a: [a], b: [b]])
    let bs = ManualBuildSystem()
    let bsm = await BuildSystemManager(
      buildSystem: bs,
      fallbackBuildSystem: nil,
      mainFilesProvider: mainFiles,
      toolchainRegistry: ToolchainRegistry.forTesting
    )
    defer { withExtendedLifetime(bsm) {} }  // Keep BSM alive for callbacks.
    let del = await BSMDelegate(bsm)

    bs.map[a] = FileBuildSettings(compilerArguments: ["x"])
    bs.map[b] = FileBuildSettings(compilerArguments: ["y"])
    await bsm.registerForChangeNotifications(for: a, language: .swift)
    assertEqual(await bsm.buildSettingsInferredFromMainFile(for: a, language: .swift), bs.map[a]!)
    await bsm.registerForChangeNotifications(for: b, language: .swift)
    assertEqual(await bsm.buildSettingsInferredFromMainFile(for: b, language: .swift), bs.map[b]!)

    bs.map[a] = FileBuildSettings(compilerArguments: ["xx"])
    bs.map[b] = FileBuildSettings(compilerArguments: ["yy"])
    let changed = expectation(description: "changed settings")
    await del.setExpected([(a, .swift, bs.map[a]!, changed, #file, #line)])
    await bsm.fileBuildSettingsChanged([a])
    try await fulfillmentOfOrThrow([changed])

    // Test multiple changes.
    bs.map[a] = FileBuildSettings(compilerArguments: ["xxx"])
    bs.map[b] = FileBuildSettings(compilerArguments: ["yyy"])
    let changedBothA = expectation(description: "changed setting a")
    let changedBothB = expectation(description: "changed setting b")
    await del.setExpected([
      (a, .swift, bs.map[a]!, changedBothA, #file, #line),
      (b, .swift, bs.map[b]!, changedBothB, #file, #line),
    ])
    await bsm.fileBuildSettingsChanged([a, b])
    try await fulfillmentOfOrThrow([changedBothA, changedBothB])
  }

  @MainActor
  func testSettingsMainFileUnchanged() async throws {
    let a = try DocumentURI(string: "bsm:a.swift")
    let b = try DocumentURI(string: "bsm:b.swift")
    let mainFiles = ManualMainFilesProvider([a: [a], b: [b]])
    let bs = ManualBuildSystem()
    let bsm = await BuildSystemManager(
      buildSystem: bs,
      fallbackBuildSystem: nil,
      mainFilesProvider: mainFiles,
      toolchainRegistry: ToolchainRegistry.forTesting
    )
    defer { withExtendedLifetime(bsm) {} }  // Keep BSM alive for callbacks.
    let del = await BSMDelegate(bsm)

    bs.map[a] = FileBuildSettings(compilerArguments: ["a"])
    bs.map[b] = FileBuildSettings(compilerArguments: ["b"])

    await bsm.registerForChangeNotifications(for: a, language: .swift)
    assertEqual(await bsm.buildSettingsInferredFromMainFile(for: a, language: .swift), bs.map[a]!)

    await bsm.registerForChangeNotifications(for: b, language: .swift)
    assertEqual(await bsm.buildSettingsInferredFromMainFile(for: b, language: .swift), bs.map[b]!)

    bs.map[a] = nil
    bs.map[b] = nil
    let changed = expectation(description: "changed settings")
    await del.setExpected([(b, .swift, nil, changed, #file, #line)])
    await bsm.fileBuildSettingsChanged([b])
    try await fulfillmentOfOrThrow([changed])
  }

  @MainActor
  func testSettingsHeaderChangeMainFile() async throws {
    let h = try DocumentURI(string: "bsm:header.h")
    let cpp1 = try DocumentURI(string: "bsm:main.cpp")
    let cpp2 = try DocumentURI(string: "bsm:other.cpp")
    let mainFiles = ManualMainFilesProvider(
      [
        h: [cpp1],
        cpp1: [cpp1],
        cpp2: [cpp2],
      ]
    )

    let bs = ManualBuildSystem()
    let bsm = await BuildSystemManager(
      buildSystem: bs,
      fallbackBuildSystem: nil,
      mainFilesProvider: mainFiles,
      toolchainRegistry: ToolchainRegistry.forTesting
    )
    defer { withExtendedLifetime(bsm) {} }  // Keep BSM alive for callbacks.
    let del = await BSMDelegate(bsm)

    bs.map[cpp1] = FileBuildSettings(compilerArguments: ["C++ 1"])
    bs.map[cpp2] = FileBuildSettings(compilerArguments: ["C++ 2"])

    await bsm.registerForChangeNotifications(for: h, language: .c)
    assertEqual(await bsm.buildSettingsInferredFromMainFile(for: h, language: .c), bs.map[cpp1]!)

    await mainFiles.updateMainFiles(for: h, to: [cpp2])

    let changed = expectation(description: "changed settings to cpp2")
    await del.setExpected([(h, .c, bs.map[cpp2]!, changed, #file, #line)])
    await bsm.mainFilesChanged()
    try await fulfillmentOfOrThrow([changed])

    let changed2 = expectation(description: "still cpp2, no update")
    changed2.isInverted = true
    await del.setExpected([(h, .c, nil, changed2, #file, #line)])
    await bsm.mainFilesChanged()
    try await fulfillmentOfOrThrow([changed2], timeout: 1)

    await mainFiles.updateMainFiles(for: h, to: [cpp1, cpp2])

    let changed3 = expectation(description: "added lexicographically earlier main file")
    await del.setExpected([(h, .c, bs.map[cpp1]!, changed3, #file, #line)])
    await bsm.mainFilesChanged()
    try await fulfillmentOfOrThrow([changed3], timeout: 1)

    await mainFiles.updateMainFiles(for: h, to: [])

    let changed4 = expectation(description: "changed settings to []")
    await del.setExpected([(h, .c, nil, changed4, #file, #line)])
    await bsm.mainFilesChanged()
    try await fulfillmentOfOrThrow([changed4])
  }

  @MainActor
  func testSettingsOneMainTwoHeader() async throws {
    let h1 = try DocumentURI(string: "bsm:header1.h")
    let h2 = try DocumentURI(string: "bsm:header2.h")
    let cpp = try DocumentURI(string: "bsm:main.cpp")
    let mainFiles = ManualMainFilesProvider(
      [
        h1: [cpp],
        h2: [cpp],
      ]
    )

    let bs = ManualBuildSystem()
    let bsm = await BuildSystemManager(
      buildSystem: bs,
      fallbackBuildSystem: nil,
      mainFilesProvider: mainFiles,
      toolchainRegistry: ToolchainRegistry.forTesting
    )
    defer { withExtendedLifetime(bsm) {} }  // Keep BSM alive for callbacks.
    let del = await BSMDelegate(bsm)

    let cppArg = "C++ Main File"
    bs.map[cpp] = FileBuildSettings(compilerArguments: [cppArg, cpp.pseudoPath])

    await bsm.registerForChangeNotifications(for: h1, language: .c)

    await bsm.registerForChangeNotifications(for: h2, language: .c)

    let expectedArgsH1 = FileBuildSettings(compilerArguments: ["-xc++", cppArg, h1.pseudoPath])
    let expectedArgsH2 = FileBuildSettings(compilerArguments: ["-xc++", cppArg, h2.pseudoPath])
    assertEqual(await bsm.buildSettingsInferredFromMainFile(for: h1, language: .c), expectedArgsH1)
    assertEqual(await bsm.buildSettingsInferredFromMainFile(for: h2, language: .c), expectedArgsH2)

    let newCppArg = "New C++ Main File"
    bs.map[cpp] = FileBuildSettings(compilerArguments: [newCppArg, cpp.pseudoPath])
    let changed1 = expectation(description: "initial settings h1 via cpp")
    let changed2 = expectation(description: "initial settings h2 via cpp")
    let newArgsH1 = FileBuildSettings(compilerArguments: ["-xc++", newCppArg, h1.pseudoPath])
    let newArgsH2 = FileBuildSettings(compilerArguments: ["-xc++", newCppArg, h2.pseudoPath])
    await del.setExpected([
      (h1, .c, newArgsH1, changed1, #file, #line),
      (h2, .c, newArgsH2, changed2, #file, #line),
    ])
    await bsm.fileBuildSettingsChanged([cpp])

    try await fulfillmentOfOrThrow([changed1, changed2])
  }

  @MainActor
  func testSettingsChangedAfterUnregister() async throws {
    let a = try DocumentURI(string: "bsm:a.swift")
    let b = try DocumentURI(string: "bsm:b.swift")
    let c = try DocumentURI(string: "bsm:c.swift")
    let mainFiles = ManualMainFilesProvider([a: [a], b: [b], c: [c]])
    let bs = ManualBuildSystem()
    let bsm = await BuildSystemManager(
      buildSystem: bs,
      fallbackBuildSystem: nil,
      mainFilesProvider: mainFiles,
      toolchainRegistry: ToolchainRegistry.forTesting
    )
    defer { withExtendedLifetime(bsm) {} }  // Keep BSM alive for callbacks.
    let del = await BSMDelegate(bsm)

    bs.map[a] = FileBuildSettings(compilerArguments: ["a"])
    bs.map[b] = FileBuildSettings(compilerArguments: ["b"])
    bs.map[c] = FileBuildSettings(compilerArguments: ["c"])

    await bsm.registerForChangeNotifications(for: a, language: .swift)
    await bsm.registerForChangeNotifications(for: b, language: .swift)
    await bsm.registerForChangeNotifications(for: c, language: .swift)
    assertEqual(await bsm.buildSettingsInferredFromMainFile(for: a, language: .swift), bs.map[a]!)
    assertEqual(await bsm.buildSettingsInferredFromMainFile(for: b, language: .swift), bs.map[b]!)
    assertEqual(await bsm.buildSettingsInferredFromMainFile(for: c, language: .swift), bs.map[c]!)

    bs.map[a] = FileBuildSettings(compilerArguments: ["new-a"])
    bs.map[b] = FileBuildSettings(compilerArguments: ["new-b"])
    bs.map[c] = FileBuildSettings(compilerArguments: ["new-c"])

    let changedB = expectation(description: "changed settings b")
    await del.setExpected([
      (b, .swift, bs.map[b]!, changedB, #file, #line)
    ])

    await bsm.unregisterForChangeNotifications(for: a)
    await bsm.unregisterForChangeNotifications(for: c)
    // At this point only b is registered, but that can race with notifications,
    // so ensure nothing bad happens and we still get the notification for b.
    await bsm.fileBuildSettingsChanged([a, b, c])

    try await fulfillmentOfOrThrow([changedB])
  }

  @MainActor
  func testDependenciesUpdated() async throws {
    let a = try DocumentURI(string: "bsm:a.swift")
    let mainFiles = ManualMainFilesProvider([a: [a]])

    let bs = ManualBuildSystem()
    let bsm = await BuildSystemManager(
      buildSystem: bs,
      fallbackBuildSystem: nil,
      mainFilesProvider: mainFiles,
      toolchainRegistry: ToolchainRegistry.forTesting
    )
    defer { withExtendedLifetime(bsm) {} }  // Keep BSM alive for callbacks.
    let del = await BSMDelegate(bsm)

    bs.map[a] = FileBuildSettings(compilerArguments: ["x"])
    assertEqual(await bsm.buildSettingsInferredFromMainFile(for: a, language: .swift), bs.map[a]!)

    await bsm.registerForChangeNotifications(for: a, language: .swift)

    let depUpdate2 = expectation(description: "dependencies update 2")
    await del.setExpectedDependenciesUpdate([(a, depUpdate2, #file, #line)])

    await bsm.filesDependenciesUpdated([a])
    try await fulfillmentOfOrThrow([depUpdate2])
  }
}

// MARK: Helper Classes for Testing

/// A simple `MainFilesProvider` that wraps a dictionary, for testing.
private final actor ManualMainFilesProvider: MainFilesProvider {
  private var mainFiles: [DocumentURI: Set<DocumentURI>]

  init(_ mainFiles: [DocumentURI: Set<DocumentURI>]) {
    self.mainFiles = mainFiles
  }

  func updateMainFiles(for file: DocumentURI, to mainFiles: Set<DocumentURI>) async {
    self.mainFiles[file] = mainFiles
  }

  func mainFilesContainingFile(_ file: DocumentURI) -> Set<DocumentURI> {
    if let result = mainFiles[file] {
      return result
    }
    return Set()
  }
}

/// A simple `BuildSystem` that wraps a dictionary, for testing.
@MainActor
class ManualBuildSystem: BuildSystem {
  var projectRoot = try! AbsolutePath(validating: "/")

  var map: [DocumentURI: FileBuildSettings] = [:]

  weak var delegate: BuildSystemDelegate? = nil

  func setDelegate(_ delegate: SKCore.BuildSystemDelegate?) async {
    self.delegate = delegate
  }

  public nonisolated var supportsPreparation: Bool { false }

  func buildSettings(for uri: DocumentURI, in buildTarget: ConfiguredTarget, language: Language) -> FileBuildSettings? {
    return map[uri]
  }

  public func defaultLanguage(for document: DocumentURI) async -> Language? {
    return nil
  }

  public func toolchain(for uri: DocumentURI, _ language: Language) async -> SKCore.Toolchain? {
    return nil
  }

  public func configuredTargets(for document: DocumentURI) async -> [ConfiguredTarget] {
    return [ConfiguredTarget(targetID: "dummy", runDestinationID: "dummy")]
  }

  public func prepare(
    targets: [ConfiguredTarget],
    logMessageToIndexLog: @escaping @Sendable (_ taskID: IndexTaskID, _ message: String) -> Void
  ) async throws {
    throw PrepareNotSupportedError()
  }

  public func generateBuildGraph(allowFileSystemWrites: Bool) {}

  public func topologicalSort(of targets: [ConfiguredTarget]) -> [ConfiguredTarget]? {
    return nil
  }

  public func targets(dependingOn targets: [ConfiguredTarget]) -> [ConfiguredTarget]? {
    return nil
  }

  func registerForChangeNotifications(for uri: DocumentURI) async {
  }

  func unregisterForChangeNotifications(for: DocumentURI) {
  }

  var indexStorePath: AbsolutePath? { nil }
  var indexDatabasePath: AbsolutePath? { nil }
  var indexPrefixMappings: [PathPrefixMapping] { return [] }

  func filesDidChange(_ events: [FileEvent]) {}

  public func fileHandlingCapability(for uri: DocumentURI) -> FileHandlingCapability {
    if map[uri] != nil {
      return .handled
    } else {
      return .unhandled
    }
  }

  func sourceFiles() async -> [SourceFileInfo] {
    return []
  }

  func addSourceFilesDidChangeCallback(_ callback: @escaping () async -> Void) {}
}

/// A `BuildSystemDelegate` setup for testing.
private actor BSMDelegate: BuildSystemDelegate {
  fileprivate typealias ExpectedBuildSettingChangedCall = (
    uri: DocumentURI, language: Language, settings: FileBuildSettings?, expectation: XCTestExpectation,
    file: StaticString, line: UInt
  )
  fileprivate typealias ExpectedDependenciesUpdatedCall = (
    uri: DocumentURI, expectation: XCTestExpectation, file: StaticString, line: UInt
  )

  unowned let bsm: BuildSystemManager
  var expected: [ExpectedBuildSettingChangedCall] = []

  /// - Note: Needed to set `expected` outside of the actor's isolation context.
  func setExpected(_ expected: [ExpectedBuildSettingChangedCall]) {
    self.expected = expected
  }

  var expectedDependenciesUpdate: [(uri: DocumentURI, expectation: XCTestExpectation, file: StaticString, line: UInt)] =
    []

  /// - Note: Needed to set `expected` outside of the actor's isolation context.
  func setExpectedDependenciesUpdate(_ expectedDependenciesUpdated: [ExpectedDependenciesUpdatedCall]) {
    self.expectedDependenciesUpdate = expectedDependenciesUpdated
  }

  init(_ bsm: BuildSystemManager) async {
    self.bsm = bsm
    // Actor initializers can't directly leave their executor. Moving the call
    // of `bsm.setDelegate` into a closure works around that limitation. rdar://116221716
    await {
      await bsm.setDelegate(self)
    }()
  }

  func fileBuildSettingsChanged(_ changedFiles: Set<DocumentURI>) async {
    for uri in changedFiles {
      guard let expected = expected.first(where: { $0.uri == uri }) else {
        XCTFail("unexpected settings change for \(uri)")
        continue
      }

      XCTAssertEqual(uri, expected.uri, file: expected.file, line: expected.line)
      let settings = await bsm.buildSettingsInferredFromMainFile(for: uri, language: expected.language)
      XCTAssertEqual(settings, expected.settings, file: expected.file, line: expected.line)
      expected.expectation.fulfill()
    }
  }

  func buildTargetsChanged(_ changes: [BuildTargetEvent]) {}
  func filesDependenciesUpdated(_ changedFiles: Set<DocumentURI>) {
    for uri in changedFiles {
      guard let expected = expectedDependenciesUpdate.first(where: { $0.uri == uri }) else {
        XCTFail("unexpected filesDependenciesUpdated for \(uri)")
        continue
      }

      XCTAssertEqual(uri, expected.uri, file: expected.file, line: expected.line)
      expected.expectation.fulfill()
    }
  }

  func fileHandlingCapabilityChanged() {}
}
