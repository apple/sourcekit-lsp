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
  /// Converts a flat list of test symbol occurrences to hierarchical `TestItem` array, inferring the hierarchical
  /// structure from `childOf` relations between the symbol occurrences.
  ///
  /// If `testLocations` is passed, it's an array of test IDs to the locations of the test cases. This allows us to
  /// provide ranges for the test cases in source code instead of only the test's location that we get from the index.
  private func testItems(
    for testSymbolOccurrences: [SymbolOccurrence],
    testLocations: [String: Location]
  ) -> [TestItem] {
    // Arrange tests by the USR they are contained in. This allows us to emit test methods as children of test classes.
    // `occurrencesByParent[nil]` are the root test symbols that aren't a child of another test symbol.
    var occurrencesByParent: [String?: [SymbolOccurrence]] = [:]

    let testSymbolUsrs = Set(testSymbolOccurrences.map(\.symbol.usr))

    for testSymbolOccurrence in testSymbolOccurrences {
      let childOfUsrs = testSymbolOccurrence.relations
        .filter { $0.roles.contains(.childOf) }
        .map(\.symbol.usr)
        .filter { testSymbolUsrs.contains($0) }
      if childOfUsrs.count > 1 {
        logger.fault(
          "Test symbol \(testSymbolOccurrence.symbol.usr) is child or multiple symbols: \(childOfUsrs.joined(separator: ", "))"
        )
      }
      occurrencesByParent[childOfUsrs.sorted().first, default: []].append(testSymbolOccurrence)
    }

    /// Returns a test item for the given `testSymbolOccurrence`.
    ///
    /// Also includes test items for all tests that are children of this test.
    ///
    /// `context` is used to build the test's ID. It is an array containing the names of all parent symbols. These will
    /// be joined with the test symbol's name using `/` to form the test ID. The test ID can be used to run an
    /// individual test.
    func testItem(for testSymbolOccurrence: SymbolOccurrence, context: [String]) -> TestItem {
      let symbolPosition = Position(
        line: testSymbolOccurrence.location.line - 1,  // 1-based -> 0-based
        // FIXME: we need to convert the utf8/utf16 column, which may require reading the file!
        utf16index: testSymbolOccurrence.location.utf8Column - 1
      )

      let id = (context + [testSymbolOccurrence.symbol.name]).joined(separator: "/")
      let location: Location
      if let syntacticLocation = testLocations[id] {
        location = syntacticLocation
      } else {
        location = Location(
          uri: DocumentURI(URL(fileURLWithPath: testSymbolOccurrence.location.path)),
          range: Range(symbolPosition)
        )
      }
      let children =
        occurrencesByParent[testSymbolOccurrence.symbol.usr, default: []]
        .sorted()
        .map { testItem(for: $0, context: context + [testSymbolOccurrence.symbol.name]) }
      return TestItem(
        id: id,
        label: testSymbolOccurrence.symbol.name,
        location: location,
        children: children,
        tags: []
      )
    }

    return occurrencesByParent[nil, default: []]
      .sorted()
      .map { testItem(for: $0, context: []) }
  }

  func workspaceTests(_ req: WorkspaceTestsRequest) async throws -> [TestItem] {
    // Gather all tests classes and test methods.
    let testSymbolOccurrences = workspaces.flatMap { (workspace) -> [SymbolOccurrence] in
      return workspace.index?.unitTests() ?? []
    }
    return testItems(for: testSymbolOccurrences, testLocations: [:])
  }

  /// Extracts a flat dictionary mapping test IDs to their locations from the given `testItems`.
  private func testLocations(from testItems: [TestItem]) -> [String: Location] {
    var result: [String: Location] = [:]
    for testItem in testItems {
      result[testItem.id] = testItem.location
      result.merge(testLocations(from: testItem.children)) { old, new in new }
    }
    return result
  }

  func documentTests(
    _ req: DocumentTestsRequest,
    workspace: Workspace,
    languageService: LanguageService
  ) async throws -> [TestItem] {
    let snapshot = try self.documentManager.latestSnapshot(req.textDocument.uri)
    let mainFileUri = await workspace.buildSystemManager.mainFile(
      for: req.textDocument.uri,
      language: snapshot.language
    )

    let syntacticTests = try await languageService.syntacticDocumentTests(for: req.textDocument.uri)
    let testLocations = testLocations(from: syntacticTests)

    if let index = workspace.index {
      var outOfDateChecker = IndexOutOfDateChecker()
      let testSymbols =
        index.unitTests(referencedByMainFiles: [mainFileUri.pseudoPath])
        .filter { $0.canBeTestDefinition && outOfDateChecker.isUpToDate($0.location) }

      if !testSymbols.isEmpty {
        return testItems(for: testSymbols, testLocations: testLocations)
      }
      if outOfDateChecker.indexHasUpToDateUnit(for: mainFileUri.pseudoPath, index: index) {
        // The index is up-to-date and doesn't contain any tests. We don't need to do a syntactic fallback.
        return []
      }
    }
    // We don't have any up-to-date index entries for this file. Syntactically look for tests.
    return syntacticTests
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
  private var result: [TestItem] = []

  /// Names of classes that are known to not inherit from `XCTestCase` and can thus be ruled out to be test classes.
  private static let knownNonXCTestSubclasses = ["NSObject"]

  private init(snapshot: DocumentSnapshot) {
    self.snapshot = snapshot
    super.init(viewMode: .fixedUp)
  }

  public static func findTestSymbols(
    in snapshot: DocumentSnapshot,
    syntaxTreeManager: SyntaxTreeManager
  ) async -> [TestItem] {
    let syntaxTree = await syntaxTreeManager.syntaxTree(for: snapshot)
    let visitor = SyntacticSwiftXCTestScanner(snapshot: snapshot)
    visitor.walk(syntaxTree)
    return visitor.result
  }

  private func findTestMethods(in members: MemberBlockItemListSyntax, containerName: String) -> [TestItem] {
    return members.compactMap { (member) -> TestItem? in
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
      guard function.signature.returnClause == nil, function.signature.parameterClause.parameters.isEmpty else {
        // Test methods can't have a return type or have parameters.
        // Technically we are also filtering out functions that have an explicit `Void` return type here but such
        // declarations are probably less common than helper functions that start with `test` and have a return type.
        return nil
      }
      guard
        let range = snapshot.range(
          of: function.positionAfterSkippingLeadingTrivia..<function.endPositionBeforeTrailingTrivia
        )
      else {
        logger.fault(
          "Failed to convert range \(function.positionAfterSkippingLeadingTrivia.utf8Offset)..<\(function.endPositionBeforeTrailingTrivia.utf8Offset) to UTF-16-based line-column range"
        )
        return nil
      }
      return TestItem(
        id: "\(containerName)/\(function.name.text)()",
        label: "\(function.name.text)()",
        location: Location(uri: snapshot.uri, range: range),
        children: [],
        tags: []
      )
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
    guard let range = snapshot.range(of: node.positionAfterSkippingLeadingTrivia..<node.endPositionBeforeTrailingTrivia)
    else {
      logger.fault(
        "Failed to convert range \(node.positionAfterSkippingLeadingTrivia.utf8Offset)..<\(node.endPositionBeforeTrailingTrivia.utf8Offset) to UTF-16-based line-column range"
      )
      return .visitChildren
    }
    let testItem = TestItem(
      id: node.name.text,
      label: node.name.text,
      location: Location(uri: snapshot.uri, range: range),
      children: testMethods,
      tags: []
    )
    result.append(testItem)
    return .visitChildren
  }

  override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
    result += findTestMethods(in: node.memberBlock.members, containerName: node.extendedType.trimmedDescription)
    return .visitChildren
  }
}

extension SwiftLanguageService {
  public func syntacticDocumentTests(for uri: DocumentURI) async throws -> [TestItem] {
    let snapshot = try documentManager.latestSnapshot(uri)
    return await SyntacticSwiftXCTestScanner.findTestSymbols(in: snapshot, syntaxTreeManager: syntaxTreeManager)
  }
}

extension ClangLanguageService {
  public func syntacticDocumentTests(for uri: DocumentURI) async -> [TestItem] {
    return []
  }
}
