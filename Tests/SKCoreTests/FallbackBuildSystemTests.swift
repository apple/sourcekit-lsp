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

import LSPTestSupport
import LanguageServerProtocol
@_spi(Testing) import SKCore
import TSCBasic
import XCTest

import struct PackageModel.BuildFlags

final class FallbackBuildSystemTests: XCTestCase {

  func testSwift() async throws {
    let sdk = try AbsolutePath(validating: "/my/sdk")
    let source = try AbsolutePath(validating: "/my/source.swift")

    let bs = FallbackBuildSystem(options: SourceKitLSPOptions.FallbackBuildSystemOptions())
    await bs.setSdkPath(sdk)

    assertNil(await bs.indexStorePath)
    assertNil(await bs.indexDatabasePath)

    let settings = await bs.buildSettings(for: source.asURI, language: .swift)!
    XCTAssertNil(settings.workingDirectory)

    let args = settings.compilerArguments
    XCTAssertEqual(
      args,
      [
        "-sdk",
        sdk.pathString,
        source.pathString,
      ]
    )

    await bs.setSdkPath(nil)

    assertEqual(
      await bs.buildSettings(for: source.asURI, language: .swift)?.compilerArguments,
      [
        source.pathString
      ]
    )
  }

  func testSwiftWithCustomFlags() async throws {
    let sdk = try AbsolutePath(validating: "/my/sdk")
    let source = try AbsolutePath(validating: "/my/source.swift")

    let options = SourceKitLSPOptions.FallbackBuildSystemOptions(
      swiftCompilerFlags: [
        "-Xfrontend",
        "-debug-constraints",
      ]
    )
    let bs = FallbackBuildSystem(options: options)
    await bs.setSdkPath(sdk)

    let args = await bs.buildSettings(for: source.asURI, language: .swift)?.compilerArguments
    XCTAssertEqual(
      args,
      [
        "-Xfrontend",
        "-debug-constraints",
        "-sdk",
        sdk.pathString,
        source.pathString,
      ]
    )

    await bs.setSdkPath(nil)

    assertEqual(
      await bs.buildSettings(for: source.asURI, language: .swift)?.compilerArguments,
      [
        "-Xfrontend",
        "-debug-constraints",
        source.pathString,
      ]
    )
  }

  func testSwiftWithCustomSDKFlag() async throws {
    let sdk = try AbsolutePath(validating: "/my/sdk")
    let source = try AbsolutePath(validating: "/my/source.swift")

    let options = SourceKitLSPOptions.FallbackBuildSystemOptions(
      swiftCompilerFlags: [
        "-sdk",
        "/some/custom/sdk",
        "-Xfrontend",
        "-debug-constraints",
      ]
    )
    let bs = FallbackBuildSystem(options: options)
    await bs.setSdkPath(sdk)

    assertEqual(
      await bs.buildSettings(for: source.asURI, language: .swift)!.compilerArguments,
      [
        "-sdk",
        "/some/custom/sdk",
        "-Xfrontend",
        "-debug-constraints",
        source.pathString,
      ]
    )

    await bs.setSdkPath(nil)

    assertEqual(
      await bs.buildSettings(for: source.asURI, language: .swift)!.compilerArguments,
      [
        "-sdk",
        "/some/custom/sdk",
        "-Xfrontend",
        "-debug-constraints",
        source.pathString,
      ]
    )
  }

  func testCXX() async throws {
    let sdk = try AbsolutePath(validating: "/my/sdk")
    let source = try AbsolutePath(validating: "/my/source.cpp")

    let bs = FallbackBuildSystem(options: SourceKitLSPOptions.FallbackBuildSystemOptions())
    await bs.setSdkPath(sdk)

    let settings = await bs.buildSettings(for: source.asURI, language: .cpp)!
    XCTAssertNil(settings.workingDirectory)

    let args = settings.compilerArguments
    XCTAssertEqual(
      args,
      [
        "-isysroot",
        sdk.pathString,
        source.pathString,
      ]
    )

    await bs.setSdkPath(nil)

    assertEqual(
      await bs.buildSettings(for: source.asURI, language: .cpp)?.compilerArguments,
      [
        source.pathString
      ]
    )
  }

  func testCXXWithCustomFlags() async throws {
    let sdk = try AbsolutePath(validating: "/my/sdk")
    let source = try AbsolutePath(validating: "/my/source.cpp")

    let options = SourceKitLSPOptions.FallbackBuildSystemOptions(
      cxxCompilerFlags: ["-v"]
    )
    let bs = FallbackBuildSystem(options: options)
    await bs.setSdkPath(sdk)

    assertEqual(
      await bs.buildSettings(for: source.asURI, language: .cpp)?.compilerArguments,
      [
        "-v",
        "-isysroot",
        sdk.pathString,
        source.pathString,
      ]
    )

    await bs.setSdkPath(nil)

    assertEqual(
      await bs.buildSettings(for: source.asURI, language: .cpp)?.compilerArguments,
      [
        "-v",
        source.pathString,
      ]
    )
  }

  func testCXXWithCustomIsysroot() async throws {
    let sdk = try AbsolutePath(validating: "/my/sdk")
    let source = try AbsolutePath(validating: "/my/source.cpp")

    let options = SourceKitLSPOptions.FallbackBuildSystemOptions(
      cxxCompilerFlags: [
        "-isysroot",
        "/my/custom/sdk",
        "-v",
      ]
    )
    let bs = FallbackBuildSystem(options: options)
    await bs.setSdkPath(sdk)

    assertEqual(
      await bs.buildSettings(for: source.asURI, language: .cpp)?.compilerArguments,
      [
        "-isysroot",
        "/my/custom/sdk",
        "-v",
        source.pathString,
      ]
    )

    await bs.setSdkPath(nil)

    assertEqual(
      await bs.buildSettings(for: source.asURI, language: .cpp)?.compilerArguments,
      [
        "-isysroot",
        "/my/custom/sdk",
        "-v",
        source.pathString,
      ]
    )
  }

  func testC() async throws {
    let source = try AbsolutePath(validating: "/my/source.c")
    let bs = FallbackBuildSystem(options: SourceKitLSPOptions.FallbackBuildSystemOptions())
    await bs.setSdkPath(nil)
    assertEqual(
      await bs.buildSettings(for: source.asURI, language: .c)?.compilerArguments,
      [
        source.pathString
      ]
    )
  }

  func testCWithCustomFlags() async throws {
    let source = try AbsolutePath(validating: "/my/source.c")

    let options = SourceKitLSPOptions.FallbackBuildSystemOptions(
      cCompilerFlags: ["-v"]
    )
    let bs = FallbackBuildSystem(options: options)
    await bs.setSdkPath(nil)
    assertEqual(
      await bs.buildSettings(for: source.asURI, language: .c)?.compilerArguments,
      [
        "-v",
        source.pathString,
      ]
    )
  }

  func testObjC() async throws {
    let source = try AbsolutePath(validating: "/my/source.m")
    let bs = FallbackBuildSystem(options: SourceKitLSPOptions.FallbackBuildSystemOptions())
    await bs.setSdkPath(nil)
    assertEqual(
      await bs.buildSettings(for: source.asURI, language: .objective_c)?.compilerArguments,
      [
        source.pathString
      ]
    )
  }

  func testObjCXX() async throws {
    let source = try AbsolutePath(validating: "/my/source.mm")
    let bs = FallbackBuildSystem(options: SourceKitLSPOptions.FallbackBuildSystemOptions())
    await bs.setSdkPath(nil)
    assertEqual(
      await bs.buildSettings(for: source.asURI, language: .objective_cpp)?.compilerArguments,
      [
        source.pathString
      ]
    )
  }

  func testUnknown() async throws {
    let source = try AbsolutePath(validating: "/my/source.mm")
    let bs = FallbackBuildSystem(options: SourceKitLSPOptions.FallbackBuildSystemOptions())
    assertNil(await bs.buildSettings(for: source.asURI, language: Language(rawValue: "unknown")))
  }
}
