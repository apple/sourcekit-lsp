if(CMAKE_VERSION VERSION_LESS 3.16)
  if(CMAKE_SYSTEM_NAME STREQUAL Windows)
    set(CMAKE_LINK_LIBRARY_FLAG "-l")
    set(CMAKE_LINK_LIBRARY_SUFFIX "")
  endif()
endif()

add_library(SourceKitLSP
  CapabilityRegistry.swift
  DocumentManager.swift
  IndexStoreDB+MainFilesProvider.swift
  SourceKitIndexDelegate.swift
  SourceKitLSPCommandMetadata.swift
  SourceKitServer+Options.swift
  SourceKitServer.swift
  ToolchainLanguageServer.swift
  Workspace.swift)
target_sources(SourceKitLSP PRIVATE
  Clang/ClangLanguageServer.swift)
target_sources(SourceKitLSP PRIVATE
  Swift/CodeCompletion.swift
  Swift/CodeCompletionSession.swift
  Swift/CommentXML.swift
  Swift/CursorInfo.swift
  Swift/Diagnostic.swift
  Swift/EditorPlaceholder.swift
  Swift/ExpressionTypeInfo.swift
  Swift/SemanticRefactorCommand.swift
  Swift/SemanticRefactoring.swift
  Swift/SourceKitD+ResponseError.swift
  Swift/SwiftCommand.swift
  Swift/SwiftLanguageServer.swift
  Swift/SyntaxHighlightingToken.swift
  Swift/VariableTypeInfo.swift)
set_target_properties(SourceKitLSP PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})
# TODO(compnerd) reduce the exposure here, why is everything PUBLIC-ly linked?
target_link_libraries(SourceKitLSP PUBLIC
  Csourcekitd
  BuildServerProtocol
  IndexStoreDB
  LanguageServerProtocol
  LanguageServerProtocolJSONRPC
  SKCore
  SKSwiftPMWorkspace
  SourceKitD
  TSCUtility)
if(NOT CMAKE_SYSTEM_NAME STREQUAL Darwin)
  if(Foundation_FOUND)
    target_link_libraries(SourceKitLSP PRIVATE
      FoundationXML)
  endif()
endif()

if(BUILD_SHARED_LIBS)
  get_swift_host_arch(swift_arch)
  install(TARGETS SourceKitLSP
    ARCHIVE DESTINATION lib/swift$<$<NOT:$<BOOL:${BUILD_SHARED_LIBS}>>:_static>/$<LOWER_CASE:${CMAKE_SYSTEM_NAME}>
    LIBRARY DESTINATION lib/swift$<$<NOT:$<BOOL:${BUILD_SHARED_LIBS}>>:_static>/$<LOWER_CASE:${CMAKE_SYSTEM_NAME}>
    RUNTIME DESTINATION bin)
  install(FILES
    $<TARGET_PROPERTY:SourceKitLSP,Swift_MODULE_DIRECTORY>/SourceKitLSP.swiftdoc
    $<TARGET_PROPERTY:SourceKitLSP,Swift_MODULE_DIRECTORY>/SourceKitLSP.swiftmodule
    DESTINATION lib/swift$<$<NOT:$<BOOL:${BUILD_SHARED_LIBS}>>:_static>/$<LOWER_CASE:${CMAKE_SYSTEM_NAME}>)
endif()
