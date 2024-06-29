
add_library(SKCore STATIC
  BuildServerBuildSystem.swift
  BuildSystem.swift
  BuildSystemDelegate.swift
  BuildSystemManager.swift
  CompilationDatabase.swift
  CompilationDatabaseBuildSystem.swift
  Debouncer.swift
  ExperimentalFeatures.swift
  FallbackBuildSystem.swift
  FileBuildSettings.swift
  IndexTaskID.swift
  MainFilesProvider.swift
  PathPrefixMapping.swift
  SourceKitLSPOptions.swift
  SplitShellCommand.swift
  TaskScheduler.swift
  Toolchain.swift
  ToolchainRegistry.swift
  XCToolchainPlist.swift)
set_target_properties(SKCore PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})
target_link_libraries(SKCore PUBLIC
  BuildServerProtocol
  LanguageServerProtocol
  LanguageServerProtocolJSONRPC
  LSPLogging
  SKSupport
  SourceKitD
  SwiftExtensions
  PackageModel
  TSCBasic)
