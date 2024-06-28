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

import Foundation
import LSPLogging
import LanguageServerProtocol
import SourceKitD

/// Detailed information about the result of a macro expansion operation.
///
/// Wraps the information returned by sourcekitd's `semantic_refactoring`
/// request, such as the necessary macro expansion edits.
struct MacroExpansion: RefactoringResponse {
  /// The title of the refactoring action.
  var title: String

  /// The URI of the file where the macro is used
  var uri: DocumentURI

  /// The resulting array of `RefactoringEdit` of a semantic refactoring request
  var edits: [RefactoringEdit]

  init(title: String, uri: DocumentURI, refactoringEdits: [RefactoringEdit]) {
    self.title = title
    self.uri = uri
    self.edits = refactoringEdits.compactMap { refactoringEdit in
      if refactoringEdit.bufferName == nil && !refactoringEdit.newText.isEmpty {
        logger.fault("Unable to retrieve some parts of the expansion")
        return nil
      }

      return refactoringEdit
    }
  }
}

extension SwiftLanguageService {
  /// Handles the `ExpandMacroCommand`.
  ///
  /// Makes a request to sourcekitd and wraps the result into a `MacroExpansion`
  /// and then makes a `ShowDocumentRequest` to the client side for each
  /// expansion to be displayed.
  ///
  /// - Parameters:
  ///   - expandMacroCommand: The `ExpandMacroCommand` that triggered this request.
  ///
  /// - Returns: A `[RefactoringEdit]` with the necessary edits and buffer name as a `LSPAny`
  func expandMacro(
    _ expandMacroCommand: ExpandMacroCommand
  ) async throws -> LSPAny {
    guard let sourceKitLSPServer else {
      // `SourceKitLSPServer` has been destructed. We are tearing down the
      // language server. Nothing left to do.
      throw ResponseError.unknown("Connection to the editor closed")
    }

    guard let sourceFileURL = expandMacroCommand.textDocument.uri.fileURL else {
      throw ResponseError.unknown("Given URI is not a file URL")
    }

    let expansion = try await self.refactoring(expandMacroCommand)

    for macroEdit in expansion.edits {
      if let bufferName = macroEdit.bufferName {
        // buffer name without ".swift"
        let macroExpansionBufferDirectoryName =
          bufferName.hasSuffix(".swift")
          ? String(bufferName.dropLast(6))
          : bufferName

        let macroExpansionBufferDirectoryURL = self.generatedMacroExpansionsPath
          .appendingPathComponent(macroExpansionBufferDirectoryName)
        do {
          try FileManager.default.createDirectory(
            at: macroExpansionBufferDirectoryURL,
            withIntermediateDirectories: true
          )
        } catch {
          throw ResponseError.unknown(
            "Failed to create directory for macro expansion buffer at path: \(macroExpansionBufferDirectoryURL.path)"
          )
        }

        // name of the source file
        let macroExpansionFileName = sourceFileURL.deletingPathExtension().lastPathComponent

        // github permalink notation for position range
        let macroExpansionPositionRangeIndicator =
          "L\(macroEdit.range.lowerBound.line + 1)C\(macroEdit.range.lowerBound.utf16index + 1)-L\(macroEdit.range.upperBound.line + 1)C\(macroEdit.range.upperBound.utf16index + 1)"

        let macroExpansionFilePath =
          macroExpansionBufferDirectoryURL
          .appendingPathComponent(
            "\(macroExpansionFileName)_\(macroExpansionPositionRangeIndicator).\(sourceFileURL.pathExtension)"
          )

        do {
          try macroEdit.newText.write(to: macroExpansionFilePath, atomically: true, encoding: .utf8)
        } catch {
          throw ResponseError.unknown(
            "Unable to write macro expansion to file path: \"\(macroExpansionFilePath.path)\""
          )
        }

        Task {
          let req = ShowDocumentRequest(uri: DocumentURI(macroExpansionFilePath))

          let response = await orLog("Sending ShowDocumentRequest to Client") {
            try await sourceKitLSPServer.sendRequestToClient(req)
          }

          if let response, !response.success {
            logger.error("client refused to show document for \(expansion.title, privacy: .public)")
          }
        }
      } else if !macroEdit.newText.isEmpty {
        logger.fault("Unable to retrieve some parts of macro expansion")
      }
    }

    return expansion.edits.encodeToLSPAny()
  }
}
