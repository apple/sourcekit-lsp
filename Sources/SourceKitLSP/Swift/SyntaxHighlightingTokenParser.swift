//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import LSPLogging
import LanguageServerProtocol
import SourceKitD

/// Parses tokens from sourcekitd response dictionaries.
struct SyntaxHighlightingTokenParser {
  private let sourcekitd: SourceKitD

  init(sourcekitd: SourceKitD) {
    self.sourcekitd = sourcekitd
  }

  private func parseTokens(
    _ response: SKDResponseDictionary,
    in snapshot: DocumentSnapshot,
    into tokens: inout SyntaxHighlightingTokens
  ) {
    let keys = sourcekitd.keys

    if let offset: Int = response[keys.offset],
      var length: Int = response[keys.length],
      let skKind: sourcekitd_api_uid_t = response[keys.kind],
      case (let kind, var modifiers)? = parseKindAndModifiers(skKind)
    {

      // If the name is escaped in backticks, we need to add two characters to the
      // length for the backticks.
      if modifiers.contains(.declaration),
        snapshot.text[snapshot.indexOf(utf8Offset: offset)] == "`"
      {
        length += 2
      }

      if let isSystem: Bool = response[keys.isSystem], isSystem {
        modifiers.insert(.defaultLibrary)
      }

      let multiLineRange = snapshot.positionOf(utf8Offset: offset)..<snapshot.positionOf(utf8Offset: offset + length)
      let ranges = multiLineRange.splitToSingleLineRanges(in: snapshot)

      tokens.tokens += ranges.map {
        SyntaxHighlightingToken(
          range: $0,
          kind: kind,
          modifiers: modifiers
        )
      }
    }

    if let substructure: SKDResponseArray = response[keys.subStructure] {
      parseTokens(substructure, in: snapshot, into: &tokens)
    }
  }

  private func parseTokens(
    _ response: SKDResponseArray,
    in snapshot: DocumentSnapshot,
    into tokens: inout SyntaxHighlightingTokens
  ) {
    response.forEach { (_, value) in
      parseTokens(value, in: snapshot, into: &tokens)
      return true
    }
  }

  func parseTokens(_ response: SKDResponseArray, in snapshot: DocumentSnapshot) -> SyntaxHighlightingTokens {
    var tokens: SyntaxHighlightingTokens = SyntaxHighlightingTokens(tokens: [])
    parseTokens(response, in: snapshot, into: &tokens)
    return tokens
  }

  private func parseKindAndModifiers(
    _ uid: sourcekitd_api_uid_t
  ) -> (SemanticTokenTypes, SemanticTokenModifiers)? {
    let api = sourcekitd.api
    let values = sourcekitd.values
    switch uid {
    case values.completionKindKeyword, values.keyword:
      return (.keyword, [])
    case values.attributeBuiltin:
      return (.modifier, [])
    case values.declModule:
      return (.namespace, [])
    case values.declClass:
      return (.class, [.declaration])
    case values.refClass:
      return (.class, [])
    case values.declActor:
      return (.actor, [.declaration])
    case values.refActor:
      return (.actor, [])
    case values.declStruct:
      return (.struct, [.declaration])
    case values.refStruct:
      return (.struct, [])
    case values.declEnum:
      return (.enum, [.declaration])
    case values.refEnum:
      return (.enum, [])
    case values.declEnumElement:
      return (.enumMember, [.declaration])
    case values.refEnumElement:
      return (.enumMember, [])
    case values.declProtocol:
      return (.interface, [.declaration])
    case values.refProtocol:
      return (.interface, [])
    case values.declAssociatedType,
      values.declTypeAlias,
      values.declGenericTypeParam:
      return (.typeParameter, [.declaration])
    case values.refAssociatedType,
      values.refTypeAlias,
      values.refGenericTypeParam:
      return (.typeParameter, [])
    case values.declFunctionFree:
      return (.function, [.declaration])
    case values.declMethodStatic,
      values.declMethodClass,
      values.declConstructor:
      return (.method, [.declaration, .static])
    case values.declMethodInstance,
      values.declDestructor,
      values.declSubscript:
      return (.method, [.declaration])
    case values.refFunctionFree:
      return (.function, [])
    case values.refMethodStatic,
      values.refMethodClass,
      values.refConstructor:
      return (.method, [.static])
    case values.refMethodInstance,
      values.refDestructor,
      values.refSubscript:
      return (.method, [])
    case values.operator:
      return (.operator, [])
    case values.declFunctionPrefixOperator,
      values.declFunctionPostfixOperator,
      values.declFunctionInfixOperator:
      return (.operator, [.declaration])
    case values.refFunctionPrefixOperator,
      values.refFunctionPostfixOperator,
      values.refFunctionInfixOperator:
      return (.operator, [])
    case values.declVarStatic,
      values.declVarClass,
      values.declVarInstance:
      return (.property, [.declaration])
    case values.declVarParam:
      // SourceKit seems to use these to refer to parameter labels,
      // therefore we don't use .parameter here (which LSP clients like
      // VSCode seem to interpret as variable identifiers, however
      // causing a 'wrong highlighting' e.g. of `x` in `f(x y: Int) {}`)
      return (.function, [.declaration, .argumentLabel])
    case values.refVarStatic,
      values.refVarClass,
      values.refVarInstance:
      return (.property, [])
    case values.declVarLocal,
      values.declVarGlobal:
      return (.variable, [.declaration])
    case values.refVarLocal,
      values.refVarGlobal:
      return (.variable, [])
    case values.comment,
      values.commentMarker,
      values.commentURL:
      return (.comment, [])
    case values.docComment,
      values.docCommentField:
      return (.comment, [.documentation])
    case values.typeIdentifier:
      return (.type, [])
    case values.number:
      return (.number, [])
    case values.string:
      return (.string, [])
    case values.identifier:
      return (.identifier, [])
    default:
      let ignoredKinds: Set<sourcekitd_api_uid_t> = [
        values.stringInterpolation
      ]
      if !ignoredKinds.contains(uid) {
        let name = api.uid_get_string_ptr(uid).map(String.init(cString:))
        logger.error("Unknown token kind: \(name ?? "?", privacy: .public)")
      }
      return nil
    }
  }
}

extension Range<Position> {
  /// Splits a potentially multi-line range to multiple single-line ranges.
  @_spi(Testing) public func splitToSingleLineRanges(in snapshot: DocumentSnapshot) -> [Self] {
    if isEmpty {
      return []
    }

    if lowerBound.line == upperBound.line {
      return [self]
    }

    let text = snapshot.text[snapshot.indexRange(of: self)]
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

    return
      lines
      .enumerated()
      .lazy
      .map { (i, content) in
        let start = Position(
          line: lowerBound.line + i,
          utf16index: i == 0 ? lowerBound.utf16index : 0
        )
        let end = Position(
          line: start.line,
          utf16index: start.utf16index + content.utf16.count
        )
        return start..<end
      }
      .filter { !$0.isEmpty }
  }
}
