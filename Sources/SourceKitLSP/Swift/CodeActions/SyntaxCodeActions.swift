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

import SwiftRefactor

/// List of all of the syntactic code action providers, which can be used
/// to produce code actions using only the swift-syntax tree of a file.
let allSyntaxCodeActions: [SyntaxCodeActionProvider.Type] = [
  AddDocumentation.self,
  AddSeparatorsToIntegerLiteral.self,
  ConvertIntegerLiteral.self,
  ConvertImplicitlyUnwrappedOptionalToOptional.self,
  ConvertJSONToCodableStruct.self,
  FormatRawStringLiteral.self,
  MigrateToNewIfLetSyntax.self,
  OpaqueParameterToGeneric.self,
  PackageManifestEdits.self,
  RemoveSeparatorsFromIntegerLiteral.self,
]
