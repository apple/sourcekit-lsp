// swift-tools-version:5.3

import PackageDescription

let package = Package(
    name: "SourceKitLSP",
    platforms: [.macOS(.v10_15)],
    products: [
      .executable(
        name: "sourcekit-lsp",
        targets: ["sourcekit-lsp"]
      ),
      .library(
        name: "_SourceKitLSP",
        type: .dynamic,
        targets: ["SourceKitLSP"]
      ),
      .library(
        name: "LSPBindings",
        type: .static,
        targets: [
          "LanguageServerProtocol",
          "LanguageServerProtocolJSONRPC",
        ]
      )
    ],
    dependencies: [
      // See 'Dependencies' below.
    ],
    targets: [
      .target(
        name: "sourcekit-lsp",
        dependencies: [
          "LanguageServerProtocolJSONRPC",
          "SourceKitLSP",
          .product(name: "ArgumentParser", package: "swift-argument-parser"),
          .product(name: "SwiftToolsSupport-auto", package: "swift-tools-support-core"),
        ],
        exclude: ["CMakeLists.txt"]),

      .target(
        name: "SourceKitLSP",
        dependencies: [
          "BuildServerProtocol",
          "IndexStoreDB",
          "LanguageServerProtocol",
          "LanguageServerProtocolJSONRPC",
          "SKCore",
          "SourceKitD",
          "SKSwiftPMWorkspace",
          .product(name: "SwiftToolsSupport-auto", package: "swift-tools-support-core"),
        ],
        exclude: ["CMakeLists.txt"]),

      .target(
        name: "CSKTestSupport",
        dependencies: []),
      .target(
        name: "SKTestSupport",
        dependencies: [
          "CSKTestSupport",
          "LSPTestSupport",
          "SourceKitLSP",
          .product(name: "ISDBTestSupport", package: "IndexStoreDB"),
          .product(name: "tibs", package: "IndexStoreDB"), // Never imported, needed at runtime
          .product(name: "SwiftToolsSupport-auto", package: "swift-tools-support-core"),
        ], 
        resources: [
          .copy("INPUTS"),
        ]
      ),
      .testTarget(
        name: "SourceKitLSPTests",
        dependencies: [
          "SKTestSupport",
          "SourceKitLSP",
        ]
      ),

      .target(
        name: "SKSwiftPMWorkspace",
        dependencies: [
          "BuildServerProtocol",
          "LanguageServerProtocol",
          "SKCore",
          .product(name: "SwiftPM-auto", package: "SwiftPM"),
        ] + (useLocalPackageDescriptionModule() ? [
          .product(name: "PackageDescription", package: "SwiftPM"),
        ] : []),
        exclude: ["CMakeLists.txt"],
        swiftSettings: useLocalPackageDescriptionModule() ? [
          .define("USE_LOCAL_PACKAGE_DESCRIPTION_MODULE")
        ] : []),

      .testTarget(
        name: "SKSwiftPMWorkspaceTests",
        dependencies: [
          "SKSwiftPMWorkspace",
          "SKTestSupport",
          .product(name: "SwiftToolsSupport-auto", package: "swift-tools-support-core"),
        ]
      ),

      // SKCore: Data structures and algorithms useful across the project, but not necessarily
      // suitable for use in other packages.
      .target(
        name: "SKCore",
        dependencies: [
          "SourceKitD",
          "BuildServerProtocol",
          "LanguageServerProtocol",
          "LanguageServerProtocolJSONRPC",
          "SKSupport",
          .product(name: "SwiftToolsSupport-auto", package: "swift-tools-support-core"),
        ],
        exclude: ["CMakeLists.txt"]),

      .testTarget(
        name: "SKCoreTests",
        dependencies: [
          "SKCore",
          "SKTestSupport",
        ]
      ),

      // SourceKitD: Swift bindings for sourcekitd.
      .target(
        name: "SourceKitD",
        dependencies: [
          "Csourcekitd",
          "LSPLogging",
          "SKSupport",
          .product(name: "SwiftToolsSupport-auto", package: "swift-tools-support-core"),
        ],
        exclude: ["CMakeLists.txt"]),

      .testTarget(
        name: "SourceKitDTests",
        dependencies: [
          "SourceKitD",
          "SKCore",
          "SKTestSupport",
        ]
      ),

      // Csourcekitd: C modules wrapper for sourcekitd.
      .target(
        name: "Csourcekitd",
        dependencies: [],
        exclude: ["CMakeLists.txt"]),

      // Logging support used in LSP modules.
      .target(
        name: "LSPLogging",
        dependencies: [],
        exclude: ["CMakeLists.txt"]),

      .testTarget(
        name: "LSPLoggingTests",
        dependencies: [
          "LSPLogging",
        ]
      ),

      .target(
        name: "LSPTestSupport",
        dependencies: [
          "LanguageServerProtocol",
          "LanguageServerProtocolJSONRPC"
        ]
      ),

      // jsonrpc: LSP connection using jsonrpc over pipes.
      .target(
        name: "LanguageServerProtocolJSONRPC",
        dependencies: [
          "LanguageServerProtocol",
          "LSPLogging",
        ],
        exclude: ["CMakeLists.txt"]),

      .testTarget(
        name: "LanguageServerProtocolJSONRPCTests",
        dependencies: [
          "LanguageServerProtocolJSONRPC",
          "LSPTestSupport"
        ]
      ),

      // LanguageServerProtocol: The core LSP types, suitable for any LSP implementation.
      .target(
        name: "LanguageServerProtocol",
        dependencies: [],
        exclude: ["CMakeLists.txt"]),

      .testTarget(
        name: "LanguageServerProtocolTests",
        dependencies: [
          "LanguageServerProtocol",
          "LSPTestSupport",
        ]
      ),

      // BuildServerProtocol: connection between build server and language server to provide build and index info
      .target(
        name: "BuildServerProtocol",
        dependencies: [
          "LanguageServerProtocol"
        ],
        exclude: ["CMakeLists.txt"]),

      // SKSupport: Data structures, algorithms and platform-abstraction code that might be generally
      // useful to any Swift package. Similar in spirit to SwiftPM's Basic module.
      .target(
        name: "SKSupport",
        dependencies: [
          .product(name: "SwiftToolsSupport-auto", package: "swift-tools-support-core"),
        ],
        exclude: ["CMakeLists.txt"]),

      .testTarget(
        name: "SKSupportTests",
        dependencies: [
          "LSPTestSupport",
          "SKSupport",
          "SKTestSupport",
        ]
      ),
    ]
)

// MARK: Dependencies

// When building with the swift build-script, use local dependencies whose contents are controlled
// by the external environment. This allows sourcekit-lsp to take advantage of the automation used
// for building the swift toolchain, such as `update-checkout`, or cross-repo PR tests.

import Foundation

if ProcessInfo.processInfo.environment["SWIFTCI_USE_LOCAL_DEPS"] == nil {
  // Building standalone.
  package.dependencies += [
    .package(name: "IndexStoreDB", url: "https://github.com/apple/indexstore-db.git", .branch("main")),
    .package(name: "SwiftPM", url: "https://github.com/apple/swift-package-manager.git", .branch("main")),
    .package(url: "https://github.com/apple/swift-tools-support-core.git", .branch("main")),
    .package(url: "https://github.com/apple/swift-argument-parser.git", .upToNextMinor(from: "0.4.1")),
  ]
} else {
  package.dependencies += [
    .package(name: "IndexStoreDB", path: "../indexstore-db"),
    .package(name: "SwiftPM", path: "../swiftpm"),
    .package(path: "../swift-tools-support-core"),
    .package(path: "../swift-argument-parser")
  ]
}

func useLocalPackageDescriptionModule() -> Bool {
  // By default, create a local PackageDescription module to ensure it stays
  // in sync with libSwiftPM during development. To install sourcekit-lsp as
  // part of the toolchain we use the toolchain's own PackageDescription, and
  // rely on the whole toolchain being built from the same swiftpm sources.
  return ProcessInfo.processInfo.environment["SWIFTCI_USE_TOOLCHAIN_PACKAGE_DESCRIPTION"] == nil
}
