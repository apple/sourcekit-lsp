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
  InitializeRequest.self,
  ShutdownRequest.self,
  WorkspaceFoldersRequest.self,
  CompletionRequest.self,
  CompletionItem.self,
  HoverRequest.self,
  WorkspaceSemanticTokensRefreshRequest.self,
  WorkspaceSymbolsRequest.self,
  CallHierarchyIncomingCallsRequest.self,
  CallHierarchyOutgoingCallsRequest.self,
  CallHierarchyPrepareRequest.self,
  TypeHierarchyPrepareRequest.self,
  TypeHierarchySupertypesRequest.self,
  TypeHierarchySubtypesRequest.self,
  DeclarationRequest.self,
  DefinitionRequest.self,
  ImplementationRequest.self,
  ReferencesRequest.self,
  DocumentHighlightRequest.self,
  DocumentFormattingRequest.self,
  DocumentRangeFormattingRequest.self,
  DocumentSemanticTokensDeltaRequest.self,
  DocumentSemanticTokensRangeRequest.self,
  DocumentSemanticTokensRequest.self,
  DocumentOnTypeFormattingRequest.self,
  FoldingRangeRequest.self,
  DocumentSymbolRequest.self,
  DocumentColorRequest.self,
  ColorPresentationRequest.self,
  CodeActionRequest.self,
  ExecuteCommandRequest.self,
  ApplyEditRequest.self,
  PrepareRenameRequest.self,
  RenameRequest.self,
  RegisterCapabilityRequest.self,
  TypeDefinitionRequest.self,
  UnregisterCapabilityRequest.self,
  InlayHintRequest.self,

  // MARK: LSP Extension Requests

  SymbolInfoRequest.self,
  PollIndexRequest.self,
]

/// The set of known notifications.
///
/// All notifications from LSP as well as any extensions provided by the server should be listed
/// here. If you are adding a message for testing only, you can register it dynamically using
/// `MessageRegistry._register()` which allows you to avoid bloating the real server implementation.
public let builtinNotifications: [NotificationType.Type] = [
  InitializedNotification.self,
  ExitNotification.self,
  CancelRequestNotification.self,
  LogMessageNotification.self,
  DidChangeConfigurationNotification.self,
  DidChangeWatchedFilesNotification.self,
  DidChangeWorkspaceFoldersNotification.self,
  DidOpenTextDocumentNotification.self,
  DidCloseTextDocumentNotification.self,
  DidChangeTextDocumentNotification.self,
  DidSaveTextDocumentNotification.self,
  WillSaveTextDocumentNotification.self,
  PublishDiagnosticsNotification.self,
]

// MARK: Miscellaneous Message Types

public struct VoidResponse: ResponseType, Hashable {
  public init() {}
}

extension Optional: MessageType where Wrapped: MessageType {}
extension Optional: ResponseType where Wrapped: ResponseType {}

extension Array: MessageType where Element: MessageType {}
extension Array: ResponseType where Element: ResponseType {}
