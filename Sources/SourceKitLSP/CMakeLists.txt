
add_library(SourceKitLSP STATIC
  CapabilityRegistry.swift
  CreateBuildSystem.swift
  DocumentManager.swift
  DocumentSnapshot+FromFileContents.swift
  IndexProgressManager.swift
  IndexStoreDB+MainFilesProvider.swift
  LanguageServerType.swift
  LanguageService.swift
  MessageHandlingDependencyTracker.swift
  Rename.swift
  ResponseError+Init.swift
  SemanticTokensLegend+SourceKitLSPLegend.swift
  SourceKitIndexDelegate.swift
  SourceKitLSPCommandMetadata.swift
  SourceKitLSPServer.swift
  SymbolLocation+DocumentURI.swift
  TestDiscovery.swift
  TestHooks.swift
  TextEdit+IsNoop.swift
  WorkDoneProgressManager.swift
  Workspace.swift
)
target_sources(SourceKitLSP PRIVATE
  Clang/ClangLanguageService.swift
  Clang/SemanticTokenTranslator.swift
)
target_sources(SourceKitLSP PRIVATE
  Swift/AdjustPositionToStartOfIdentifier.swift
  Swift/CodeActions/AddDocumentation.swift
  Swift/CodeActions/ConvertIntegerLiteral.swift
  Swift/CodeActions/ConvertJSONToCodableStruct.swift
  Swift/CodeActions/PackageManifestEdits.swift
  Swift/CodeActions/SyntaxCodeActionProvider.swift
  Swift/CodeActions/SyntaxCodeActions.swift
  Swift/CodeActions/SyntaxRefactoringCodeActionProvider.swift
  Swift/CodeCompletion.swift
  Swift/CodeCompletionSession.swift
  Swift/CommentXML.swift
  Swift/CursorInfo.swift
  Swift/Diagnostic.swift
  Swift/DiagnosticReportManager.swift
  Swift/DocumentFormatting.swift
  Swift/DocumentSymbols.swift
  Swift/ExpandMacroCommand.swift
  Swift/FoldingRange.swift
  Swift/MacroExpansion.swift
  Swift/OpenInterface.swift
  Swift/RefactoringResponse.swift
  Swift/RefactoringEdit.swift
  Swift/RefactorCommand.swift
  Swift/RelatedIdentifiers.swift
  Swift/RewriteSourceKitPlaceholders.swift
  Swift/SemanticRefactorCommand.swift
  Swift/SemanticRefactoring.swift
  Swift/SemanticTokens.swift
  Swift/SourceKitD+ResponseError.swift
  Swift/SwiftCommand.swift
  Swift/SwiftLanguageService.swift
  Swift/SwiftTestingScanner.swift
  Swift/SymbolInfo.swift
  Swift/SyntacticSwiftXCTestScanner.swift
  Swift/SyntacticTestIndex.swift
  Swift/SyntaxHighlightingToken.swift
  Swift/SyntaxHighlightingTokenParser.swift
  Swift/SyntaxHighlightingTokens.swift
  Swift/SyntaxTreeManager.swift
  Swift/VariableTypeInfo.swift
)
set_target_properties(SourceKitLSP PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})
# TODO(compnerd) reduce the exposure here, why is everything PUBLIC-ly linked?
target_link_libraries(SourceKitLSP PUBLIC
  BuildServerProtocol
  LanguageServerProtocol
  LanguageServerProtocolJSONRPC
  LSPLogging
  SemanticIndex
  SKCore
  SKSupport
  SKSwiftPMWorkspace
  SourceKitD
  SwiftExtensions
  IndexStoreDB
  SwiftSyntax::SwiftBasicFormat
  SwiftSyntax::SwiftDiagnostics
  SwiftSyntax::SwiftIDEUtils
  SwiftSyntax::SwiftParser
  SwiftSyntax::SwiftParserDiagnostics
  SwiftSyntax::SwiftRefactor
  SwiftSyntax::SwiftSyntax)
target_link_libraries(SourceKitLSP PRIVATE
  PackageModelSyntax
  $<$<NOT:$<PLATFORM_ID:Darwin>>:FoundationXML>)

