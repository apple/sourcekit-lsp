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

import IndexStoreDB
import LSPLogging
import LanguageServerProtocol
import SwiftSyntax

fileprivate extension SymbolOccurrence {
  /// Assuming that this is a symbol occurrence returned by the index, return whether it can constitute the definition
  /// of a test case.
  ///
  /// The primary intention for this is to filter out references to test cases and extension declarations of test cases.
  /// The latter is important to filter so we don't include extension declarations for the derived `DiscoveredTests`
  /// files on non-Darwin platforms.
  var canBeTestDefinition: Bool {
    guard roles.contains(.definition) else {
      return false
    }
    guard symbol.kind == .class || symbol.kind == .instanceMethod else {
      return false
    }
    return true
  }
}

extension SourceKitLSPServer {
  func workspaceTests(_ req: WorkspaceTestsRequest) async throws -> [WorkspaceSymbolItem]? {
    let testSymbols = workspaces.flatMap { (workspace) -> [SymbolOccurrence] in
      return workspace.index?.unitTests() ?? []
    }
    return
      testSymbols
      .filter { $0.canBeTestDefinition }
      .sorted()
      .map(WorkspaceSymbolItem.init)
  }

  func documentTests(
    _ req: DocumentTestsRequest,
    workspace: Workspace,
    languageService: LanguageService
  ) async throws -> [WorkspaceSymbolItem]? {
    let snapshot = try self.documentManager.latestSnapshot(req.textDocument.uri)
    let mainFileUri = await workspace.buildSystemManager.mainFile(
      for: req.textDocument.uri,
      language: snapshot.language
    )
    if let index = workspace.index {
      var outOfDateChecker = IndexOutOfDateChecker()
      let testSymbols =
        index.unitTests(referencedByMainFiles: [mainFileUri.pseudoPath])
        .filter { $0.canBeTestDefinition && outOfDateChecker.isUpToDate($0.location) }

      if !testSymbols.isEmpty {
        return testSymbols.sorted().map(WorkspaceSymbolItem.init)
      }
      if outOfDateChecker.indexHasUpToDateUnit(for: mainFileUri.pseudoPath, index: index) {
        // The index is up-to-date and doesn't contain any tests. We don't need to do a syntactic fallback.
        return []
      }
    }
    // We don't have any up-to-date index entries for this file. Syntactically look for tests.
    return try await languageService.syntacticDocumentTests(for: req.textDocument.uri)
  }
}

/// Scans a source file for `XCTestCase` classes and test methods.
///
/// The syntax visitor scans from class and extension declarations that could be `XCTestCase` classes or extensions
/// thereof. It then calls into `findTestMethods` to find the actual test methods.
private final class SyntacticSwiftXCTestScanner: SyntaxVisitor {
  /// The document snapshot of the syntax tree that is being walked.
  private var snapshot: DocumentSnapshot

  /// The workspace symbols representing the found `XCTestCase` subclasses and test methods.
  private var result: [WorkspaceSymbolItem] = []

  /// Names of classes that are known to not inherit from `XCTestCase` and can thus be ruled out to be test classes.
  private static let knownNonXCTestSubclasses = ["NSObject"]

  private init(snapshot: DocumentSnapshot) {
    self.snapshot = snapshot
    super.init(viewMode: .fixedUp)
  }

  public static func findTestSymbols(
    in snapshot: DocumentSnapshot,
    syntaxTreeManager: SyntaxTreeManager
  ) async -> [WorkspaceSymbolItem] {
    let syntaxTree = await syntaxTreeManager.syntaxTree(for: snapshot)
    let visitor = SyntacticSwiftXCTestScanner(snapshot: snapshot)
    visitor.walk(syntaxTree)
    return visitor.result
  }

  private func findTestMethods(in members: MemberBlockItemListSyntax, containerName: String) -> [WorkspaceSymbolItem] {
    return members.compactMap { (member) -> WorkspaceSymbolItem? in
      guard let function = member.decl.as(FunctionDeclSyntax.self) else {
        return nil
      }
      guard function.name.text.starts(with: "test") else {
        return nil
      }
      guard function.modifiers.map(\.name.tokenKind).allSatisfy({ $0 != .keyword(.static) && $0 != .keyword(.class) })
      else {
        // Test methods can't be static.
        return nil
      }
      guard function.signature.returnClause == nil else {
        // Test methods can't have a return type.
        // Technically we are also filtering out functions that have an explicit `Void` return type here but such
        // declarations are probably less common than helper functions that start with `test` and have a return type.
        return nil
      }
      guard let position = snapshot.position(of: function.name.positionAfterSkippingLeadingTrivia) else {
        logger.fault(
          "Failed to convert offset \(function.name.positionAfterSkippingLeadingTrivia.utf8Offset) to UTF-16-based position"
        )
        return nil
      }
      let symbolInformation = SymbolInformation(
        name: function.name.text,
        kind: .method,
        location: Location(uri: snapshot.uri, range: Range(position)),
        containerName: containerName
      )
      return WorkspaceSymbolItem.symbolInformation(symbolInformation)
    }
  }

  override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
    guard let inheritedTypes = node.inheritanceClause?.inheritedTypes, let superclass = inheritedTypes.first else {
      // The class has no superclass and thus can't inherit from XCTestCase.
      // Continue scanning its children in case it has a nested subclass that inherits from XCTestCase.
      return .visitChildren
    }
    if let superclassIdentifier = superclass.type.as(IdentifierTypeSyntax.self),
      Self.knownNonXCTestSubclasses.contains(superclassIdentifier.name.text)
    {
      // We know that the class can't be an subclass of `XCTestCase` so don't visit it.
      // We can't explicitly check for the `XCTestCase` superclass because the class might inherit from a class that in
      // turn inherits from `XCTestCase`. Resolving that inheritance hierarchy would be semantic.
      return .visitChildren
    }
    let testMethods = findTestMethods(in: node.memberBlock.members, containerName: node.name.text)
    guard !testMethods.isEmpty else {
      // Don't report a test class if it doesn't contain any test methods.
      return .visitChildren
    }
    guard let position = snapshot.position(of: node.name.positionAfterSkippingLeadingTrivia) else {
      logger.fault(
        "Failed to convert offset \(node.name.positionAfterSkippingLeadingTrivia.utf8Offset) to UTF-16-based position"
      )
      return .visitChildren
    }
    let testClassSymbolInformation = SymbolInformation(
      name: node.name.text,
      kind: .class,
      location: Location(uri: snapshot.uri, range: Range(position)),
      containerName: nil
    )
    result.append(.symbolInformation(testClassSymbolInformation))
    result += testMethods
    return .visitChildren
  }

  override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
    result += findTestMethods(in: node.memberBlock.members, containerName: node.extendedType.trimmedDescription)
    return .visitChildren
  }
}

extension SwiftLanguageService {
  public func syntacticDocumentTests(for uri: DocumentURI) async throws -> [WorkspaceSymbolItem]? {
    let snapshot = try documentManager.latestSnapshot(uri)
    return await SyntacticSwiftXCTestScanner.findTestSymbols(in: snapshot, syntaxTreeManager: syntaxTreeManager)
  }
}

extension ClangLanguageService {
  public func syntacticDocumentTests(for uri: DocumentURI) async -> [WorkspaceSymbolItem]? {
    return nil
  }
}
