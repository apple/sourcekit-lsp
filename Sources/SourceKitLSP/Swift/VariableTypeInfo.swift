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

import Dispatch
import LanguageServerProtocol
import SourceKitD
import SwiftSyntax

fileprivate extension TokenSyntax {
  /// Returns `false` if it is known that this token can’t be followed by a type
  /// annotation.
  var canBeFollowedByTypeAnnotation: Bool {
    var node = Syntax(self)
    LOOP: while let parent = node.parent {
      switch parent.kind {
      case .switchCaseItem, .closureShorthandParameter:
        // case items (inside a switch) and closure parameters can’t have type
        // annotations.
        return false
      case .codeBlockItem, .memberBlockItem:
        // Performance optimization. If we walked the parents up to code block item,
        // we can’t enter a case item or closure param anymore. No need walking
        // the tree any further.
        break LOOP
      default:
        break
      }
      node = parent
    }

    // By default, assume that the token can be followed by a type annotation as
    // most locations that produce a variable type info can.
    return true
  }
}

/// A typed variable as returned by sourcekitd's CollectVariableType.
struct VariableTypeInfo {
  /// Range of the variable identifier in the source file.
  var range: Range<Position>
  /// The printed type of the variable.
  var printedType: String
  /// Whether the variable has an explicit type annotation in the source file.
  var hasExplicitType: Bool
  /// Whether we should suggest making an edit to add the type annotation to the
  /// source file.
  var canBeFollowedByTypeAnnotation: Bool

  init?(_ dict: SKDResponseDictionary, in snapshot: DocumentSnapshot, syntaxTree: SourceFileSyntax) {
    let keys = dict.sourcekitd.keys

    guard let offset: Int = dict[keys.variableOffset],
      let length: Int = dict[keys.variableLength],
      let printedType: String = dict[keys.variableType],
      let hasExplicitType: Bool = dict[keys.variableTypeExplicit]
    else {
      return nil
    }
    let tokenAtOffset = syntaxTree.token(at: AbsolutePosition(utf8Offset: offset))

    self.range = snapshot.positionOf(utf8Offset: offset)..<snapshot.positionOf(utf8Offset: offset + length)
    self.printedType = printedType
    self.hasExplicitType = hasExplicitType
    self.canBeFollowedByTypeAnnotation = tokenAtOffset?.canBeFollowedByTypeAnnotation ?? true
  }
}

extension SwiftLanguageService {
  /// Provides typed variable declarations in a document.
  ///
  /// - Parameters:
  ///   - url: Document URL in which to perform the request. Must be an open document.
  func variableTypeInfos(
    _ uri: DocumentURI,
    _ range: Range<Position>? = nil
  ) async throws -> [VariableTypeInfo] {
    let snapshot = try documentManager.latestSnapshot(uri)

    let skreq = sourcekitd.dictionary([
      keys.request: requests.collectVariableType,
      keys.sourceFile: snapshot.uri.pseudoPath,
      keys.compilerArgs: await self.buildSettings(for: uri)?.compilerArgs as [SKDRequestValue]?,
    ])

    if let range = range {
      let start = snapshot.utf8Offset(of: range.lowerBound)
      let end = snapshot.utf8Offset(of: range.upperBound)
      skreq.set(keys.offset, to: start)
      skreq.set(keys.length, to: end - start)
    }

    let dict = try await sendSourcekitdRequest(skreq, fileContents: snapshot.text)
    guard let skVariableTypeInfos: SKDResponseArray = dict[keys.variableTypeList] else {
      return []
    }

    var variableTypeInfos: [VariableTypeInfo] = []
    variableTypeInfos.reserveCapacity(skVariableTypeInfos.count)

    let syntaxTree = await syntaxTreeManager.syntaxTree(for: snapshot)
    skVariableTypeInfos.forEach { (_, skVariableTypeInfo) -> Bool in
      guard let info = VariableTypeInfo(skVariableTypeInfo, in: snapshot, syntaxTree: syntaxTree) else {
        assertionFailure("VariableTypeInfo failed to deserialize")
        return true
      }
      variableTypeInfos.append(info)
      return true
    }

    return variableTypeInfos
  }
}
