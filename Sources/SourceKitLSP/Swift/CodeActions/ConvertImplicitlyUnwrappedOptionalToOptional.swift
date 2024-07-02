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

import LanguageServerProtocol
import SwiftRefactor
import SwiftSyntax

/// Convert implicitly unwrapped optionals to  optionals
struct ConvertImplicitlyUnwrappedOptionalToOptional: SyntaxRefactoringProvider {
  public static func refactor(syntax: ImplicitlyUnwrappedOptionalTypeSyntax, in context: Void) -> OptionalTypeSyntax? {
    OptionalTypeSyntax(
      leadingTrivia: syntax.leadingTrivia,
      syntax.unexpectedBeforeWrappedType,
      wrappedType: syntax.wrappedType,
      syntax.unexpectedBetweenWrappedTypeAndExclamationMark,
      questionMark: .postfixQuestionMarkToken(
        leadingTrivia: syntax.exclamationMark.leadingTrivia,
        trailingTrivia: syntax.exclamationMark.trailingTrivia
      )
    )
  }
}

extension ConvertImplicitlyUnwrappedOptionalToOptional: SyntaxRefactoringCodeActionProvider {
  static let title: String = "Convert Implicitly Unwrapped Optional to Optional"

  static func nodeToRefactor(in scope: SyntaxCodeActionScope) -> ImplicitlyUnwrappedOptionalTypeSyntax? {
    guard let token = scope.innermostNodeContainingRange else {
      return nil
    }

    return
      if let iuoType = token.as(ImplicitlyUnwrappedOptionalTypeSyntax.self)
      ?? token.parent?.as(ImplicitlyUnwrappedOptionalTypeSyntax.self)
    {
      iuoType
    } else if token.is(TokenSyntax.self),
      let wrappedType = token.parent?.as(TypeSyntax.self),
      let iuoType = wrappedType.parent?.as(ImplicitlyUnwrappedOptionalTypeSyntax.self),
      iuoType.wrappedType == wrappedType
    {
      iuoType
    } else {
      nil
    }
  }
}
