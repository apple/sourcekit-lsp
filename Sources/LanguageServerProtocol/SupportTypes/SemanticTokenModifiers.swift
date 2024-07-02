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

import Foundation

/// Additional metadata about a token.
///
/// Similar to `SemanticTokenTypes`, the bit indices should
/// be numbered starting at 0.
public struct SemanticTokenModifiers: OptionSet, Hashable, Sendable {
  public let rawValue: UInt32

  public init(rawValue: UInt32) {
    self.rawValue = rawValue
  }

  public static let declaration = Self(rawValue: 1 << 0)
  public static let definition = Self(rawValue: 1 << 1)
  public static let readonly = Self(rawValue: 1 << 2)
  public static let `static` = Self(rawValue: 1 << 3)
  public static let deprecated = Self(rawValue: 1 << 4)
  public static let abstract = Self(rawValue: 1 << 5)
  public static let async = Self(rawValue: 1 << 6)
  public static let modification = Self(rawValue: 1 << 7)
  public static let documentation = Self(rawValue: 1 << 8)
  public static let defaultLibrary = Self(rawValue: 1 << 9)

  // The following are LSP extensions from clangd
  public static let deduced = Self(rawValue: 1 << 10)
  public static let virtual = Self(rawValue: 1 << 11)
  public static let dependentName = Self(rawValue: 1 << 12)
  public static let usedAsMutableReference = Self(rawValue: 1 << 13)
  public static let usedAsMutablePointer = Self(rawValue: 1 << 14)
  public static let constructorOrDestructor = Self(rawValue: 1 << 15)
  public static let userDefined = Self(rawValue: 1 << 16)
  public static let functionScope = Self(rawValue: 1 << 17)
  public static let classScope = Self(rawValue: 1 << 18)
  public static let fileScope = Self(rawValue: 1 << 19)
  public static let globalScope = Self(rawValue: 1 << 20)

  /// Argument labels in function definitions and function calls
  ///
  /// **(LSP Extension)**
  public static let argumentLabel = Self(rawValue: 1 << 21)

  public var name: String? {
    switch self {
    case .declaration: return "declaration"
    case .definition: return "definition"
    case .readonly: return "readonly"
    case .static: return "static"
    case .deprecated: return "deprecated"
    case .abstract: return "abstract"
    case .async: return "async"
    case .modification: return "modification"
    case .documentation: return "documentation"
    case .defaultLibrary: return "defaultLibrary"
    case .deduced: return "deduced"
    case .virtual: return "virtual"
    case .dependentName: return "dependentName"
    case .usedAsMutableReference: return "usedAsMutableReference"
    case .usedAsMutablePointer: return "usedAsMutablePointer"
    case .constructorOrDestructor: return "constructorOrDestructor"
    case .userDefined: return "userDefined"
    case .functionScope: return "functionScope"
    case .classScope: return "classScope"
    case .fileScope: return "fileScope"
    case .globalScope: return "globalScope"
    case .argumentLabel: return "argumentLabel"
    default: return nil
    }
  }

  /// All available modifiers, in ascending order of the bit index
  /// they are represented with (starting at the rightmost bit).
  public static let all: [Self] = [
    .declaration,
    .definition,
    .readonly,
    .static,
    .deprecated,
    .abstract,
    .async,
    .modification,
    .documentation,
    .defaultLibrary,
    .deduced,
    .virtual,
    .dependentName,
    .usedAsMutableReference,
    .usedAsMutablePointer,
    .constructorOrDestructor,
    .userDefined,
    .functionScope,
    .classScope,
    .fileScope,
    .globalScope,
    .argumentLabel,
  ]
}
