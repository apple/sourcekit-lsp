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

/// The set of known requests.
///
/// All requests from LSP as well as any extensions provided by the server should be listed here.
/// If you are adding a message for testing only, you can register it dynamically using
/// `MessageRegistry._register()` which allows you to avoid bloating the real server implementation.
public let builtinRequests: [_RequestType.Type] = [
  ApplyEditRequest.self,
  BarrierRequest.self,
  CallHierarchyIncomingCallsRequest.self,
  CallHierarchyOutgoingCallsRequest.self,
  CallHierarchyPrepareRequest.self,
  CodeActionRequest.self,
  CodeActionResolveRequest.self,
  CodeLensRefreshRequest.self,
  CodeLensRequest.self,
  CodeLensResolveRequest.self,
  ColorPresentationRequest.self,
  CompletionItemResolveRequest.self,
  CompletionRequest.self,
  CreateWorkDoneProgressRequest.self,
  DeclarationRequest.self,
  DefinitionRequest.self,
  DiagnosticsRefreshRequest.self,
  DocumentColorRequest.self,
  DocumentDiagnosticsRequest.self,
  DocumentFormattingRequest.self,
  DocumentHighlightRequest.self,
  DocumentLinkRequest.self,
  DocumentLinkResolveRequest.self,
  DocumentOnTypeFormattingRequest.self,
  DocumentRangeFormattingRequest.self,
  DocumentSemanticTokensDeltaRequest.self,
  DocumentSemanticTokensRangeRequest.self,
  DocumentSemanticTokensRequest.self,
  DocumentSymbolRequest.self,
  DocumentTestsRequest.self,
  ExecuteCommandRequest.self,
  FoldingRangeRequest.self,
  HoverRequest.self,
  ImplementationRequest.self,
  InitializeRequest.self,
  InlayHintRefreshRequest.self,
  InlayHintRequest.self,
  InlayHintResolveRequest.self,
  InlineValueRefreshRequest.self,
  InlineValueRequest.self,
  LinkedEditingRangeRequest.self,
  MonikersRequest.self,
  PeekDocumentsRequest.self,
  PollIndexRequest.self,
  PrepareRenameRequest.self,
  ReferencesRequest.self,
  RegisterCapabilityRequest.self,
  RenameRequest.self,
  SelectionRangeRequest.self,
  ShowDocumentRequest.self,
  ShowMessageRequest.self,
  ShutdownRequest.self,
  SignatureHelpRequest.self,
  SymbolInfoRequest.self,
  TypeDefinitionRequest.self,
  TypeHierarchyPrepareRequest.self,
  TypeHierarchySubtypesRequest.self,
  TypeHierarchySupertypesRequest.self,
  UnregisterCapabilityRequest.self,
  WillCreateFilesRequest.self,
  WillDeleteFilesRequest.self,
  WillRenameFilesRequest.self,
  WillSaveWaitUntilTextDocumentRequest.self,
  WorkspaceDiagnosticsRequest.self,
  WorkspaceFoldersRequest.self,
  WorkspaceSemanticTokensRefreshRequest.self,
  WorkspaceSymbolResolveRequest.self,
  WorkspaceSymbolsRequest.self,
  WorkspaceTestsRequest.self,
]

/// The set of known notifications.
///
/// All notifications from LSP as well as any extensions provided by the server should be listed
/// here. If you are adding a message for testing only, you can register it dynamically using
/// `MessageRegistry._register()` which allows you to avoid bloating the real server implementation.
public let builtinNotifications: [NotificationType.Type] = [
  CancelRequestNotification.self,
  CancelWorkDoneProgressNotification.self,
  DidChangeConfigurationNotification.self,
  DidChangeNotebookDocumentNotification.self,
  DidChangeTextDocumentNotification.self,
  DidChangeWatchedFilesNotification.self,
  DidChangeWorkspaceFoldersNotification.self,
  DidCloseNotebookDocumentNotification.self,
  DidCloseTextDocumentNotification.self,
  DidCreateFilesNotification.self,
  DidDeleteFilesNotification.self,
  DidOpenNotebookDocumentNotification.self,
  DidOpenTextDocumentNotification.self,
  DidRenameFilesNotification.self,
  DidSaveNotebookDocumentNotification.self,
  DidSaveTextDocumentNotification.self,
  ExitNotification.self,
  InitializedNotification.self,
  LogMessageNotification.self,
  LogTraceNotification.self,
  PublishDiagnosticsNotification.self,
  SetTraceNotification.self,
  ShowMessageNotification.self,
  WillSaveTextDocumentNotification.self,
  WorkDoneProgress.self,
]

// MARK: Miscellaneous Message Types

public struct VoidResponse: ResponseType, Hashable {
  public init() {}
}

extension Optional: MessageType where Wrapped: MessageType {}
extension Optional: ResponseType where Wrapped: ResponseType {}

extension Array: MessageType where Element: MessageType {}
extension Array: ResponseType where Element: ResponseType {}
