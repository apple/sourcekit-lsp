//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import LSPLogging
import LanguageServerProtocol
import SourceKitD
import SwiftIDEUtils
import SwiftParser
import SwiftSyntax

extension SwiftLanguageService {
  /// Requests the semantic highlighting tokens for the given snapshot from sourcekitd.
  private func semanticHighlightingTokens(for snapshot: DocumentSnapshot) async throws -> SyntaxHighlightingTokens? {
    guard let buildSettings = await self.buildSettings(for: snapshot.uri), !buildSettings.isFallback else {
      return nil
    }

    let skreq = sourcekitd.dictionary([
      keys.request: requests.semanticTokens,
      keys.sourceFile: snapshot.uri.pseudoPath,
      keys.compilerArgs: buildSettings.compilerArgs as [SKDRequestValue],
    ])

    let dict = try await sendSourcekitdRequest(skreq, fileContents: snapshot.text)

    guard let skTokens: SKDResponseArray = dict[keys.semanticTokens] else {
      return nil
    }

    return SyntaxHighlightingTokenParser(sourcekitd: sourcekitd).parseTokens(skTokens, in: snapshot)
  }

  /// Computes an array of syntax highlighting tokens from the syntax tree that
  /// have been merged with any semantic tokens from SourceKit. If the provided
  /// range is non-empty, this function restricts its output to only those
  /// tokens whose ranges overlap it. If no range is provided, tokens for the
  /// entire document are returned.
  ///
  /// - Parameter range: The range of tokens to restrict this function to, if any.
  /// - Returns: An array of syntax highlighting tokens.
  private func mergedAndSortedTokens(
    for snapshot: DocumentSnapshot,
    in range: Range<Position>? = nil
  ) async throws -> SyntaxHighlightingTokens {
    async let tree = syntaxTreeManager.syntaxTree(for: snapshot)
    let semanticTokens = await orLog("Loading semantic tokens") { try await semanticHighlightingTokens(for: snapshot) }

    let range =
      if let range = range.flatMap({ snapshot.byteSourceRange(of: $0) }) {
        range
      } else {
        await tree.range
      }

    let tokens =
      await tree
      .classifications(in: range)
      .map { $0.highlightingTokens(in: snapshot) }
      .reduce(into: SyntaxHighlightingTokens(tokens: [])) { $0.tokens += $1.tokens }

    return
      tokens
      .mergingTokens(with: semanticTokens ?? SyntaxHighlightingTokens(tokens: []))
      .sorted { $0.start < $1.start }
  }

  public func documentSemanticTokens(
    _ req: DocumentSemanticTokensRequest
  ) async throws -> DocumentSemanticTokensResponse? {
    let snapshot = try self.documentManager.latestSnapshot(req.textDocument.uri)

    let tokens = try await mergedAndSortedTokens(for: snapshot)
    let encodedTokens = tokens.lspEncoded

    return DocumentSemanticTokensResponse(data: encodedTokens)
  }

  public func documentSemanticTokensDelta(
    _ req: DocumentSemanticTokensDeltaRequest
  ) async throws -> DocumentSemanticTokensDeltaResponse? {
    return nil
  }

  public func documentSemanticTokensRange(
    _ req: DocumentSemanticTokensRangeRequest
  ) async throws -> DocumentSemanticTokensResponse? {
    let snapshot = try self.documentManager.latestSnapshot(req.textDocument.uri)
    let tokens = try await mergedAndSortedTokens(for: snapshot, in: req.range)
    let encodedTokens = tokens.lspEncoded

    return DocumentSemanticTokensResponse(data: encodedTokens)
  }
}

extension SyntaxClassifiedRange {
  fileprivate func highlightingTokens(in snapshot: DocumentSnapshot) -> SyntaxHighlightingTokens {
    guard let (kind, modifiers) = self.kind.highlightingKindAndModifiers else {
      return SyntaxHighlightingTokens(tokens: [])
    }

    let multiLineRange = snapshot.absolutePositionRange(of: self.range)
    let ranges = multiLineRange.splitToSingleLineRanges(in: snapshot)

    let tokens = ranges.map {
      SyntaxHighlightingToken(
        range: $0,
        kind: kind,
        modifiers: modifiers
      )
    }

    return SyntaxHighlightingTokens(tokens: tokens)
  }
}

extension SyntaxClassification {
  fileprivate var highlightingKindAndModifiers: (SemanticTokenTypes, SemanticTokenModifiers)? {
    switch self {
    case .none:
      return nil
    case .editorPlaceholder:
      return nil
    case .keyword:
      return (.keyword, [])
    case .identifier, .type, .dollarIdentifier:
      return (.identifier, [])
    case .operator:
      return (.operator, [])
    case .integerLiteral, .floatLiteral:
      return (.number, [])
    case .stringLiteral:
      return (.string, [])
    case .regexLiteral:
      return (.regexp, [])
    case .ifConfigDirective:
      return (.macro, [])
    case .attribute:
      return (.modifier, [])
    case .lineComment, .blockComment:
      return (.comment, [])
    case .docLineComment, .docBlockComment:
      return (.comment, .documentation)
    case .argumentLabel:
      return (.function, [])
    }
  }
}
