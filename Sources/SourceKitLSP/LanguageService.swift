//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import LanguageServerProtocol
import SKCore
import SwiftSyntax

/// The state of a `ToolchainLanguageServer`
public enum LanguageServerState {
  /// The language server is running with semantic functionality enabled
  case connected
  /// The language server server has crashed and we are waiting for it to relaunch
  case connectionInterrupted
  /// The language server has relaunched but semantic functionality is currently disabled
  case semanticFunctionalityDisabled
}

public struct AnnotatedTestItem: Sendable {
  /// The test item to be annotated
  public var testItem: TestItem

  /// Whether the `TestItem` is an extension.
  public var isExtension: Bool

  public init(
    testItem: TestItem,
    isExtension: Bool
  ) {
    self.testItem = testItem
    self.isExtension = isExtension
  }
}

public struct RenameLocation: Sendable {
  /// How the identifier at a given location is being used.
  ///
  /// This is primarily used to influence how argument labels should be renamed in Swift and if a location should be
  /// rejected if argument labels don't match.
  enum Usage {
    /// The definition of a function/subscript/variable/...
    case definition

    /// The symbol is being referenced.
    ///
    /// This includes
    ///  - References to variables
    ///  - Unapplied references to functions (`myStruct.memberFunc`)
    ///  - Calls to subscripts (`myArray[1]`, location is `[` here, length 1)
    case reference

    /// A function that is being called.
    case call

    /// Unknown name usage occurs if we don't have an entry in the index that
    /// tells us whether the location is a call, reference or a definition. The
    /// most common reasons why this happens is if the editor is adding syntactic
    /// results (eg. from comments or string literals).
    case unknown
  }

  /// The line of the identifier to be renamed (1-based).
  let line: Int

  /// The column of the identifier to be renamed in UTF-8 bytes (1-based).
  let utf8Column: Int

  let usage: Usage
}

/// The textual output of a module interface.
public struct GeneratedInterfaceDetails: ResponseType, Hashable {
  public var uri: DocumentURI
  public var position: Position?

  public init(uri: DocumentURI, position: Position?) {
    self.uri = uri
    self.position = position
  }
}

/// Provides language specific functionality to sourcekit-lsp from a specific toolchain.
///
/// For example, we may have a language service that provides semantic functionality for c-family using a clangd server,
/// launched from a specific toolchain or from sourcekitd.
public protocol LanguageService: AnyObject, Sendable {

  // MARK: - Creation

  init?(
    sourceKitLSPServer: SourceKitLSPServer,
    toolchain: Toolchain,
    options: SourceKitLSPOptions,
    testHooks: TestHooks,
    workspace: Workspace
  ) async throws

  /// Returns `true` if this instance of the language server can handle opening documents in `workspace`.
  ///
  /// If this returns `false`, a new language server will be started for `workspace`.
  func canHandle(workspace: Workspace) -> Bool

  // MARK: - Lifetime

  func initialize(_ initialize: InitializeRequest) async throws -> InitializeResult
  func clientInitialized(_ initialized: InitializedNotification) async

  /// Shut the server down and return once the server has finished shutting down
  func shutdown() async

  /// Add a handler that is called whenever the state of the language server changes.
  func addStateChangeHandler(
    handler: @Sendable @escaping (_ oldState: LanguageServerState, _ newState: LanguageServerState) -> Void
  ) async

  // MARK: - Text synchronization

  /// Sent to open up a document on the Language Server.
  ///
  /// This may be called before or after a corresponding `documentUpdatedBuildSettings` call for the same document.
  func openDocument(_ notification: DidOpenTextDocumentNotification, snapshot: DocumentSnapshot) async
 

  /// Sent to close a document on the Language Server.
  func closeDocument(_ notification: DidCloseTextDocumentNotification) async

  /// Re-open the given document, discarding any in-memory state and forcing an AST to be re-built after build settings
  /// have been changed. This needs to be handled via a notification to ensure that no other request for this document
  /// is executing at the same time.
  ///
  /// Only intended for `SwiftLanguageService`.
  func reopenDocument(_ notification: ReopenTextDocumentNotification) async

  func changeDocument(
    _ notification: DidChangeTextDocumentNotification,
    preEditSnapshot: DocumentSnapshot,
    postEditSnapshot: DocumentSnapshot,
    edits: [SourceEdit]
  ) async
  func willSaveDocument(_ notification: WillSaveTextDocumentNotification) async
  func didSaveDocument(_ notification: DidSaveTextDocumentNotification) async

  // MARK: - Build System Integration

  /// Sent when the `BuildSystem` has resolved build settings, such as for the initial build settings
  /// or when the settings have changed (e.g. modified build system files). This may be sent before
  /// the respective `DocumentURI` has been opened.
  func documentUpdatedBuildSettings(_ uri: DocumentURI) async

  /// Sent when the `BuildSystem` has detected that dependencies of the given file have changed
  /// (e.g. header files, swiftmodule files, other compiler input files).
  func documentDependenciesUpdated(_ uri: DocumentURI) async

  // MARK: - Text Document

  func completion(_ req: CompletionRequest) async throws -> CompletionList
  func hover(_ req: HoverRequest) async throws -> HoverResponse?
  func symbolInfo(_ request: SymbolInfoRequest) async throws -> [SymbolDetails]

  /// Request a generated interface of a module to display in the IDE.
  ///
  /// - Parameters:
  ///   - document: The document whose compiler arguments should be used to generate the interface.
  ///   - moduleName: The module to generate an index for.
  ///   - groupName: The module group name.
  ///   - symbol: The symbol USR to search for in the generated module interface.
  func openGeneratedInterface(
    document: DocumentURI,
    moduleName: String,
    groupName: String?,
    symbolUSR symbol: String?
  ) async throws -> GeneratedInterfaceDetails?

  /// - Note: Only called as a fallback if the definition could not be found in the index.
  func definition(_ request: DefinitionRequest) async throws -> LocationsOrLocationLinksResponse?

  func declaration(_ request: DeclarationRequest) async throws -> LocationsOrLocationLinksResponse?
  func documentSymbolHighlight(_ req: DocumentHighlightRequest) async throws -> [DocumentHighlight]?
  func foldingRange(_ req: FoldingRangeRequest) async throws -> [FoldingRange]?
  func documentSymbol(_ req: DocumentSymbolRequest) async throws -> DocumentSymbolResponse?
  func documentColor(_ req: DocumentColorRequest) async throws -> [ColorInformation]
  func documentSemanticTokens(_ req: DocumentSemanticTokensRequest) async throws -> DocumentSemanticTokensResponse?
  func documentSemanticTokensDelta(
    _ req: DocumentSemanticTokensDeltaRequest
  ) async throws -> DocumentSemanticTokensDeltaResponse?
  func documentSemanticTokensRange(
    _ req: DocumentSemanticTokensRangeRequest
  ) async throws -> DocumentSemanticTokensResponse?
  func colorPresentation(_ req: ColorPresentationRequest) async throws -> [ColorPresentation]
  func codeAction(_ req: CodeActionRequest) async throws -> CodeActionRequestResponse?
  func inlayHint(_ req: InlayHintRequest) async throws -> [InlayHint]
  func documentDiagnostic(_ req: DocumentDiagnosticsRequest) async throws -> DocumentDiagnosticReport
  func documentFormatting(_ req: DocumentFormattingRequest) async throws -> [TextEdit]?

  // MARK: - Rename

  /// Entry point to perform rename.
  ///
  /// Rename is implemented as a two-step process:  This function returns all the edits it knows need to be performed.
  /// For Swift these edits are those within the current file. In addition, it can return a USR + the old name of the
  /// symbol to be renamed so that `SourceKitLSPServer` can perform an index lookup to discover more locations to rename
  /// within the entire workspace. `SourceKitLSPServer` will transform those into edits by calling
  /// `editsToRename(locations:in:oldName:newName:)` on the toolchain server to perform the actual rename.
  func rename(_ request: RenameRequest) async throws -> (edits: WorkspaceEdit, usr: String?)

  /// Given a list of `locations``, return the list of edits that need to be performed to rename these occurrences from
  /// `oldName` to `newName`.
  func editsToRename(
    locations renameLocations: [RenameLocation],
    in snapshot: DocumentSnapshot,
    oldName: CrossLanguageName,
    newName: CrossLanguageName
  ) async throws -> [TextEdit]

  /// Return compound decl name that will be used as a placeholder for a rename request at a specific position.
  func prepareRename(
    _ request: PrepareRenameRequest
  ) async throws -> (prepareRename: PrepareRenameResponse, usr: String?)?

  func indexedRename(_ request: IndexedRenameRequest) async throws -> WorkspaceEdit?

  /// If there is a function-like definition at the given `renamePosition`, rename all the references to parameters
  /// inside the function's body.
  ///
  /// For example, this produces the edit to rename the occurrence of `x` inside `print` in the following
  ///
  /// ```swift
  /// func foo(x: Int) { print(x) }
  /// ```
  ///
  /// - Parameters:
  ///   - snapshot: A `DocumentSnapshot` containing the file contents
  ///   - renameLocation: The position of the function's base name (in front of `foo` in the above example)
  ///   - newName: The new name of the function (eg. `bar(y:)` in the above example)
  func editsToRenameParametersInFunctionBody(
    snapshot: DocumentSnapshot,
    renameLocation: RenameLocation,
    newName: CrossLanguageName
  ) async -> [TextEdit]

  // MARK: - Other

  func executeCommand(_ req: ExecuteCommandRequest) async throws -> LSPAny?

  /// Perform a syntactic scan of the file at the given URI for test cases and test classes.
  ///
  /// This is used as a fallback to show the test cases in a file if the index for a given file is not up-to-date.
  ///
  /// A return value of `nil` indicates that this language service does not support syntactic test discovery.
  func syntacticDocumentTests(for uri: DocumentURI, in workspace: Workspace) async throws -> [AnnotatedTestItem]?

  /// A position that is canonical for all positions within a declaration. For example, if we have the following
  /// declaration, then all `|` markers should return the same canonical position.
  /// ```
  /// func |fo|o(|ba|r: Int)
  /// ```
  /// The actual position returned by the method does not matter. All that's relevant is the canonicalization.
  ///
  /// Returns `nil` if no canonical position could be determined.
  func canonicalDeclarationPosition(of position: Position, in uri: DocumentURI) async -> Position?

  /// Crash the language server. Should be used for crash recovery testing only.
  func crash() async
}
