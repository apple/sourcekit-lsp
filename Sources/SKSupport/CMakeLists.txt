
add_library(SKSupport STATIC
  AbsolutePath+Init.swift
  Atomics.swift
  BuildConfiguration.swift
  ByteString.swift
  Connection+Send.swift
  dlopen.swift
  DocumentURI+CustomLogStringConvertible.swift
  FileSystem.swift
  LineTable.swift
  PipeAsStringHandler.swift
  Process+Run.swift
  Random.swift
  Result.swift
  SwitchableProcessResultExitStatus.swift
  WorkspaceType.swift
)
set_target_properties(SKSupport PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})
target_link_libraries(SKSupport PUBLIC
  CAtomics
)
target_link_libraries(SKSupport PRIVATE
  LanguageServerProtocol
  LSPLogging
  SwiftExtensions
  TSCBasic
  $<$<NOT:$<PLATFORM_ID:Darwin>>:Foundation>)
