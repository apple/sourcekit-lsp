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
import SwiftSyntax

// MARK: - Attribute parsing

/// Get the traits applied to a testing attribute.
///
/// - Parameters:
///   - testAttribute: The attribute to inspect.
///
/// - Returns: An array of `ExprSyntax` instances representing the traits
///   applied to `testAttribute`. If the attribute has no traits, the empty
///   array is returned.
private func traits(ofTestAttribute testAttribute: AttributeSyntax) -> [ExprSyntax] {
  guard let argument = testAttribute.arguments, case let .argumentList(argumentList) = argument else {
    return []
  }

  // Skip the display name if present.
  var traitArgumentsRange = argumentList.startIndex..<argumentList.endIndex
  if let firstArgument = argumentList.first,
    firstArgument.label == nil,
    firstArgument.expression.is(StringLiteralExprSyntax.self)
  {
    traitArgumentsRange = argumentList.index(after: argumentList.startIndex)..<argumentList.endIndex
  }

  // Look for any traits in the remaining arguments and slice them off.
  if let labelledArgumentIndex = argumentList[traitArgumentsRange].firstIndex(where: { $0.label != nil }) {
    // There is an argument with a label, so splice there.
    traitArgumentsRange = traitArgumentsRange.lowerBound..<labelledArgumentIndex
  }

  return argumentList[traitArgumentsRange].map(\.expression)
}

/// Contains information about a testing attribute such as `@Test` or `@Suite`.
struct TestingAttributeData {
  /// The display name in the attribute, if any.
  let displayName: String?

  /// The tags applied to the attribute.
  let tags: [String]

  /// Whether or not the attributed test is unconditionally disabled.
  ///
  /// Disabled tests can be presented differently in IDEs to indicate that they will never run, although they will still
  /// be represented in the results.
  let isDisabled: Bool

  /// Whether or not the attributed test is hidden.
  ///
  /// Hidden tests are not reported by SourceKit-LSP and are not run automatically.
  let isHidden: Bool

  /// Extract the testing attribute data from the given attribute, which is assumed to be an `@Test` or `@Suite`
  /// attribute.
  init(attribute: AttributeSyntax) {
    // If the first argument is an unlabelled string literal, it is the
    // display name of the test. Otherwise, the test does not have a display
    // name.
    if case .argumentList(let argumentList) = attribute.arguments,
      let firstArgument = argumentList.first,
      firstArgument.label == nil,
      let stringLiteral = firstArgument.expression.as(StringLiteralExprSyntax.self)
    {
      self.displayName = stringLiteral.representedLiteralValue
    } else {
      self.displayName = nil
    }

    let traitArguments = traits(ofTestAttribute: attribute)

    // Map the arguments to tag's names.
    self.tags = traitArguments.lazy
      .compactMap { $0.as(FunctionCallExprSyntax.self) }
      .filter { functionCall in
        switch functionCall.calledExpression.as(MemberAccessExprSyntax.self)?.fullyQualifiedName {
        case "tags", "Tag.List.tags", "Testing.Tag.List.tags":
          return true
        default:
          return false
        }
      }.flatMap(\.arguments)
      .compactMap {
        if let memberAccess = $0.expression.as(MemberAccessExprSyntax.self) {
          var components = memberAccess.components[...]
          if components.starts(with: ["Testing", "Tag"]) {
            components = components.dropFirst(2)
          } else if components.starts(with: ["Tag"]) {
            components = components.dropFirst(1)
          }
          return components.joined(separator: ".")
        }
        return nil
      }

    self.isDisabled = traitArguments.lazy
      .compactMap { $0.as(FunctionCallExprSyntax.self) }
      .filter { functionCall in
        switch functionCall.calledExpression.as(MemberAccessExprSyntax.self)?.fullyQualifiedName {
        case "disabled", "ConditionTrait.disabled", "Testing.ConditionTrait.disabled":
          return true
        default:
          return false
        }
      }
      .contains { functionCall in
        // Ignore disabled traits which have an `if:` parameter since
        // they're conditional.
        let hasConditionParam = functionCall.arguments.lazy
          .compactMap(\.label?.text)
          .contains("if")
        if hasConditionParam {
          return false
        }

        // Ignore disabled traits which have a trailing closure since
        // they're conditional.
        if functionCall.trailingClosure != nil {
          return false
        }

        return true
      }

    self.isHidden = traitArguments.lazy
      .compactMap { $0.as(MemberAccessExprSyntax.self) }
      .contains { memberAccess in
        switch memberAccess.fullyQualifiedName {
        case "hidden", "HiddenTrait.hidden", "Testing.HiddenTrait.hidden":
          true
        default:
          false
        }
      }
  }
}

// MARK: - Test scanning

final class SyntacticSwiftTestingTestScanner: SyntaxVisitor {
  /// The `DocumentSnapshot` of the syntax tree that is being visited.
  ///
  /// Used to convert `AbsolutePosition` to line-column.
  private let snapshot: DocumentSnapshot

  /// Whether all tests discovered by the scanner should be marked as disabled.
  ///
  /// This is the case when the scanner is looking for tests inside a disabled suite.
  private let allTestsDisabled: Bool

  /// The names of the types that this scanner is scanning members for.
  ///
  /// For example, when scanning for tests inside `Bar` in the following, this is `["Foo", "Bar"]`
  ///
  /// ```swift
  /// struct Foo {
  ///   struct Bar {
  ///     @Test func myTest() {}
  ///   }
  /// }
  /// ```
  private let parentTypeNames: [String]

  /// The discovered test items.
  private var result: [AnnotatedTestItem] = []

  private init(
    snapshot: DocumentSnapshot,
    allTestsDisabled: Bool,
    parentTypeNames: [String]
  ) {
    self.snapshot = snapshot
    self.allTestsDisabled = allTestsDisabled
    self.parentTypeNames = parentTypeNames
    super.init(viewMode: .fixedUp)
  }

  /// Public entry point. Scans the syntax tree of the given snapshot for swift-testing tests.
  public static func findTestSymbols(
    in snapshot: DocumentSnapshot,
    syntaxTreeManager: SyntaxTreeManager
  ) async -> [AnnotatedTestItem] {
    guard snapshot.text.contains("Suite") || snapshot.text.contains("Test") else {
      // If the file contains swift-testing tests, it must contain a `@Suite` or `@Test` attribute.
      // Only check for the attribute name because the attribute may be module qualified and contain an arbitrary amount
      // of whitespace.
      // This is intended to filter out files that obviously do not contain tests.
      return []
    }
    let syntaxTree = await syntaxTreeManager.syntaxTree(for: snapshot)
    let visitor = SyntacticSwiftTestingTestScanner(
      snapshot: snapshot,
      allTestsDisabled: false,
      parentTypeNames: []
    )
    visitor.walk(syntaxTree)
    return visitor.result
  }

  /// Visit a class/struct/... or extension declaration.
  ///
  /// `typeNames` is the name of the class struct or, if this is an extension, an array containing the components of the
  /// extended type. For example, `extension Foo.Bar {}` passes `["Foo", "Bar"]` as `typeNames`.
  /// `typeNames` must not be empty.
  private func visitTypeOrExtensionDecl(
    _ node: DeclGroupSyntax,
    typeNames: [String]
  ) -> SyntaxVisitorContinueKind {
    precondition(!typeNames.isEmpty)
    let superclassName = node.inheritanceClause?.inheritedTypes.first?.type.as(IdentifierTypeSyntax.self)?.name.text
    if superclassName == "XCTestCase" {
      return .skipChildren
    }

    let suiteAttribute = node.attributes
      .compactMap { $0.as(AttributeSyntax.self) }
      .first { $0.isNamed("Suite", inModuleNamed: "Testing") }
    let attributeData = suiteAttribute.map(TestingAttributeData.init(attribute:))

    if attributeData?.isHidden ?? false {
      return .skipChildren
    }

    let memberScanner = SyntacticSwiftTestingTestScanner(
      snapshot: snapshot,
      allTestsDisabled: attributeData?.isDisabled ?? false,
      parentTypeNames: parentTypeNames + typeNames
    )
    memberScanner.walk(node.memberBlock)

    guard !memberScanner.result.isEmpty || suiteAttribute != nil else {
      // Only include this declaration if it has an `@Suite` attribute or contains nested tests.
      return .skipChildren
    }

    let range = snapshot.absolutePositionRange(
      of: node.positionAfterSkippingLeadingTrivia..<node.endPositionBeforeTrailingTrivia
    )

    let location = location(range: range)

    // Members won't be extensions since extensions will only be at the top level.
    let testItem = AnnotatedTestItem(
      testItem: TestItem(
        id: (parentTypeNames + typeNames + [location]).joined(separator: "/"),
        label: attributeData?.displayName ?? typeNames.last!,
        disabled: (attributeData?.isDisabled ?? false) || allTestsDisabled,
        style: TestStyle.swiftTesting,
        location: Location(uri: snapshot.uri, range: range),
        children: memberScanner.result.map(\.testItem),
        tags: attributeData?.tags.map(TestTag.init(id:)) ?? []
      ),
      isExtension: node.is(ExtensionDeclSyntax.self)
    )
    result.append(testItem)
    return .skipChildren
  }

  override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
    guard let identifier = node.name.identifier else {
      return .skipChildren
    }
    return visitTypeOrExtensionDecl(node, typeNames: [identifier.name])
  }

  override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
    guard let identifier = node.name.identifier else {
      return .skipChildren
    }
    return visitTypeOrExtensionDecl(node, typeNames: [identifier.name])
  }

  override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
    guard let identifier = node.name.identifier else {
      return .skipChildren
    }
    return visitTypeOrExtensionDecl(node, typeNames: [identifier.name])
  }

  override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
    guard let newContextComponents = node.extendedType.components else {
      return .skipChildren
    }

    return visitTypeOrExtensionDecl(node, typeNames: newContextComponents)
  }

  override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
    guard let identifier = node.name.identifier else {
      return .skipChildren
    }
    return visitTypeOrExtensionDecl(node, typeNames: [identifier.name])
  }

  override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
    let testAttribute = node.attributes
      .compactMap { $0.as(AttributeSyntax.self) }
      .first { $0.isNamed("Test", inModuleNamed: "Testing") }

    guard let testAttribute, let identifier = node.name.identifier else {
      return .skipChildren
    }
    let attributeData = TestingAttributeData(attribute: testAttribute)
    if attributeData.isHidden {
      return .skipChildren
    }

    let parameters = node.signature.parameterClause.parameters.map {
      "\($0.firstName.identifier?.name ?? $0.firstName.text):"
    }.joined()
    let name = "\(identifier.name)(\(parameters))"

    let range = snapshot.absolutePositionRange(
      of: node.positionAfterSkippingLeadingTrivia..<node.endPositionBeforeTrailingTrivia
    )

    let location = location(range: range)

    let testItem = AnnotatedTestItem(
      testItem: TestItem(
        id: (parentTypeNames + [name] + [location]).joined(separator: "/"),
        label: attributeData.displayName ?? name,
        disabled: attributeData.isDisabled || allTestsDisabled,
        style: TestStyle.swiftTesting,
        location: Location(uri: snapshot.uri, range: range),
        children: [],
        tags: attributeData.tags.map(TestTag.init(id:))
      ),
      isExtension: false
    )
    result.append(testItem)
    return .visitChildren
  }

  private func location(range: Range<Position>) -> String {
    let fileName = snapshot.uri.fileURL?.lastPathComponent
    let locations: [String?] = [
      fileName,
      range.lowerBound.line.description,
      range.lowerBound.utf16index.description,
    ]

    return
      locations
      .compactMap { $0 }
      .joined(separator: ":")
  }
}

// MARK: - SwiftSyntax Utilities

fileprivate extension AttributeSyntax {
  /// Check whether or not this attribute is named with the specified name and
  /// module.
  ///
  /// The attribute's name is accepted either without or with the specified
  /// module name as a prefix to allow for either syntax. The name of this
  /// attribute must not include generic type parameters.
  ///
  /// - Parameters:
  ///   - name: The `"."`-separated type name to compare against.
  ///   - moduleName: The module the specified type is declared in.
  ///
  /// - Returns: Whether or not this type has the given name.
  func isNamed(_ name: String, inModuleNamed moduleName: String) -> Bool {
    if let identifierType = attributeName.as(IdentifierTypeSyntax.self) {
      return identifierType.name.text == name
    } else if let memberType = attributeName.as(MemberTypeSyntax.self),
      let baseIdentifierType = memberType.baseType.as(IdentifierTypeSyntax.self),
      baseIdentifierType.genericArgumentClause == nil
    {
      return memberType.name.text == name && baseIdentifierType.name.text == moduleName
    }

    return false
  }
}

fileprivate extension MemberAccessExprSyntax {
  /// The fully-qualified name of this instance (subject to available
  /// information.)
  ///
  /// The value of this property are all the components of the based name
  /// name joined together with `.`.
  var fullyQualifiedName: String {
    components.joined(separator: ".")
  }

  /// The name components of this instance (subject to available
  /// information.)
  ///
  /// The value of this property is this base name of this instance,
  /// i.e. the string value of `base` preceeded with any preceding base names
  /// and followed by its `name` property.
  ///
  /// For example, if this instance represents
  /// the expression `x.y.z(123)`, the value of this property is
  /// `["x", "y", "z"]`.
  var components: [String] {
    if let declReferenceExpr = base?.as(DeclReferenceExprSyntax.self) {
      return [declReferenceExpr.baseName.text, declName.baseName.text]
    } else if let baseMemberAccessExpr = base?.as(MemberAccessExprSyntax.self) {
      return baseMemberAccessExpr.components + [declName.baseName.text]
    }
    return [declName.baseName.text]
  }
}

fileprivate extension TypeSyntax {
  /// If this type is a simple chain of `MemberTypeSyntax` and `IdentifierTypeSyntax`, return the components that make
  /// up the qualified type.
  ///
  /// ### Examples
  ///  - `Foo.Bar` returns `["Foo", "Bar"]`
  ///  - `Foo` returns `["Foo"]`
  ///  - `[Int]` returns `nil`
  var components: [String]? {
    switch self.as(TypeSyntaxEnum.self) {
    case .identifierType(let identifierType):
      return [identifierType.name.identifier?.name ?? identifierType.name.text]
    case .memberType(let memberType):
      guard let baseComponents = memberType.baseType.components else {
        return nil
      }
      return baseComponents + [memberType.name.identifier?.name ?? memberType.name.text]
    default:
      return nil
    }
  }
}
