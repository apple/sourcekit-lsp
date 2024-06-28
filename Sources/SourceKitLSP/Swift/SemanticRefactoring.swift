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

import LSPLogging
import LanguageServerProtocol
import SourceKitD

/// Detailed information about the result of a specific refactoring operation.
///
/// Wraps the information returned by sourcekitd's `semantic_refactoring`
/// request, such as the necessary edits and placeholder locations.
struct SemanticRefactoring: RefactoringResponse {

  /// The title of the refactoring action.
  var title: String

  /// The resulting `WorkspaceEdit` of a `semantic_refactoring` request.
  var edit: WorkspaceEdit

  init(_ title: String, _ edit: WorkspaceEdit) {
    self.title = title
    self.edit = edit
  }

  init(title: String, uri: DocumentURI, refactoringEdits: [RefactoringEdit]) {
    self.title = title
    self.edit = WorkspaceEdit(changes: [
      uri: refactoringEdits.map { TextEdit(range: $0.range, newText: $0.newText) }
    ])
  }
}

/// An error from a semantic refactoring request.
enum SemanticRefactoringError: Error {
  /// The underlying sourcekitd request failed with the given error.
  case responseError(ResponseError)

  /// The underlying sourcekitd reported no edits for this action.
  case noEditsNeeded(DocumentURI)
}

extension SemanticRefactoringError: CustomStringConvertible {
  var description: String {
    switch self {
    case .responseError(let error):
      return "\(error)"
    case .noEditsNeeded(let url):
      return "no edits reported for semantic refactoring action for url \(url)"
    }
  }
}

extension SwiftLanguageService {

  /// Handles the `SemanticRefactorCommand`.
  ///
  /// Sends a request to sourcekitd and wraps the result into a
  /// `SemanticRefactoring` and then makes an `ApplyEditRequest` to the client
  /// side for the actual refactoring.
  ///
  /// - Parameters:
  ///   - semanticRefactorCommand: The `SemanticRefactorCommand` that triggered this request.
  func semanticRefactoring(
    _ semanticRefactorCommand: SemanticRefactorCommand
  ) async throws {
    guard let sourceKitLSPServer else {
      // `SourceKitLSPServer` has been destructed. We are tearing down the
      // language server. Nothing left to do.
      throw ResponseError.unknown("Connection to the editor closed")
    }

    let semanticRefactor = try await self.refactoring(semanticRefactorCommand)

    let edit = semanticRefactor.edit
    let req = ApplyEditRequest(label: semanticRefactor.title, edit: edit)
    let response = try await sourceKitLSPServer.sendRequestToClient(req)
    if !response.applied {
      let reason: String
      if let failureReason = response.failureReason {
        reason = " reason: \(failureReason)"
      } else {
        reason = ""
      }
      logger.error("client refused to apply edit for \(semanticRefactor.title, privacy: .public) \(reason)")
    }
  }
}
