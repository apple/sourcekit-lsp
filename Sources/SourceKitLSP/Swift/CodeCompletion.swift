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

import LanguageServerProtocol
import LSPLogging
import SourceKitD
import Foundation

extension SwiftLanguageServer {

  /// Must be called on `queue`.
  func _completion(_ req: Request<CompletionRequest>) {
    guard let snapshot = documentManager.latestSnapshot(req.params.textDocument.uri) else {
      log("failed to find snapshot for url \(req.params.textDocument.uri)")
      req.reply(CompletionList(isIncomplete: true, items: []))
      return
    }

    guard let completionPos = adjustCompletionLocation(req.params.position, in: snapshot) else {
      log("invalid completion position \(req.params.position)")
      req.reply(CompletionList(isIncomplete: true, items: []))
      return
    }

    guard let offset = snapshot.utf8Offset(of: completionPos) else {
      log("invalid completion position \(req.params.position) (adjusted: \(completionPos)")
      req.reply(CompletionList(isIncomplete: true, items: []))
      return
    }

    let options = req.params.sourcekitlspOptions ?? serverOptions.completionOptions

    if options.serverSideFiltering {
      _completionWithServerFiltering(offset: offset, completionPos: completionPos, snapshot: snapshot, request: req, options: options)
    } else {
      _completionWithClientFiltering(offset: offset, completionPos: completionPos, snapshot: snapshot, request: req, options: options)
    }
  }

  /// Must be called on `queue`.
  func _completionWithServerFiltering(offset: Int, completionPos: Position, snapshot: DocumentSnapshot, request req: Request<CompletionRequest>, options: SKCompletionOptions) {
    guard let start = snapshot.indexOf(utf8Offset: offset),
          let end = snapshot.index(of: req.params.position) else {
      log("invalid completion position \(req.params.position)")
      return req.reply(CompletionList(isIncomplete: true, items: []))
    }

    let filterText = String(snapshot.text[start..<end])

    let session: CodeCompletionSession
    if req.params.context?.triggerKind == .triggerFromIncompleteCompletions {
      guard let currentSession = currentCompletionSession else {
        log("triggerFromIncompleteCompletions with no existing completion session", level: .warning)
        return req.reply(.failure(.cancelled))
      }
      guard currentSession.uri == snapshot.document.uri, currentSession.utf8StartOffset == offset else {
        log("triggerFromIncompleteCompletions with incompatible completion session; expected \(currentSession.uri)@\(currentSession.utf8StartOffset), but got \(snapshot.document.uri)@\(offset)", level: .warning)
        return req.reply(.failure(.cancelled))
      }
      session = currentSession
    } else {
      // FIXME: even if trigger kind is not from incomplete, we could to detect a compatible
      // location if we also check that the rest of the snapshot has not changed.
      session = CodeCompletionSession(
        server: self,
        snapshot: snapshot,
        utf8Offset: offset,
        position: completionPos,
        compileCommand: commandsByFile[snapshot.document.uri])

      currentCompletionSession?.close()
      currentCompletionSession = session
    }

    session.update(filterText: filterText, position: req.params.position, in: snapshot, options: options, completion: req.reply)
  }

  /// Must be called on `queue`.
  func _completionWithClientFiltering(offset: Int, completionPos: Position, snapshot: DocumentSnapshot, request req: Request<CompletionRequest>, options: SKCompletionOptions) {
    let skreq = SKDRequestDictionary(sourcekitd: sourcekitd)
    skreq[keys.request] = requests.codecomplete
    skreq[keys.offset] = offset
    skreq[keys.sourcefile] = snapshot.document.uri.pseudoPath
    skreq[keys.sourcetext] = snapshot.text

    let skreqOptions = SKDRequestDictionary(sourcekitd: sourcekitd)
    skreqOptions[keys.codecomplete_sort_byname] = 1
    skreq[keys.codecomplete_options] = skreqOptions

    // FIXME: SourceKit should probably cache this for us.
    if let compileCommand = commandsByFile[snapshot.document.uri] {
      skreq[keys.compilerargs] = compileCommand.compilerArgs
    }

    let handle = sourcekitd.send(skreq, queue) { [weak self] result in
      guard let self = self else { return }
      guard let dict = result.success else {
        req.reply(.failure(ResponseError(result.failure!)))
        return
      }

      guard let completions: SKDResponseArray = dict[self.keys.results] else {
        req.reply(CompletionList(isIncomplete: false, items: []))
        return
      }

      req.reply(.success(self.completionsFromSKDResponse(completions, in: snapshot, completionPos: completionPos, requestPosition: req.params.position, isIncomplete: false)))
    }

    // FIXME: cancellation
    _ = handle
  }

  func completionsFromSKDResponse(
    _ completions: SKDResponseArray,
    in snapshot: DocumentSnapshot,
    completionPos: Position,
    requestPosition: Position,
    isIncomplete: Bool
  ) -> CompletionList {
    var result = CompletionList(isIncomplete: isIncomplete, items: [])

    completions.forEach { (i, value) -> Bool in
      guard let name: String = value[self.keys.description] else {
        return true // continue
      }

      var filterName: String? = value[self.keys.name]
      let insertText: String? = value[self.keys.sourcetext]
      let typeName: String? = value[self.keys.typename]
      let docBrief: String? = value[self.keys.doc_brief]

      let clientCompletionCapabilities = self.clientCapabilities.textDocument?.completion
      let clientSupportsSnippets = clientCompletionCapabilities?.completionItem?.snippetSupport == true
      let text = insertText.map {
        rewriteSourceKitPlaceholders(inString: $0, clientSupportsSnippets: clientSupportsSnippets)
      }
      let isInsertTextSnippet = clientSupportsSnippets && text != insertText

      let textEdit: TextEdit?
      if let text = text {
        let utf8CodeUnitsToErase: Int = value[self.keys.num_bytes_to_erase] ?? 0

        textEdit = self.computeCompletionTextEdit(completionPos: completionPos, requestPosition: requestPosition, utf8CodeUnitsToErase: utf8CodeUnitsToErase, newText: text, snapshot: snapshot)

        if utf8CodeUnitsToErase != 0, filterName != nil, let textEdit = textEdit {
          // To support the case where the client is doing prefix matching on the TextEdit range,
          // we need to prepend the deleted text to filterText.
          // This also works around a behaviour in VS Code that causes completions to not show up
          // if a '.' is being replaced for Optional completion.
          let startIndex = snapshot.lineTable.stringIndexOf(line: textEdit.range.lowerBound.line, utf16Column: textEdit.range.lowerBound.utf16index)!
          let endIndex = snapshot.lineTable.stringIndexOf(line: completionPos.line, utf16Column: completionPos.utf16index)!
          let filterPrefix = snapshot.text[startIndex..<endIndex]
          filterName = filterPrefix + filterName!
        }
      } else {
        textEdit = nil
      }

      // Map SourceKit's not_recommended field to LSP's deprecated
      let notRecommended = (value[self.keys.not_recommended] as Int?).map({ $0 != 0 })

      let kind = (value[self.keys.kind] as sourcekitd_uid_t?)?.asCompletionItemKind(self.values) ?? .value
      var data: [String: LSPAny] = ["textDocURI": .string(snapshot.document.uri.stringValue)]

      if let usr: String = value[self.keys.associated_usrs] { data["usr"] = .string(usr) }
      
      result.items.append(CompletionItem(
        label: name,
        kind: kind,
        detail: typeName,
        documentation: docBrief != nil ? .markupContent(MarkupContent(kind: .markdown, value: docBrief!)) : nil,
        sortText: nil,
        filterText: filterName,
        textEdit: textEdit,
        insertText: text,
        insertTextFormat: isInsertTextSnippet ? .snippet : .plain,
        deprecated: notRecommended ?? false,
        data: .dictionary(data)
      ))

      return true
    }

    return result
  }

  /// Adjust completion position to the start of identifier characters.
  func adjustCompletionLocation(_ pos: Position, in snapshot: DocumentSnapshot) -> Position? {
    guard pos.line < snapshot.lineTable.count else {
      // Line out of range.
      return nil
    }
    let lineSlice = snapshot.lineTable[pos.line]
    let startIndex = lineSlice.startIndex

    let identifierChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))

    guard var loc = lineSlice.utf16.index(startIndex, offsetBy: pos.utf16index, limitedBy: lineSlice.endIndex) else {
      // Column out of range.
      return nil
    }
    while loc != startIndex {
      let prev = lineSlice.index(before: loc)
      if !identifierChars.contains(lineSlice.unicodeScalars[prev]) {
        break
      }
      loc = prev
    }

    // ###aabccccccdddddd
    // ^  ^- loc  ^-requestedLoc
    // `- startIndex

    let adjustedOffset = lineSlice.utf16.distance(from: startIndex, to: loc)
    return Position(line: pos.line, utf16index: adjustedOffset)
  }

  private func computeCompletionTextEdit(completionPos: Position, requestPosition: Position, utf8CodeUnitsToErase: Int, newText: String, snapshot: DocumentSnapshot) -> TextEdit {
    let textEditRangeStart: Position

    // Compute the TextEdit
    if utf8CodeUnitsToErase == 0 {
      // Nothing to delete. Fast path and avoid UTF-8/UTF-16 conversions
      textEditRangeStart = completionPos
    } else if utf8CodeUnitsToErase == 1 {
      // Fast path: Erasing a single UTF-8 byte code unit means we are also need to erase exactly one UTF-16 code unit, meaning we don't need to process the file contents
      if completionPos.utf16index >= 1 {
        // We can delete the character.
        textEditRangeStart = Position(line: completionPos.line, utf16index: completionPos.utf16index - 1)
      } else {
        // Deleting the character would cross line boundaries. This is not supported by LSP.
        // Fall back to ignoring utf8CodeUnitsToErase.
        // If we discover that multi-lines replacements are often needed, we can add an LSP extension to support multi-line edits.
        textEditRangeStart = completionPos
      }
    } else {
      // We need to delete more than one text character. Do the UTF-8/UTF-16 dance.
      assert(completionPos.line == requestPosition.line)
      // Construct a string index for the edit range start by subtracting the UTF-8 code units to erase from the completion position.
      let line = snapshot.lineTable[completionPos.line]
      let completionPosStringIndex = snapshot.lineTable.stringIndexOf(line: completionPos.line, utf16Column: completionPos.utf16index)!
      let deletionStartStringIndex = line.utf8.index(completionPosStringIndex, offsetBy: -utf8CodeUnitsToErase)

      // Compute the UTF-16 offset of the deletion start range. If the start lies in a previous line, this will be negative
      let deletionStartUtf16Offset = line.utf16.distance(from: line.startIndex, to: deletionStartStringIndex)

      // Check if we are only deleting on one line. LSP does not support deleting over multiple lines.
      if deletionStartUtf16Offset >= 0 {
        // We are only deleting characters on the same line. Construct the corresponding text edit.
        textEditRangeStart = Position(line: completionPos.line, utf16index: deletionStartUtf16Offset)
      } else {
        // Deleting the character would cross line boundaries. This is not supported by LSP.
        // Fall back to ignoring utf8CodeUnitsToErase.
        // If we discover that multi-lines replacements are often needed, we can add an LSP extension to support multi-line edits.
        textEditRangeStart = completionPos
      }
    }

    return TextEdit(range: textEditRangeStart..<requestPosition, newText: newText)
  }
  
    /// Must be called on `queue`.
  func _completionResolve(_ req: Request<CompletionItem>) {
    dispatchPrecondition(condition: .onQueue(queue))
    
    if 
      let data = req.params.data,
      case let .dictionary(dict) = data,
      case let .string(usr) = dict["usr"],
      case let .string(textDocURI) = dict["textDocURI"]
    {
      let uri = DocumentURI(string: textDocURI)
      let skreq = SKDRequestDictionary(sourcekitd: sourcekitd)
      
      skreq[keys.request] = requests.cursorinfo
      skreq[keys.usr] = usr
      skreq[keys.sourcefile] = uri.pseudoPath

      // FIXME: SourceKit should probably cache this for us.
      if let compileCommand = commandsByFile[uri] {
        skreq[keys.compilerargs] = compileCommand.compilerArgs
      }
      
      let handle = sourcekitd.send(skreq, queue) { [weak self] result in
        guard let dict = result.success else { 
          req.reply(.failure(ResponseError(result.failure!)))
          return
        }
        
        if let documentationXML: String = dict[self?.keys.doc_full_as_xml] {
          
          do {
            let documentationMarkdown = try xmlDocumentationToMarkdown(documentationXML)
            var completionItem = req.params
            
            completionItem.documentation = .markupContent(MarkupContent(kind: .markdown, value: documentationMarkdown))
            req.reply(completionItem)
          } catch {
            log("Completion Resolve: Unable to convert XML documentation to Markdown", level: .debug)
            req.reply(req.params)
          }
          
        } else {
          log("Completion Resolve: No doc_full_as_xml in SourceKit response", level: .debug)
          req.reply(req.params)
        }
      }
      
      // FIXME: cancellation
       _ = handle
    } else {
      req.reply(req.params)
    }
  }
}
