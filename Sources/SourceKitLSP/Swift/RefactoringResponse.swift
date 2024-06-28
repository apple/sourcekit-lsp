//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import LSPLogging
import LanguageServerProtocol
import SourceKitD

protocol RefactoringResponse {
  init(title: String, uri: DocumentURI, refactoringEdits: [RefactoringEdit])
}

extension RefactoringResponse {
  /// Create an instance of `RefactoringResponse` from a sourcekitd semantic
  /// refactoring response dictionary, if possible.
  ///
  /// - Parameters:
  ///   - title: The title of the refactoring action.
  ///   - dict: Response dictionary to extract information from.
  ///   - snapshot: The snapshot that triggered the `semantic_refactoring` request.
  ///   - keys: The sourcekitd key set to use for looking up into `dict`.
  init?(_ title: String, _ dict: SKDResponseDictionary, _ snapshot: DocumentSnapshot, _ keys: sourcekitd_api_keys) {
    guard let categorizedEdits: SKDResponseArray = dict[keys.categorizedEdits] else {
      logger.fault("categorizedEdits doesn't exist in response dictionary")
      return nil
    }

    var refactoringEdits: [RefactoringEdit] = []

    categorizedEdits.forEach { _, categorizedEdit in
      guard let edits: SKDResponseArray = categorizedEdit[keys.edits] else {
        logger.fault("edits doesn't exist in categorizedEdit dictionary")
        return true
      }
      edits.forEach { _, edit in
        guard let startLine: Int = edit[keys.line],
          let startColumn: Int = edit[keys.column],
          let endLine: Int = edit[keys.endLine],
          let endColumn: Int = edit[keys.endColumn],
          let text: String = edit[keys.text]
        else {
          logger.fault("Failed to deserialise edit dictionary containing values: \(edit)")
          return true  // continue
        }

        // The LSP is zero based, but semantic_refactoring is one based.
        let startPosition = snapshot.positionOf(
          zeroBasedLine: startLine - 1,
          utf8Column: startColumn - 1
        )
        let endPosition = snapshot.positionOf(
          zeroBasedLine: endLine - 1,
          utf8Column: endColumn - 1
        )
        // Snippets are only supported in code completion.
        // Remove SourceKit placeholders in refactoring actions because they
        // can't be represented in the editor properly.
        let textWithSnippets = rewriteSourceKitPlaceholders(in: text, clientSupportsSnippets: false)
        refactoringEdits.append(
          RefactoringEdit(
            range: startPosition..<endPosition,
            newText: textWithSnippets,
            bufferName: edit[keys.bufferName]
          )
        )
        return true
      }
      return true
    }

    guard !refactoringEdits.isEmpty else {
      logger.error("No refactoring edits found")
      return nil
    }

    self.init(title: title, uri: snapshot.uri, refactoringEdits: refactoringEdits)
  }
}

extension SwiftLanguageService {
  /// Provides detailed information about the result of a specific refactoring
  /// operation.
  ///
  /// Wraps the information returned by sourcekitd's `semantic_refactoring`
  /// request, such as the necessary edits and placeholder locations.
  ///
  /// - Parameters:
  ///   - refactorCommand: The semantic `RefactorCommand` that triggered this request.
  /// - Returns: The response of the refactoring
  func refactoring<T: RefactorCommand>(
    _ refactorCommand: T
  ) async throws -> T.Response {
    let keys = self.keys

    let uri = refactorCommand.textDocument.uri
    let snapshot = try self.documentManager.latestSnapshot(uri)
    let line = refactorCommand.positionRange.lowerBound.line
    let utf16Column = refactorCommand.positionRange.lowerBound.utf16index
    let utf8Column = snapshot.lineTable.utf8ColumnAt(line: line, utf16Column: utf16Column)

    let skreq = sourcekitd.dictionary([
      keys.request: self.requests.semanticRefactoring,
      // Preferred name for e.g. an extracted variable.
      // Empty string means sourcekitd chooses a name automatically.
      keys.name: "",
      keys.sourceFile: uri.pseudoPath,
      // LSP is zero based, but this request is 1 based.
      keys.line: line + 1,
      keys.column: utf8Column + 1,
      keys.length: snapshot.utf8OffsetRange(of: refactorCommand.positionRange).count,
      keys.actionUID: self.sourcekitd.api.uid_get_from_cstr(refactorCommand.actionString)!,
      keys.compilerArgs: await self.buildSettings(for: snapshot.uri)?.compilerArgs as [SKDRequestValue]?,
    ])

    let dict = try await self.sourcekitd.send(skreq, fileContents: snapshot.text)
    guard let refactor = T.Response(refactorCommand.title, dict, snapshot, self.keys) else {
      throw SemanticRefactoringError.noEditsNeeded(uri)
    }
    return refactor
  }
}
