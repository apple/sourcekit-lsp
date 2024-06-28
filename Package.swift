// swift-tools-version: 5.8

import Foundation
import PackageDescription

let strictConcurrencySettings: [SwiftSetting] = [
  .enableUpcomingFeature("StrictConcurrency"),
  .enableUpcomingFeature("RegionBasedIsolation"),
  .enableUpcomingFeature("InferSendableFromCaptures"),
]

let package = Package(
  name: "SourceKitLSP",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "sourcekit-lsp", targets: ["sourcekit-lsp"]),
    .library(name: "_SourceKitLSP", targets: ["SourceKitLSP"]),
    .library(name: "LSPBindings", targets: ["LanguageServerProtocol", "LanguageServerProtocolJSONRPC"]),
  ],
  dependencies: dependencies,
  targets: [
    // Formatting style:
    //  - One section for each target and its test target
    //  - Sections are sorted alphabetically
    //  - Dependencies are listed on separate lines
    //  - All array elements are sorted alphabetically

    // MARK: sourcekit-lsp

    .executableTarget(
      name: "sourcekit-lsp",
      dependencies: [
        "Diagnose",
        "LanguageServerProtocol",
        "LanguageServerProtocolJSONRPC",
        "SKCore",
        "SKSupport",
        "SourceKitLSP",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "SwiftToolsSupport-auto", package: "swift-tools-support-core"),
      ],
      exclude: ["CMakeLists.txt"],
      swiftSettings: strictConcurrencySettings,
      linkerSettings: sourcekitLSPLinkSettings
    ),

    // MARK: BuildServerProtocol
    // Connection between build server and language server to provide build and index info

    .target(
      name: "BuildServerProtocol",
      dependencies: [
        "LanguageServerProtocol"
      ],
      exclude: ["CMakeLists.txt"],
      swiftSettings: strictConcurrencySettings
    ),

    // MARK: CAtomics
    .target(
      name: "CAtomics",
      dependencies: []
    ),

    // MARK: CSKTestSupport
    .target(
      name: "CSKTestSupport",
      dependencies: []
    ),

    // MARK: Csourcekitd
    // C modules wrapper for sourcekitd.
    .target(
      name: "Csourcekitd",
      dependencies: [],
      exclude: ["CMakeLists.txt"]
    ),

    // MARK: Diagnose

    .target(
      name: "Diagnose",
      dependencies: [
        "InProcessClient",
        "LSPLogging",
        "SKCore",
        "SKSupport",
        "SourceKitD",
        "SourceKitLSP",
        "SwiftExtensions",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "SwiftIDEUtils", package: "swift-syntax"),
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftParser", package: "swift-syntax"),
        .product(name: "SwiftToolsSupport-auto", package: "swift-tools-support-core"),
      ],
      exclude: ["CMakeLists.txt"],
      swiftSettings: strictConcurrencySettings
    ),

    .testTarget(
      name: "DiagnoseTests",
      dependencies: [
        "Diagnose",
        "LSPLogging",
        "LSPTestSupport",
        "SourceKitD",
        "SKCore",
        "SKTestSupport",
        .product(name: "SwiftToolsSupport-auto", package: "swift-tools-support-core"),
      ],
      swiftSettings: strictConcurrencySettings
    ),

    // MARK: InProcessClient

    .target(
      name: "InProcessClient",
      dependencies: [
        "LanguageServerProtocol",
        "LSPLogging",
        "SKCore",
        "SourceKitLSP",
      ],
      exclude: ["CMakeLists.txt"],
      swiftSettings: strictConcurrencySettings
    ),

    // MARK: LanguageServerProtocol
    // The core LSP types, suitable for any LSP implementation.
    .target(
      name: "LanguageServerProtocol",
      dependencies: [],
      exclude: ["CMakeLists.txt"],
      swiftSettings: strictConcurrencySettings
    ),

    .testTarget(
      name: "LanguageServerProtocolTests",
      dependencies: [
        "LanguageServerProtocol",
        "LSPTestSupport",
      ],
      swiftSettings: strictConcurrencySettings
    ),

    // MARK: LanguageServerProtocolJSONRPC
    // LSP connection using jsonrpc over pipes.

    .target(
      name: "LanguageServerProtocolJSONRPC",
      dependencies: [
        "LanguageServerProtocol",
        "LSPLogging",
      ],
      exclude: ["CMakeLists.txt"],
      swiftSettings: strictConcurrencySettings
    ),

    .testTarget(
      name: "LanguageServerProtocolJSONRPCTests",
      dependencies: [
        "LanguageServerProtocolJSONRPC",
        "LSPTestSupport",
      ],
      swiftSettings: strictConcurrencySettings
    ),

    // MARK: LSPLogging
    // Logging support used in LSP modules.

    .target(
      name: "LSPLogging",
      dependencies: [
        "SwiftExtensions",
        .product(name: "Crypto", package: "swift-crypto"),
      ],
      exclude: ["CMakeLists.txt"],
      swiftSettings: lspLoggingSwiftSettings + strictConcurrencySettings
    ),

    .testTarget(
      name: "LSPLoggingTests",
      dependencies: [
        "LSPLogging",
        "SKTestSupport",
      ],
      swiftSettings: strictConcurrencySettings
    ),

    // MARK: LSPTestSupport

    .target(
      name: "LSPTestSupport",
      dependencies: [
        "InProcessClient",
        "LanguageServerProtocol",
        "LanguageServerProtocolJSONRPC",
        "SKSupport",
        "SwiftExtensions",
      ],
      swiftSettings: strictConcurrencySettings
    ),

    // MARK: SemanticIndex

    .target(
      name: "SemanticIndex",
      dependencies: [
        "LanguageServerProtocol",
        "LSPLogging",
        "SKCore",
        "SwiftExtensions",
        .product(name: "IndexStoreDB", package: "indexstore-db"),
      ],
      exclude: ["CMakeLists.txt"],
      swiftSettings: strictConcurrencySettings
    ),

    .testTarget(
      name: "SemanticIndexTests",
      dependencies: [
        "LSPLogging",
        "SemanticIndex",
        "SKTestSupport",
      ],
      swiftSettings: strictConcurrencySettings
    ),

    // MARK: SKCore
    // Data structures and algorithms useful across the project, but not necessarily
    // suitable for use in other packages.

    .target(
      name: "SKCore",
      dependencies: [
        "BuildServerProtocol",
        "LanguageServerProtocol",
        "LanguageServerProtocolJSONRPC",
        "LSPLogging",
        "SKSupport",
        "SourceKitD",
        "SwiftExtensions",
        .product(name: "SwiftPMDataModel-auto", package: "swift-package-manager"),
        .product(name: "SwiftToolsSupport-auto", package: "swift-tools-support-core"),
      ],
      exclude: ["CMakeLists.txt"],
      swiftSettings: strictConcurrencySettings
    ),

    .testTarget(
      name: "SKCoreTests",
      dependencies: [
        "SKCore",
        "SKTestSupport",
      ],
      swiftSettings: strictConcurrencySettings
    ),

    // MARK: SKSupport
    // Data structures, algorithms and platform-abstraction code that might be generally useful to any Swift package.
    // Similar in spirit to SwiftPM's Basic module.

    .target(
      name: "SKSupport",
      dependencies: [
        "CAtomics",
        "LanguageServerProtocol",
        "LSPLogging",
        "SwiftExtensions",
        .product(name: "SwiftToolsSupport-auto", package: "swift-tools-support-core"),
      ],
      exclude: ["CMakeLists.txt"],
      swiftSettings: strictConcurrencySettings
    ),

    .testTarget(
      name: "SKSupportTests",
      dependencies: [
        "LSPTestSupport",
        "SKSupport",
        "SKTestSupport",
        "SwiftExtensions",
      ],
      swiftSettings: strictConcurrencySettings
    ),

    // MARK: SKSwiftPMWorkspace

    .target(
      name: "SKSwiftPMWorkspace",
      dependencies: [
        "BuildServerProtocol",
        "LanguageServerProtocol",
        "LSPLogging",
        "SKCore",
        "SwiftExtensions",
        .product(name: "SwiftPM-auto", package: "swift-package-manager"),
        .product(name: "SwiftToolsSupport-auto", package: "swift-tools-support-core"),
      ],
      exclude: ["CMakeLists.txt"],
      swiftSettings: strictConcurrencySettings
    ),

    .testTarget(
      name: "SKSwiftPMWorkspaceTests",
      dependencies: [
        "LSPTestSupport",
        "LanguageServerProtocol",
        "SKCore",
        "SKSwiftPMWorkspace",
        "SKTestSupport",
        "SourceKitLSP",
        .product(name: "SwiftPM-auto", package: "swift-package-manager"),
        .product(name: "SwiftToolsSupport-auto", package: "swift-tools-support-core"),
      ],
      swiftSettings: strictConcurrencySettings
    ),

    // MARK: SKTestSupport

    .target(
      name: "SKTestSupport",
      dependencies: [
        "CSKTestSupport",
        "InProcessClient",
        "LanguageServerProtocol",
        "LSPTestSupport",
        "LSPLogging",
        "SKCore",
        "SourceKitLSP",
        "SwiftExtensions",
        .product(name: "ISDBTestSupport", package: "indexstore-db"),
        .product(name: "SwiftToolsSupport-auto", package: "swift-tools-support-core"),
      ],
      resources: [.copy("INPUTS")],
      swiftSettings: strictConcurrencySettings
    ),

    // MARK: SourceKitD
    // Swift bindings for sourcekitd.

    .target(
      name: "SourceKitD",
      dependencies: [
        "Csourcekitd",
        "LSPLogging",
        "SwiftExtensions",
        .product(name: "SwiftToolsSupport-auto", package: "swift-tools-support-core"),
      ],
      exclude: ["CMakeLists.txt", "sourcekitd_uids.swift.gyb"],
      swiftSettings: strictConcurrencySettings
    ),

    .testTarget(
      name: "SourceKitDTests",
      dependencies: [
        "SourceKitD",
        "SKCore",
        "SKTestSupport",
        "SwiftExtensions",
      ],
      swiftSettings: strictConcurrencySettings
    ),

    // MARK: SourceKitLSP

    .target(
      name: "SourceKitLSP",
      dependencies: [
        "BuildServerProtocol",
        "LanguageServerProtocol",
        "LanguageServerProtocolJSONRPC",
        "LSPLogging",
        "SemanticIndex",
        "SKCore",
        "SKSupport",
        "SKSwiftPMWorkspace",
        "SourceKitD",
        "SwiftExtensions",
        .product(name: "IndexStoreDB", package: "indexstore-db"),
        .product(name: "SwiftBasicFormat", package: "swift-syntax"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "SwiftDiagnostics", package: "swift-syntax"),
        .product(name: "SwiftIDEUtils", package: "swift-syntax"),
        .product(name: "SwiftParser", package: "swift-syntax"),
        .product(name: "SwiftParserDiagnostics", package: "swift-syntax"),
        .product(name: "SwiftRefactor", package: "swift-syntax"),
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftToolsSupport-auto", package: "swift-tools-support-core"),
        .product(name: "SwiftPM-auto", package: "swift-package-manager"),
      ],
      exclude: ["CMakeLists.txt"],
      swiftSettings: strictConcurrencySettings
    ),

    .testTarget(
      name: "SourceKitLSPTests",
      dependencies: [
        "BuildServerProtocol",
        "LSPLogging",
        "LSPTestSupport",
        "LanguageServerProtocol",
        "SemanticIndex",
        "SKCore",
        "SKSupport",
        "SKTestSupport",
        "SourceKitD",
        "SourceKitLSP",
        .product(name: "IndexStoreDB", package: "indexstore-db"),
        .product(name: "ISDBTestSupport", package: "indexstore-db"),
        .product(name: "SwiftParser", package: "swift-syntax"),
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftToolsSupport-auto", package: "swift-tools-support-core"),
        // Depend on `SwiftCompilerPlugin` and `SwiftSyntaxMacros` so the modules are built before running tests and can
        // be used by test cases that test macros (see `SwiftPMTestProject.macroPackageManifest`).
        .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
        .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
      ],
      swiftSettings: strictConcurrencySettings
    ),

    // MARK: SwiftExtensions

    .target(
      name: "SwiftExtensions",
      exclude: ["CMakeLists.txt"],
      swiftSettings: strictConcurrencySettings
    ),
  ]
)

// MARK: - Parse build arguments

func hasEnvironmentVariable(_ name: String) -> Bool {
  return ProcessInfo.processInfo.environment[name] != nil
}

/// Use the `NonDarwinLogger` even if `os_log` can be imported.
///
/// This is useful when running tests using `swift test` because xctest will not display the output from `os_log` on the
/// command line.
var forceNonDarwinLogger: Bool { hasEnvironmentVariable("SOURCEKITLSP_FORCE_NON_DARWIN_LOGGER") }

// When building the toolchain on the CI, don't add the CI's runpath for the
// final build before installing.
var installAction: Bool { hasEnvironmentVariable("SOURCEKIT_LSP_CI_INSTALL") }

/// Assume that all the package dependencies are checked out next to sourcekit-lsp and use that instead of fetching a
/// remote dependency.
var useLocalDependencies: Bool { hasEnvironmentVariable("SWIFTCI_USE_LOCAL_DEPS") }

// MARK: - Dependencies

// When building with the swift build-script, use local dependencies whose contents are controlled
// by the external environment. This allows sourcekit-lsp to take advantage of the automation used
// for building the swift toolchain, such as `update-checkout`, or cross-repo PR tests.

var dependencies: [Package.Dependency] {
  if useLocalDependencies {
    return [
      .package(path: "../indexstore-db"),
      .package(name: "swift-package-manager", path: "../swiftpm"),
      .package(path: "../swift-tools-support-core"),
      .package(path: "../swift-argument-parser"),
      .package(path: "../swift-syntax"),
      .package(path: "../swift-crypto"),
    ]
  } else {
    let relatedDependenciesBranch = "main"

    return [
      .package(url: "https://github.com/swiftlang/indexstore-db.git", branch: relatedDependenciesBranch),
      .package(url: "https://github.com/swiftlang/swift-package-manager.git", branch: relatedDependenciesBranch),
      .package(url: "https://github.com/apple/swift-tools-support-core.git", branch: relatedDependenciesBranch),
      .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.2"),
      .package(url: "https://github.com/swiftlang/swift-syntax.git", branch: relatedDependenciesBranch),
      .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
      // Not a build dependency. Used so the "Format Source Code" command plugin can be used to format sourcekit-lsp
      .package(url: "https://github.com/swiftlang/swift-format.git", branch: relatedDependenciesBranch),
    ]
  }
}

// MARK: - Compute custom build settings

var sourcekitLSPLinkSettings: [LinkerSetting] {
  if installAction {
    return [.unsafeFlags(["-no-toolchain-stdlib-rpath"], .when(platforms: [.linux, .android]))]
  } else {
    return []
  }
}

var lspLoggingSwiftSettings: [SwiftSetting] {
  if forceNonDarwinLogger {
    return [.define("SOURCEKITLSP_FORCE_NON_DARWIN_LOGGER")]
  } else {
    return []
  }
}
