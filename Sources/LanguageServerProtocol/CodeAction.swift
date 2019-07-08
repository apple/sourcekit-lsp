//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import SKSupport

public typealias CodeActionProviderCompletion = (([CodeAction]) -> Void)
public typealias CodeActionProvider = ((CodeActionRequest, @escaping CodeActionProviderCompletion) -> Void)

/// Request for returning all possible code actions for a given text document and range.
///
/// The code action request is sent from the client to the server to compute commands for a given text
/// document and range. These commands are typically code fixes to either fix problems or to beautify/
/// refactor code.
///
/// Servers that provide code actions should set the `codeActions` server capability.
///
/// - Parameters:
///   - textDocument: The document in which the command was invoked.
///   - range: The specific range inside the document to search for code actions.
///   - context: The context of the request.
///
/// - Returns: A list of code actions for the given range and context.
public struct CodeActionRequest: TextDocumentRequest, Hashable {
  public static let method: String = "textDocument/codeAction"
  public typealias Response = CodeActionRequestResponse?

  /// The range for which the command was invoked.
  public var range: PositionRange

  /// Context carrying additional information.
  public var context: CodeActionContext

  /// The document in which the command was invoked.
  public var textDocument: TextDocumentIdentifier

  public init(range: Range<Position>, context: CodeActionContext, textDocument: TextDocumentIdentifier) {
    self.range = PositionRange(range)
    self.context = context
    self.textDocument = textDocument
  }

  public func injectMetadata(atResponse response: CodeActionRequestResponse?) -> CodeActionRequestResponse? {
    let metadata = SourceKitLSPCommandMetadata(textDocument: textDocument)
    guard let data = try? JSONEncoder().encode(metadata),
          let metadataArgument = try? JSONDecoder().decode(CommandArgumentType.self, from: data) else
    {
      log("failed to inject metadata in codeAction response", level: .error)
      return nil
    }
    switch response {
    case .codeActions(var codeActions)?:
      for i in 0..<codeActions.count {
        codeActions[i].command?.arguments?.append(metadataArgument)
      }
      return .codeActions(codeActions)
    case .commands(var commands)?:
      for i in 0..<commands.count {
        commands[i].arguments?.append(metadataArgument)
      }
      return .commands(commands)
    case nil:
      return nil
    }
  }
}

/// Wrapper type for the response of a CodeAction request.
/// If the client supports CodeAction literals, the encoded type will be the CodeAction array itself.
/// Otherwise, the encoded value will be an array of CodeActions' inner Command structs.
public enum CodeActionRequestResponse: ResponseType, Codable, Equatable {
  case codeActions([CodeAction])
  case commands([Command])

  public init(codeActions: [CodeAction], clientCapabilities: TextDocumentClientCapabilities.CodeAction?) {
    if let literalSupport = clientCapabilities?.codeActionLiteralSupport {
      let supportedKinds = literalSupport.codeActionKind.valueSet
      self = .codeActions(codeActions.filter {
        if let kind = $0.kind {
          return supportedKinds.contains(kind)
        } else {
          // The client guarantees that unsupported kinds will be treated,
          // so it's probably safe to include unspecified kinds into the result.
          return true
        }
      })
    } else {
      self = .commands(codeActions.compactMap { $0.command })
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let codeActions = try? container.decode([CodeAction].self) {
      self = .codeActions(codeActions)
    } else if let commands = try? container.decode([Command].self) {
      self = .commands(commands)
    } else {
      let error = "CodeActionRequestResponse has neither a CodeAction or a Command."
      throw DecodingError.dataCorruptedError(in: container, debugDescription: error)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .codeActions(let codeActions):
      try container.encode(codeActions)
    case .commands(let commands):
      try container.encode(commands)
    }
  }
}

public struct CodeActionContext: Codable, Hashable {

  /// An array of diagnostics.
  public var diagnostics: [Diagnostic]

  /// Requested kind of actions to return.
  /// If provided, actions of these kinds are filtered out by the client before being shown,
  /// so servers can omit computing them.
  public var only: [CodeActionKind]?

  public init(diagnostics: [Diagnostic] = [], only: [CodeActionKind]? = nil) {
    self.diagnostics = diagnostics
    self.only = only
  }
}

public struct CodeAction: Codable, Equatable, ResponseType {

  /// A short, human-readable, title for this code action.
  public var title: String

  /// The kind of the code action.
  public var kind: CodeActionKind?

  /// The diagnostics that this code action resolves, if applicable.
  public var diagnostics: [Diagnostic]?

  /// The workspace edit this code action performs.
  public var edit: WorkspaceEdit?

  /// A command this code action executes.
  /// If a code action provides an edit and a command,
  /// first the edit is executed and then the command.
  public var command: Command?

  public init(title: String, kind: CodeActionKind? = nil, diagnostics: [Diagnostic]? = nil, edit: WorkspaceEdit? = nil, command: Command? = nil) {
    self.title = title
    self.kind = kind
    self.diagnostics = diagnostics
    self.edit = edit
    self.command = command
  }
}
