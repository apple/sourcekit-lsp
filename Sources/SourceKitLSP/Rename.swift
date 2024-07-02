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

@preconcurrency import IndexStoreDB
import LSPLogging
import LanguageServerProtocol
import SKSupport
import SemanticIndex
import SourceKitD
import SwiftSyntax

// MARK: - Helper types

/// A parsed representation of a name that may be disambiguated by its argument labels.
///
/// ### Examples
///  - `foo(a:b:)`
///  - `foo(_:b:)`
///  - `foo` if no argument labels are specified, eg. for a variable.
fileprivate struct CompoundDeclName {
  /// The parameter of a compound decl name, which can either be the parameter's name or `_` to indicate that the
  /// parameter is unnamed.
  enum Parameter: Equatable {
    case named(String)
    case wildcard

    var stringOrWildcard: String {
      switch self {
      case .named(let str): return str
      case .wildcard: return "_"
      }
    }

    var stringOrEmpty: String {
      switch self {
      case .named(let str): return str
      case .wildcard: return ""
      }
    }
  }

  let baseName: String
  let parameters: [Parameter]

  /// Parse a compound decl name into its base names and parameters.
  init(_ compoundDeclName: String) {
    guard let openParen = compoundDeclName.firstIndex(of: "(") else {
      // We don't have a compound name. Everything is the base name
      self.baseName = compoundDeclName
      self.parameters = []
      return
    }
    self.baseName = String(compoundDeclName[..<openParen])
    let closeParen = compoundDeclName.firstIndex(of: ")") ?? compoundDeclName.endIndex
    let parametersText = compoundDeclName[compoundDeclName.index(after: openParen)..<closeParen]
    // Split by `:` to get the parameter names. Drop the last element so that we don't have a trailing empty element
    // after the last `:`.
    let parameterStrings = parametersText.split(separator: ":", omittingEmptySubsequences: false).dropLast()
    parameters = parameterStrings.map {
      switch $0 {
      case "", "_": return .wildcard
      default: return .named(String($0))
      }
    }
  }
}

/// The kind of range that a `SyntacticRenamePiece` can be.
fileprivate enum SyntacticRenamePieceKind {
  /// The base name of a function or the name of a variable, which can be renamed.
  ///
  /// ### Examples
  /// - `foo` in `func foo(a b: Int)`.
  /// - `foo` in `let foo = 1`
  case baseName

  /// The base name of a function-like declaration that cannot be renamed
  ///
  /// ### Examples
  /// - `init` in `init(a: Int)`
  /// - `subscript` in `subscript(a: Int) -> Int`
  case keywordBaseName

  /// The internal parameter name (aka. second name) inside a function declaration
  ///
  /// ### Examples
  /// - ` b` in `func foo(a b: Int)`
  case parameterName

  /// Same as `parameterName` but cannot be removed if it is the same as the parameter's first name. This only happens
  /// for subscripts where parameters are unnamed by default unless they have both a first and second name.
  ///
  /// ### Examples
  /// The second ` a` in `subscript(a a: Int)`
  case noncollapsibleParameterName

  /// The external argument label of a function parameter
  ///
  /// ### Examples
  /// - `a` in `func foo(a b: Int)`
  /// - `a` in `func foo(a: Int)`
  case declArgumentLabel

  /// The argument label inside a call.
  ///
  /// ### Examples
  /// - `a` in `foo(a: 1)`
  case callArgumentLabel

  /// The colon after an argument label inside a call. This is reported so it can be removed if the parameter becomes
  /// unnamed.
  ///
  /// ### Examples
  /// - `: ` in `foo(a: 1)`
  case callArgumentColon

  /// An empty range that point to the position before an unnamed argument. This is used to insert the argument label
  /// if an unnamed parameter becomes named.
  ///
  /// ### Examples
  /// - An empty range before `1` in `foo(1)`, which could expand to `foo(a: 1)`
  case callArgumentCombined

  /// The argument label in a compound decl name.
  ///
  /// ### Examples
  /// - `a` in `foo(a:)`
  case selectorArgumentLabel

  init?(_ uid: sourcekitd_api_uid_t, values: sourcekitd_api_values) {
    switch uid {
    case values.renameRangeBase: self = .baseName
    case values.renameRangeCallArgColon: self = .callArgumentColon
    case values.renameRangeCallArgCombined: self = .callArgumentCombined
    case values.renameRangeCallArgLabel: self = .callArgumentLabel
    case values.renameRangeDeclArgLabel: self = .declArgumentLabel
    case values.renameRangeKeywordBase: self = .keywordBaseName
    case values.renameRangeNoncollapsibleParam: self = .noncollapsibleParameterName
    case values.renameRangeParam: self = .parameterName
    case values.renameRangeSelectorArgLabel: self = .selectorArgumentLabel
    default: return nil
    }
  }
}

/// A single “piece” that is used for renaming a compound function name.
///
/// See `SyntacticRenamePieceKind` for the different rename pieces that exist.
///
/// ### Example
/// `foo(x: 1)` is represented by three pieces
/// - The base name `foo`
/// - The parameter name `x`
/// - The call argument colon `: `.
fileprivate struct SyntacticRenamePiece {
  /// The range that represents this piece of the name
  let range: Range<Position>

  /// The kind of the rename piece.
  let kind: SyntacticRenamePieceKind

  /// If this piece belongs to a parameter, the index of that parameter (zero-based) or `nil` if this is the base name
  /// piece.
  let parameterIndex: Int?

  /// Create a `SyntacticRenamePiece` from a `sourcekitd` response.
  init?(
    _ dict: SKDResponseDictionary,
    in snapshot: DocumentSnapshot,
    keys: sourcekitd_api_keys,
    values: sourcekitd_api_values
  ) {
    guard let line: Int = dict[keys.line],
      let column: Int = dict[keys.column],
      let endLine: Int = dict[keys.endLine],
      let endColumn: Int = dict[keys.endColumn],
      let kind: sourcekitd_api_uid_t = dict[keys.kind]
    else {
      return nil
    }
    let start = snapshot.positionOf(zeroBasedLine: line - 1, utf8Column: column - 1)
    let end = snapshot.positionOf(zeroBasedLine: endLine - 1, utf8Column: endColumn - 1)
    guard let kind = SyntacticRenamePieceKind(kind, values: values) else {
      return nil
    }

    self.range = start..<end
    self.kind = kind
    self.parameterIndex = dict[keys.argIndex] as Int?
  }
}

/// The context in which the location to be renamed occurred.
fileprivate enum SyntacticRenameNameContext {
  /// No syntactic rename ranges for the rename location could be found.
  case unmatched

  /// A name could be found at a requested rename location but the name did not match the specified old name.
  case mismatch

  /// The matched ranges are in active source code (ie. source code that is not an inactive `#if` range).
  case activeCode

  /// The matched ranges are in an inactive `#if` region of the source code.
  case inactiveCode

  /// The matched ranges occur inside a string literal.
  case string

  /// The matched ranges occur inside a `#selector` directive.
  case selector

  /// The matched ranges are within a comment.
  case comment

  init?(_ uid: sourcekitd_api_uid_t, values: sourcekitd_api_values) {
    switch uid {
    case values.editActive: self = .activeCode
    case values.editComment: self = .comment
    case values.editInactive: self = .inactiveCode
    case values.editMismatch: self = .mismatch
    case values.editSelector: self = .selector
    case values.editString: self = .string
    case values.editUnknown: self = .unmatched
    default: return nil
    }
  }
}

/// A set of ranges that, combined, represent which edits need to be made to rename a possibly compound name.
///
/// See `SyntacticRenamePiece` for more details.
fileprivate struct SyntacticRenameName {
  let pieces: [SyntacticRenamePiece]
  let category: SyntacticRenameNameContext

  init?(
    _ dict: SKDResponseDictionary,
    in snapshot: DocumentSnapshot,
    keys: sourcekitd_api_keys,
    values: sourcekitd_api_values
  ) {
    guard let ranges: SKDResponseArray = dict[keys.ranges] else {
      return nil
    }
    self.pieces = ranges.compactMap { SyntacticRenamePiece($0, in: snapshot, keys: keys, values: values) }
    guard let categoryUid: sourcekitd_api_uid_t = dict[keys.category],
      let category = SyntacticRenameNameContext(categoryUid, values: values)
    else {
      return nil
    }
    self.category = category
  }
}

private extension LineTable {
  /// Returns the string in the source file that's with the given position range.
  ///
  /// If either the lower or upper bound of `range` do not refer to valid positions with in the snapshot, returns
  /// `nil` and logs a fault containing the file and line of the caller (from `callerFile` and `callerLine`).
  subscript(range: Range<Position>, callerFile: StaticString = #fileID, callerLine: UInt = #line) -> Substring {
    let start = self.stringIndexOf(
      line: range.lowerBound.line,
      utf16Column: range.lowerBound.utf16index,
      callerFile: callerFile,
      callerLine: callerLine
    )
    let end = self.stringIndexOf(
      line: range.upperBound.line,
      utf16Column: range.upperBound.utf16index,
      callerFile: callerFile,
      callerLine: callerLine
    )
    return self.content[start..<end]
  }
}

private extension RenameLocation.Usage {
  init(roles: SymbolRole) {
    if roles.contains(.definition) || roles.contains(.declaration) {
      self = .definition
    } else if roles.contains(.call) {
      self = .call
    } else {
      self = .reference
    }
  }
}

private extension IndexSymbolKind {
  var isMethod: Bool {
    switch self {
    case .instanceMethod, .classMethod, .staticMethod:
      return true
    default: return false
    }
  }
}

// MARK: - Name translation

extension SwiftLanguageService {
  enum NameTranslationError: Error, CustomStringConvertible {
    case malformedSwiftToClangTranslateNameResponse(SKDResponseDictionary)
    case malformedClangToSwiftTranslateNameResponse(SKDResponseDictionary)

    var description: String {
      switch self {
      case .malformedSwiftToClangTranslateNameResponse(let response):
        return """
          Malformed response for Swift to Clang name translation

          \(response.description)
          """
      case .malformedClangToSwiftTranslateNameResponse(let response):
        return """
          Malformed response for Clang to Swift name translation

          \(response.description)
          """
      }
    }
  }

  /// Translate a Swift name to the corresponding C/C++/ObjectiveC name.
  ///
  /// This invokes the clang importer to perform the name translation, based on the `position` and `uri` at which the
  /// Swift symbol is defined.
  ///
  /// - Parameters:
  ///   - position: The position at which the Swift name is defined
  ///   - uri: The URI of the document in which the Swift name is defined
  ///   - name: The Swift name of the symbol
  fileprivate func translateSwiftNameToClang(
    at symbolLocation: SymbolLocation,
    in uri: DocumentURI,
    name: CompoundDeclName
  ) async throws -> String {
    guard let snapshot = documentManager.latestSnapshotOrDisk(uri, language: .swift) else {
      throw ResponseError.unknown("Failed to get contents of \(uri.forLogging) to translate Swift name to clang name")
    }

    let req = sourcekitd.dictionary([
      keys.request: sourcekitd.requests.nameTranslation,
      keys.sourceFile: snapshot.uri.pseudoPath,
      keys.compilerArgs: await self.buildSettings(for: snapshot.uri)?.compilerArgs as [SKDRequestValue]?,
      keys.offset: snapshot.utf8Offset(of: snapshot.position(of: symbolLocation)),
      keys.nameKind: sourcekitd.values.nameSwift,
      keys.baseName: name.baseName,
      keys.argNames: sourcekitd.array(name.parameters.map { $0.stringOrWildcard }),
    ])

    let response = try await sendSourcekitdRequest(req, fileContents: snapshot.text)

    guard let isZeroArgSelector: Int = response[keys.isZeroArgSelector],
      let selectorPieces: SKDResponseArray = response[keys.selectorPieces]
    else {
      throw NameTranslationError.malformedSwiftToClangTranslateNameResponse(response)
    }
    return
      try selectorPieces
      .map { (dict: SKDResponseDictionary) -> String in
        guard var name: String = dict[keys.name] else {
          throw NameTranslationError.malformedSwiftToClangTranslateNameResponse(response)
        }
        if isZeroArgSelector == 0 {
          // Selector pieces in multi-arg selectors end with ":"
          name.append(":")
        }
        return name
      }.joined()
  }

  /// Translates a C/C++/Objective-C symbol name to Swift.
  ///
  /// This requires the position at which the the symbol is referenced in Swift so sourcekitd can determine the
  /// clang declaration that is being renamed and check if that declaration has a `SWIFT_NAME`. If it does, this
  /// `SWIFT_NAME` is used as the name translation result instead of invoking the clang importer rename rules.
  ///
  /// - Parameters:
  ///   - position: A position at which this symbol is referenced from Swift.
  ///   - snapshot: The snapshot containing the `position` that points to a usage of the clang symbol.
  ///   - isObjectiveCSelector: Whether the name is an Objective-C selector. Cannot be inferred from the name because
  ///     a name without `:` can also be a zero-arg Objective-C selector. For such names sourcekitd needs to know
  ///     whether it is translating a selector to apply the correct renaming rule.
  ///   - name: The clang symbol name.
  /// - Returns:
  fileprivate func translateClangNameToSwift(
    at symbolLocation: SymbolLocation,
    in snapshot: DocumentSnapshot,
    isObjectiveCSelector: Bool,
    name: String
  ) async throws -> String {
    let req = sourcekitd.dictionary([
      keys.request: sourcekitd.requests.nameTranslation,
      keys.sourceFile: snapshot.uri.pseudoPath,
      keys.compilerArgs: await self.buildSettings(for: snapshot.uri)?.compilerArgs as [SKDRequestValue]?,
      keys.offset: snapshot.utf8Offset(of: snapshot.position(of: symbolLocation)),
      keys.nameKind: sourcekitd.values.nameObjc,
    ])

    if isObjectiveCSelector {
      // Split the name into selector pieces, keeping the ':'.
      let selectorPieces = name.split(separator: ":").map { String($0 + ":") }
      req.set(keys.selectorPieces, to: sourcekitd.array(selectorPieces))
    } else {
      req.set(keys.baseName, to: name)
    }

    let response = try await sendSourcekitdRequest(req, fileContents: snapshot.text)

    guard let baseName: String = response[keys.baseName] else {
      throw NameTranslationError.malformedClangToSwiftTranslateNameResponse(response)
    }
    let argNamesArray: SKDResponseArray? = response[keys.argNames]
    let argNames = try argNamesArray?.map { (dict: SKDResponseDictionary) -> String in
      guard var name: String = dict[keys.name] else {
        throw NameTranslationError.malformedClangToSwiftTranslateNameResponse(response)
      }
      if name.isEmpty {
        // Empty argument names are represented by `_` in Swift.
        name = "_"
      }
      return name + ":"
    }
    var result = baseName
    if let argNames, !argNames.isEmpty {
      result += "(" + argNames.joined() + ")"
    }
    return result
  }
}

/// A name that has a representation both in Swift and clang-based languages.
///
/// These names might differ. For example, an Objective-C method gets translated by the clang importer to form the Swift
/// name or it could have a `SWIFT_NAME` attribute that defines the method's name in Swift. Similarly, a Swift symbol
/// might specify the name by which it gets exposed to Objective-C using the `@objc` attribute.
public struct CrossLanguageName: Sendable {
  /// The name of the symbol in clang languages or `nil` if the symbol is defined in Swift, doesn't have any references
  /// from clang languages and thus hasn't been translated.
  fileprivate let clangName: String?

  /// The name of the symbol in Swift or `nil` if the symbol is defined in clang, doesn't have any references from
  /// Swift and thus hasn't been translated.
  fileprivate let swiftName: String?

  fileprivate var compoundSwiftName: CompoundDeclName? {
    if let swiftName {
      return CompoundDeclName(swiftName)
    }
    return nil
  }

  /// the language that the symbol is defined in.
  fileprivate let definitionLanguage: Language

  /// The name of the symbol in the language that it is defined in.
  var definitionName: String? {
    switch definitionLanguage {
    case .c, .cpp, .objective_c, .objective_cpp:
      return clangName
    case .swift:
      return swiftName
    default:
      return nil
    }
  }
}

// MARK: - SourceKitLSPServer

/// The kinds of symbol occurrence roles that should be renamed.
fileprivate let renameRoles: SymbolRole = [.declaration, .definition, .reference]

extension DocumentManager {
  /// Returns the latest open snapshot of `uri` or, if no document with that URI is open, reads the file contents of
  /// that file from disk.
  fileprivate func latestSnapshotOrDisk(_ uri: DocumentURI, language: Language) -> DocumentSnapshot? {
    return (try? self.latestSnapshot(uri)) ?? (try? DocumentSnapshot(withContentsFromDisk: uri, language: language))
  }
}

extension SourceKitLSPServer {
  /// Returns a `DocumentSnapshot`, a position and the corresponding language service that references
  /// `usr` from a Swift file. If `usr` is not referenced from Swift, returns `nil`.
  private func getReferenceFromSwift(
    usr: String,
    index: CheckedIndex,
    workspace: Workspace
  ) async -> (swiftLanguageService: SwiftLanguageService, snapshot: DocumentSnapshot, location: SymbolLocation)? {
    var reference: SymbolOccurrence? = nil
    index.forEachSymbolOccurrence(byUSR: usr, roles: renameRoles) {
      if $0.symbolProvider == .swift {
        reference = $0
        // We have found a reference from Swift. Stop iteration.
        return false
      }
      return true
    }

    guard let reference else {
      return nil
    }
    let uri = reference.location.documentUri
    guard let snapshot = self.documentManager.latestSnapshotOrDisk(uri, language: .swift) else {
      return nil
    }
    let swiftLanguageService = await self.languageService(for: uri, .swift, in: workspace) as? SwiftLanguageService
    guard let swiftLanguageService else {
      return nil
    }
    return (swiftLanguageService, snapshot, reference.location)
  }

  /// Returns a `CrossLanguageName` for the symbol with the given USR.
  ///
  /// If the symbol is used across clang/Swift languages, the cross-language name will have both a `swiftName` and a
  /// `clangName` set. Otherwise it only has the name of the language it's defined in set.
  ///
  /// If `overrideName` is passed, the name of the symbol will be assumed to be `overrideName` in its native language.
  /// This is used to create a `CrossLanguageName` for the new name of a renamed symbol.
  private func getCrossLanguageName(
    forUsr usr: String,
    overrideName: String? = nil,
    workspace: Workspace,
    index: CheckedIndex
  ) async throws -> CrossLanguageName? {
    let definitions = index.occurrences(ofUSR: usr, roles: [.definition])
    if definitions.isEmpty {
      logger.error("No definitions for \(usr) found")
      return nil
    }
    if definitions.count > 1 {
      logger.log("Multiple definitions for \(usr) found")
    }
    // There might be multiple definitions of the same symbol eg. in different `#if` branches. In this case pick any of
    // them because with very high likelihood they all translate to the same clang and Swift name. Sort the entries to
    // ensure that we deterministically pick the same entry every time.
    for definitionOccurrence in definitions.sorted() {
      do {
        return try await getCrossLanguageName(
          forDefinitionOccurrence: definitionOccurrence,
          overrideName: overrideName,
          workspace: workspace,
          index: index
        )
      } catch {
        // If getting the cross-language name fails for this occurrence, try the next definition, if there are multiple.
        logger.log(
          "Getting cross-language name for occurrence at \(definitionOccurrence.location) failed. \(error.forLogging)"
        )
      }
    }
    return nil
  }

  // FIXME: (async-workaround): Needed to work around rdar://127977642
  private func translateClangNameToSwift(
    _ swiftLanguageService: SwiftLanguageService,
    at symbolLocation: SymbolLocation,
    in snapshot: DocumentSnapshot,
    isObjectiveCSelector: Bool,
    name: String
  ) async throws -> String {
    return try await swiftLanguageService.translateClangNameToSwift(
      at: symbolLocation,
      in: snapshot,
      isObjectiveCSelector: isObjectiveCSelector,
      name: name
    )
  }

  private func getCrossLanguageName(
    forDefinitionOccurrence definitionOccurrence: SymbolOccurrence,
    overrideName: String? = nil,
    workspace: Workspace,
    index: CheckedIndex
  ) async throws -> CrossLanguageName {
    let definitionSymbol = definitionOccurrence.symbol
    let usr = definitionSymbol.usr
    let definitionLanguage: Language =
      switch definitionSymbol.language {
      case .c: .c
      case .cxx: .cpp
      case .objc: .objective_c
      case .swift: .swift
      }
    let definitionDocumentUri = definitionOccurrence.location.documentUri

    guard
      let definitionLanguageService = await self.languageService(
        for: definitionDocumentUri,
        definitionLanguage,
        in: workspace
      )
    else {
      throw ResponseError.unknown("Failed to get language service for the document defining \(usr)")
    }

    let definitionName = overrideName ?? definitionSymbol.name

    switch definitionLanguageService {
    case is ClangLanguageService:
      let swiftName: String?
      if let swiftReference = await getReferenceFromSwift(usr: usr, index: index, workspace: workspace) {
        let isObjectiveCSelector = definitionLanguage == .objective_c && definitionSymbol.kind.isMethod
        swiftName = try await self.translateClangNameToSwift(
          swiftReference.swiftLanguageService,
          at: swiftReference.location,
          in: swiftReference.snapshot,
          isObjectiveCSelector: isObjectiveCSelector,
          name: definitionName
        )
      } else {
        logger.debug("Not translating \(definitionSymbol) to Swift because it is not referenced from Swift")
        swiftName = nil
      }
      return CrossLanguageName(clangName: definitionName, swiftName: swiftName, definitionLanguage: definitionLanguage)
    case let swiftLanguageService as SwiftLanguageService:
      // Continue iteration if the symbol provider is not clang.
      // If we terminate early by returning `false` from the closure, `forEachSymbolOccurrence` returns `true`,
      // indicating that we have found a reference from clang.
      let hasReferenceFromClang = !index.forEachSymbolOccurrence(byUSR: usr, roles: renameRoles) {
        return $0.symbolProvider != .clang
      }
      let clangName: String?
      if hasReferenceFromClang {
        clangName = try await swiftLanguageService.translateSwiftNameToClang(
          at: definitionOccurrence.location,
          in: definitionDocumentUri,
          name: CompoundDeclName(definitionName)
        )
      } else {
        clangName = nil
      }
      return CrossLanguageName(clangName: clangName, swiftName: definitionName, definitionLanguage: definitionLanguage)
    default:
      throw ResponseError.unknown("Cannot rename symbol because it is defined in an unknown language")
    }
  }

  /// Starting from the given USR, compute the transitive closure of all declarations that are overridden or override
  /// the symbol, including the USR itself.
  ///
  /// This includes symbols that need to traverse the inheritance hierarchy up and down. For example, it includes all
  /// occurrences of `foo` in the following when started from `Inherited.foo`.
  ///
  /// ```swift
  /// class Base { func foo() {} }
  /// class Inherited: Base { override func foo() {} }
  /// class OtherInherited: Base { override func foo() {} }
  /// ```
  private func overridingAndOverriddenUsrs(of usr: String, index: CheckedIndex) -> [String] {
    var workList = [usr]
    var usrs: [String] = []
    while let usr = workList.popLast() {
      usrs.append(usr)
      var relatedUsrs = index.occurrences(relatedToUSR: usr, roles: .overrideOf).map(\.symbol.usr)
      relatedUsrs += index.occurrences(ofUSR: usr, roles: .overrideOf).flatMap { occurrence in
        occurrence.relations.filter { $0.roles.contains(.overrideOf) }.map(\.symbol.usr)
      }
      for overriddenUsr in relatedUsrs {
        if usrs.contains(overriddenUsr) || workList.contains(overriddenUsr) {
          // Already handling this USR. Nothing to do.
          continue
        }
        workList.append(overriddenUsr)
      }
    }
    return usrs
  }

  func rename(_ request: RenameRequest) async throws -> WorkspaceEdit? {
    let uri = request.textDocument.uri
    let snapshot = try documentManager.latestSnapshot(uri)

    guard let workspace = await workspaceForDocument(uri: uri) else {
      throw ResponseError.workspaceNotOpen(uri)
    }
    guard let primaryFileLanguageService = workspace.documentService.value[uri] else {
      return nil
    }

    // Determine the local edits and the USR to rename
    let renameResult = try await primaryFileLanguageService.rename(request)

    // We only check if the files exist. If a source file has been modified on disk, we will still try to perform a
    // rename. Rename will check if the expected old name exists at the location in the index and, if not, ignore that
    // location. This way we are still able to rename occurrences in files where eg. only one line has been modified but
    // all the line:column locations of occurrences are still up-to-date.
    // This should match the check level in prepareRename.
    guard let usr = renameResult.usr, let index = workspace.index(checkedFor: .deletedFiles) else {
      // We don't have enough information to perform a cross-file rename.
      return renameResult.edits
    }

    let oldName = try await getCrossLanguageName(forUsr: usr, workspace: workspace, index: index)
    let newName = try await getCrossLanguageName(
      forUsr: usr,
      overrideName: request.newName,
      workspace: workspace,
      index: index
    )

    guard let oldName, let newName else {
      // We failed to get the translated name, so we can't to global rename.
      // Do local rename within the current file instead as fallback.
      return renameResult.edits
    }

    var changes: [DocumentURI: [TextEdit]] = [:]
    if oldName.definitionLanguage == snapshot.language {
      // If this is not a cross-language rename, we can use the local edits returned by
      // the language service's rename function.
      // If this is cross-language rename, that's not possible because the user would eg.
      // enter a new clang name, which needs to be translated to the Swift name before
      // changing the current file.
      changes = renameResult.edits.changes ?? [:]
    }

    // If we have a USR + old name, perform an index lookup to find workspace-wide symbols to rename.
    // First, group all occurrences of that USR by the files they occur in.
    var locationsByFile: [DocumentURI: (renameLocations: [RenameLocation], symbolProvider: SymbolProviderKind)] = [:]

    let usrsToRename = overridingAndOverriddenUsrs(of: usr, index: index)
    let occurrencesToRename = usrsToRename.flatMap { index.occurrences(ofUSR: $0, roles: renameRoles) }
    for occurrence in occurrencesToRename {
      let uri = occurrence.location.documentUri

      // Determine whether we should add the location produced by the index to those that will be renamed, or if it has
      // already been handled by the set provided by the AST.
      if changes[uri] != nil {
        if occurrence.symbol.usr == usr {
          // If the language server's rename function already produced AST-based locations for this symbol, no need to
          // perform an indexed rename for it.
          continue
        }
        switch occurrence.symbolProvider {
        case .swift:
          // sourcekitd only produces AST-based results for the direct calls to this USR. This is because the Swift
          // AST only has upwards references to superclasses and overridden methods, not the other way round. It is
          // thus not possible to (easily) compute an up-down closure like described in `overridingAndOverriddenUsrs`.
          // We thus need to perform an indexed rename for other, related USRs.
          break
        case .clang:
          // clangd produces AST-based results for the entire class hierarchy, so nothing to do.
          continue
        }
      }

      let renameLocation = RenameLocation(
        line: occurrence.location.line,
        utf8Column: occurrence.location.utf8Column,
        usage: RenameLocation.Usage(roles: occurrence.roles)
      )
      if let existingLocations = locationsByFile[uri] {
        if existingLocations.symbolProvider != occurrence.symbolProvider {
          logger.fault(
            """
            Found mismatching symbol providers for \(uri.forLogging): \
            \(String(describing: existingLocations.symbolProvider), privacy: .public) vs \
            \(String(describing: occurrence.symbolProvider), privacy: .public)
            """
          )
        }
        locationsByFile[uri] = (existingLocations.renameLocations + [renameLocation], occurrence.symbolProvider)
      } else {
        locationsByFile[uri] = ([renameLocation], occurrence.symbolProvider)
      }
    }

    // Now, call `editsToRename(locations:in:oldName:newName:)` on the language service to convert these ranges into
    // edits.
    let urisAndEdits =
      await locationsByFile
      .concurrentMap {
        (
          uri: DocumentURI,
          value: (renameLocations: [RenameLocation], symbolProvider: SymbolProviderKind)
        ) -> (DocumentURI, [TextEdit])? in
        let language: Language
        switch value.symbolProvider {
        case .clang:
          // Technically, we still don't know the language of the source file but defaulting to C is sufficient to
          // ensure we get the clang toolchain language server, which is all we care about.
          language = .c
        case .swift:
          language = .swift
        }
        // Create a document snapshot to operate on. If the document is open, load it from the document manager,
        // otherwise conjure one from the file on disk. We need the file in memory to perform UTF-8 to UTF-16 column
        // conversions.
        guard let snapshot = self.documentManager.latestSnapshotOrDisk(uri, language: language) else {
          logger.error("Failed to get document snapshot for \(uri.forLogging)")
          return nil
        }
        guard let languageService = await self.languageService(for: uri, language, in: workspace) else {
          return nil
        }

        var edits: [TextEdit] =
          await orLog("Getting edits for rename location") {
            return try await languageService.editsToRename(
              locations: value.renameLocations,
              in: snapshot,
              oldName: oldName,
              newName: newName
            )
          } ?? []
        for location in value.renameLocations where location.usage == .definition {
          edits += await languageService.editsToRenameParametersInFunctionBody(
            snapshot: snapshot,
            renameLocation: location,
            newName: newName
          )
        }
        edits = edits.filter { !$0.isNoOp(in: snapshot) }
        return (uri, edits)
      }.compactMap { $0 }
    for (uri, editsForUri) in urisAndEdits {
      if !editsForUri.isEmpty {
        changes[uri, default: []] += editsForUri
      }
    }
    var edits = renameResult.edits
    edits.changes = changes
    return edits
  }

  func prepareRename(
    _ request: PrepareRenameRequest,
    workspace: Workspace,
    languageService: LanguageService
  ) async throws -> PrepareRenameResponse? {
    guard let languageServicePrepareRename = try await languageService.prepareRename(request) else {
      return nil
    }
    var prepareRenameResult = languageServicePrepareRename.prepareRename

    guard
      let index = workspace.index(checkedFor: .deletedFiles),
      let usr = languageServicePrepareRename.usr,
      let oldName = try await self.getCrossLanguageName(forUsr: usr, workspace: workspace, index: index),
      var definitionName = oldName.definitionName
    else {
      return prepareRenameResult
    }
    if oldName.definitionLanguage == .swift, definitionName.hasSuffix("()") {
      definitionName = String(definitionName.dropLast(2))
    }

    // Get the name of the symbol's definition, if possible.
    // This is necessary for cross-language rename. Eg. when renaming an Objective-C method from Swift,
    // the user still needs to enter the new Objective-C name.
    prepareRenameResult.placeholder = definitionName
    return prepareRenameResult
  }

  func indexedRename(
    _ request: IndexedRenameRequest,
    workspace: Workspace,
    languageService: LanguageService
  ) async throws -> WorkspaceEdit? {
    return try await languageService.indexedRename(request)
  }
}

// MARK: - Swift

extension SwiftLanguageService {
  /// From a list of rename locations compute the list of `SyntacticRenameName`s that define which ranges need to be
  /// edited to rename a compound decl name.
  ///
  /// - Parameters:
  ///   - renameLocations: The locations to rename
  ///   - oldName: The compound decl name that the declaration had before the rename. Used to verify that the rename
  ///     locations match that name. Eg. `myFunc(argLabel:otherLabel:)` or `myVar`
  ///   - snapshot: A `DocumentSnapshot` containing the contents of the file for which to compute the rename ranges.
  private func getSyntacticRenameRanges(
    renameLocations: [RenameLocation],
    oldName: String,
    in snapshot: DocumentSnapshot
  ) async throws -> [SyntacticRenameName] {
    let locations = sourcekitd.array(
      renameLocations.map { renameLocation in
        let location = sourcekitd.dictionary([
          keys.line: renameLocation.line,
          keys.column: renameLocation.utf8Column,
          keys.nameType: renameLocation.usage.uid(values: values),
        ])
        return sourcekitd.dictionary([
          keys.locations: [location],
          keys.name: oldName,
        ])
      }
    )

    let skreq = sourcekitd.dictionary([
      keys.request: requests.findRenameRanges,
      keys.sourceFile: snapshot.uri.pseudoPath,
      // find-syntactic-rename-ranges is a syntactic sourcekitd request that doesn't use the in-memory file snapshot.
      // We need to send the source text again.
      keys.sourceText: snapshot.text,
      keys.renameLocations: locations,
    ])

    let syntacticRenameRangesResponse = try await sendSourcekitdRequest(skreq, fileContents: snapshot.text)
    guard let categorizedRanges: SKDResponseArray = syntacticRenameRangesResponse[keys.categorizedRanges] else {
      throw ResponseError.internalError("sourcekitd did not return categorized ranges")
    }

    return categorizedRanges.compactMap { SyntacticRenameName($0, in: snapshot, keys: keys, values: values) }
  }

  /// If `position` is on an argument label or a parameter name, find the range from the function's base name to the
  /// token that terminates the arguments or parameters of the function. Typically, this is the closing ')' but it can
  /// also be a closing ']' for subscripts or the end of a trailing closure.
  private func findFunctionLikeRange(of position: Position, in snapshot: DocumentSnapshot) async -> Range<Position>? {
    let tree = await self.syntaxTreeManager.syntaxTree(for: snapshot)
    guard let token = tree.token(at: snapshot.absolutePosition(of: position)) else {
      return nil
    }

    // The node that contains the function's base name. This might be an expression like `self.doStuff`.
    // The start position of the last token in this node will be used as the base name position.
    var startToken: TokenSyntax? = nil
    var endToken: TokenSyntax? = nil

    switch token.keyPathInParent {
    case \LabeledExprSyntax.label:
      let callLike = token.parent(as: LabeledExprSyntax.self)?.parent(as: LabeledExprListSyntax.self)?.parent
      switch callLike?.as(SyntaxEnum.self) {
      case .attribute(let attribute):
        startToken = attribute.attributeName.lastToken(viewMode: .sourceAccurate)
        endToken = attribute.lastToken(viewMode: .sourceAccurate)
      case .functionCallExpr(let functionCall):
        startToken = functionCall.calledExpression.lastToken(viewMode: .sourceAccurate)
        endToken = functionCall.lastToken(viewMode: .sourceAccurate)
      case .macroExpansionDecl(let macroExpansionDecl):
        startToken = macroExpansionDecl.macroName
        endToken = macroExpansionDecl.lastToken(viewMode: .sourceAccurate)
      case .macroExpansionExpr(let macroExpansionExpr):
        startToken = macroExpansionExpr.macroName
        endToken = macroExpansionExpr.lastToken(viewMode: .sourceAccurate)
      case .subscriptCallExpr(let subscriptCall):
        startToken = subscriptCall.leftSquare
        endToken = subscriptCall.lastToken(viewMode: .sourceAccurate)
      default:
        break
      }
    case \FunctionParameterSyntax.firstName:
      let parameterClause =
        token
        .parent(as: FunctionParameterSyntax.self)?
        .parent(as: FunctionParameterListSyntax.self)?
        .parent(as: FunctionParameterClauseSyntax.self)
      if let functionSignature = parameterClause?.parent(as: FunctionSignatureSyntax.self) {
        switch functionSignature.parent?.as(SyntaxEnum.self) {
        case .functionDecl(let functionDecl):
          startToken = functionDecl.name
          endToken = functionSignature.parameterClause.rightParen
        case .initializerDecl(let initializerDecl):
          startToken = initializerDecl.initKeyword
          endToken = functionSignature.parameterClause.rightParen
        case .macroDecl(let macroDecl):
          startToken = macroDecl.name
          endToken = functionSignature.parameterClause.rightParen
        default:
          break
        }
      } else if let subscriptDecl = parameterClause?.parent(as: SubscriptDeclSyntax.self) {
        startToken = subscriptDecl.subscriptKeyword
        endToken = subscriptDecl.parameterClause.rightParen
      }
    case \DeclNameArgumentSyntax.name:
      let declReference =
        token
        .parent(as: DeclNameArgumentSyntax.self)?
        .parent(as: DeclNameArgumentListSyntax.self)?
        .parent(as: DeclNameArgumentsSyntax.self)?
        .parent(as: DeclReferenceExprSyntax.self)
      startToken = declReference?.baseName
      endToken = declReference?.argumentNames?.rightParen
    default:
      break
    }

    if let startToken, let endToken {
      return snapshot.absolutePositionRange(
        of: startToken.positionAfterSkippingLeadingTrivia..<endToken.endPositionBeforeTrailingTrivia
      )
    }
    return nil
  }

  /// When the user requested a rename at `position` in `snapshot`, determine the position at which the rename should be
  /// performed internally, the USR of the symbol to rename and the range to rename that should be returned to the
  /// editor.
  ///
  /// This is necessary to adjust the rename position when renaming function parameters. For example when invoking
  /// rename on `x` in `foo(x:)`, we need to perform a rename of `foo` in sourcekitd so that we can rename the function
  /// parameter.
  ///
  /// The position might be `nil` if there is no local position in the file that refers to the base name to be renamed.
  /// This happens if renaming a function parameter of `MyStruct(x:)` where `MyStruct` is defined outside of the current
  /// file. In this case, there is no base name that refers to the initializer of `MyStruct`. When `position` is `nil`
  /// a pure index-based rename from the usr USR or `symbolDetails` needs to be performed and no `relatedIdentifiers`
  /// request can be used to rename symbols in the current file.
  ///
  /// `position` might be at a different location in the source file than where the user initiated the rename.
  /// For example, `position` could point to the definition of a function within the file when rename was initiated on
  /// a call.
  ///
  /// If a `functionLikeRange` is returned, this is an expanded range that contains both the symbol to rename as well
  /// as the position at which the rename was requested. For example, when rename was initiated from the argument label
  /// of a function call, the `range` will contain the entire function call from the base name to the closing `)`.
  func symbolToRename(
    at position: Position,
    in snapshot: DocumentSnapshot
  ) async -> (position: Position?, usr: String?, functionLikeRange: Range<Position>?) {
    let startOfIdentifierPosition = await adjustPositionToStartOfIdentifier(position, in: snapshot)
    let symbolInfo = try? await self.symbolInfo(
      SymbolInfoRequest(textDocument: TextDocumentIdentifier(snapshot.uri), position: startOfIdentifierPosition)
    )

    guard let functionLikeRange = await findFunctionLikeRange(of: startOfIdentifierPosition, in: snapshot) else {
      return (startOfIdentifierPosition, symbolInfo?.only?.usr, nil)
    }
    if let onlySymbol = symbolInfo?.only, onlySymbol.kind == .constructor {
      // We have a rename like `MyStruct(x: 1)`, invoked from `x`.
      if let bestLocalDeclaration = onlySymbol.bestLocalDeclaration, bestLocalDeclaration.uri == snapshot.uri {
        // If the initializer is declared within the same file, we can perform rename in the current file based on
        // the declaration's location.
        return (bestLocalDeclaration.range.lowerBound, onlySymbol.usr, functionLikeRange)
      }
      // Otherwise, we don't have a reference to the base name of the initializer and we can't use related
      // identifiers to perform the rename.
      // Return `nil` for the position to perform a pure index-based rename.
      return (nil, onlySymbol.usr, functionLikeRange)
    }
    // Adjust the symbol info to the symbol info of the base name.
    // This ensures that we get the symbol info of the function's base instead of the parameter.
    let baseNameSymbolInfo = try? await self.symbolInfo(
      SymbolInfoRequest(textDocument: TextDocumentIdentifier(snapshot.uri), position: functionLikeRange.lowerBound)
    )
    return (functionLikeRange.lowerBound, baseNameSymbolInfo?.only?.usr, functionLikeRange)
  }

  public func rename(_ request: RenameRequest) async throws -> (edits: WorkspaceEdit, usr: String?) {
    let snapshot = try self.documentManager.latestSnapshot(request.textDocument.uri)

    let (renamePosition, usr, _) = await symbolToRename(at: request.position, in: snapshot)
    guard let renamePosition else {
      return (edits: WorkspaceEdit(), usr: usr)
    }

    let relatedIdentifiersResponse = try await self.relatedIdentifiers(
      at: renamePosition,
      in: snapshot,
      includeNonEditableBaseNames: true
    )
    guard let oldNameString = relatedIdentifiersResponse.name else {
      throw ResponseError.unknown("Running sourcekit-lsp with a version of sourcekitd that does not support rename")
    }

    let renameLocations = relatedIdentifiersResponse.renameLocations(in: snapshot)

    try Task.checkCancellation()

    let oldName = CrossLanguageName(clangName: nil, swiftName: oldNameString, definitionLanguage: .swift)
    let newName = CrossLanguageName(clangName: nil, swiftName: request.newName, definitionLanguage: .swift)
    var edits = try await editsToRename(
      locations: renameLocations,
      in: snapshot,
      oldName: oldName,
      newName: newName
    )
    if let compoundSwiftName = oldName.compoundSwiftName, !compoundSwiftName.parameters.isEmpty {
      // If we are doing a function rename, run `renameParametersInFunctionBody` for every occurrence of the rename
      // location within the current file. If the location is not a function declaration, it will exit early without
      // invoking sourcekitd, so it's OK to do this performance-wise.
      for renameLocation in renameLocations {
        edits += await editsToRenameParametersInFunctionBody(
          snapshot: snapshot,
          renameLocation: renameLocation,
          newName: newName
        )
      }
    }
    edits = edits.filter { !$0.isNoOp(in: snapshot) }

    if edits.isEmpty {
      return (edits: WorkspaceEdit(changes: [:]), usr: usr)
    }
    return (edits: WorkspaceEdit(changes: [snapshot.uri: edits]), usr: usr)
  }

  public func editsToRenameParametersInFunctionBody(
    snapshot: DocumentSnapshot,
    renameLocation: RenameLocation,
    newName: CrossLanguageName
  ) async -> [TextEdit] {
    let position = snapshot.absolutePosition(of: renameLocation)
    let syntaxTree = await syntaxTreeManager.syntaxTree(for: snapshot)
    let token = syntaxTree.token(at: position)
    let parameterClause: FunctionParameterClauseSyntax?
    switch token?.keyPathInParent {
    case \FunctionDeclSyntax.name:
      parameterClause = token?.parent(as: FunctionDeclSyntax.self)?.signature.parameterClause
    case \InitializerDeclSyntax.initKeyword:
      parameterClause = token?.parent(as: InitializerDeclSyntax.self)?.signature.parameterClause
    case \SubscriptDeclSyntax.subscriptKeyword:
      parameterClause = token?.parent(as: SubscriptDeclSyntax.self)?.parameterClause
    default:
      parameterClause = nil
    }
    guard let parameterClause else {
      // We are not at a function-like definition. Nothing to rename.
      return []
    }
    guard let newSwiftNameString = newName.swiftName else {
      logger.fault(
        "Cannot rename at \(renameLocation.line):\(renameLocation.utf8Column) because new name is not a Swift name"
      )
      return []
    }
    let newSwiftName = CompoundDeclName(newSwiftNameString)

    var edits: [TextEdit] = []
    for (index, parameter) in parameterClause.parameters.enumerated() {
      guard parameter.secondName == nil else {
        // The parameter has a second name. The function signature only renames the first name and the function body
        // refers to the second name. Nothing to do.
        continue
      }
      let oldParameterName = parameter.firstName.text
      guard index < newSwiftName.parameters.count else {
        // We don't have a new name for this parameter. Nothing to do.
        continue
      }
      let newParameterName = newSwiftName.parameters[index].stringOrEmpty
      guard !newParameterName.isEmpty else {
        // We are changing the parameter to an empty name. This will retain the current external parameter name as the
        // new second name, so nothing to do in the function body.
        continue
      }
      guard newParameterName != oldParameterName else {
        // This parameter wasn't modified. Nothing to do.
        continue
      }

      let oldCrossLanguageParameterName = CrossLanguageName(
        clangName: nil,
        swiftName: oldParameterName,
        definitionLanguage: .swift
      )
      let newCrossLanguageParameterName = CrossLanguageName(
        clangName: nil,
        swiftName: newParameterName,
        definitionLanguage: .swift
      )

      let parameterRenameEdits = await orLog("Renaming parameter") {
        let parameterPosition = snapshot.position(of: parameter.positionAfterSkippingLeadingTrivia)
        // Once we have lexical scope lookup in swift-syntax, this can be a purely syntactic rename.
        // We know that the parameters are variables and thus there can't be overloads that need to be resolved by the
        // type checker.
        let relatedIdentifiers = try await self.relatedIdentifiers(
          at: parameterPosition,
          in: snapshot,
          includeNonEditableBaseNames: false
        )

        // Exclude the edit that renames the parameter itself. The parameter gets renamed as part of the function
        // declaration.
        let filteredRelatedIdentifiers = RelatedIdentifiersResponse(
          relatedIdentifiers: relatedIdentifiers.relatedIdentifiers.filter { !$0.range.contains(parameterPosition) },
          name: relatedIdentifiers.name
        )

        let parameterRenameLocations = filteredRelatedIdentifiers.renameLocations(in: snapshot)

        return try await editsToRename(
          locations: parameterRenameLocations,
          in: snapshot,
          oldName: oldCrossLanguageParameterName,
          newName: newCrossLanguageParameterName
        )
      }
      guard let parameterRenameEdits else {
        continue
      }
      edits += parameterRenameEdits
    }
    return edits
  }

  /// Return the edit that needs to be performed for the given syntactic rename piece to rename it from
  /// `oldParameter` to `newParameter`.
  /// Returns `nil` if no edit needs to be performed.
  private func textEdit(
    for piece: SyntacticRenamePiece,
    in snapshot: DocumentSnapshot,
    oldParameter: CompoundDeclName.Parameter,
    newParameter: CompoundDeclName.Parameter
  ) -> TextEdit? {
    switch piece.kind {
    case .parameterName:
      if newParameter == .wildcard, piece.range.isEmpty, case .named(let oldParameterName) = oldParameter {
        // We are changing a named parameter to an unnamed one. If the parameter didn't have an internal parameter
        // name, we need to transfer the previously external parameter name to be the internal one.
        // E.g. `func foo(a: Int)` becomes `func foo(_ a: Int)`.
        return TextEdit(range: piece.range, newText: " " + oldParameterName)
      }
      if case .named(let newParameterLabel) = newParameter,
        newParameterLabel.trimmingCharacters(in: .whitespaces)
          == snapshot.lineTable[piece.range].trimmingCharacters(in: .whitespaces)
      {
        // We are changing the external parameter name to be the same one as the internal parameter name. The
        // internal name is thus no longer needed. Drop it.
        // Eg. an old declaration `func foo(_ a: Int)` becomes `func foo(a: Int)` when renaming the parameter to `a`
        return TextEdit(range: piece.range, newText: "")
      }
      // In all other cases, don't touch the internal parameter name. It's not part of the public API.
      return nil
    case .noncollapsibleParameterName:
      // Noncollapsible parameter names should never be renamed because they are the same as `parameterName` but
      // never fall into one of the two categories above.
      return nil
    case .declArgumentLabel:
      if piece.range.isEmpty {
        // If we are inserting a new external argument label where there wasn't one before, add a space after it to
        // separate it from the internal name.
        // E.g. `subscript(a: Int)` becomes `subscript(a a: Int)`.
        return TextEdit(range: piece.range, newText: newParameter.stringOrWildcard + " ")
      }
      // Otherwise, just update the name.
      return TextEdit(range: piece.range, newText: newParameter.stringOrWildcard)
    case .callArgumentLabel:
      // Argument labels of calls are just updated.
      return TextEdit(range: piece.range, newText: newParameter.stringOrEmpty)
    case .callArgumentColon:
      if case .wildcard = newParameter {
        // If the parameter becomes unnamed, remove the colon after the argument name.
        return TextEdit(range: piece.range, newText: "")
      }
      return nil
    case .callArgumentCombined:
      if case .named(let newParameterName) = newParameter {
        // If an unnamed parameter becomes named, insert the new name and a colon.
        return TextEdit(range: piece.range, newText: newParameterName + ": ")
      }
      return nil
    case .selectorArgumentLabel:
      return TextEdit(range: piece.range, newText: newParameter.stringOrWildcard)
    case .baseName, .keywordBaseName:
      preconditionFailure("Handled above")
    }
  }

  public func editsToRename(
    locations renameLocations: [RenameLocation],
    in snapshot: DocumentSnapshot,
    oldName oldCrossLanguageName: CrossLanguageName,
    newName newCrossLanguageName: CrossLanguageName
  ) async throws -> [TextEdit] {
    guard
      let oldNameString = oldCrossLanguageName.swiftName,
      let oldName = oldCrossLanguageName.compoundSwiftName,
      let newName = newCrossLanguageName.compoundSwiftName
    else {
      throw ResponseError.unknown(
        "Failed to rename \(snapshot.uri.forLogging) because the Swift name for rename is unknown"
      )
    }

    let tree = await syntaxTreeManager.syntaxTree(for: snapshot)

    let compoundRenameRanges = try await getSyntacticRenameRanges(
      renameLocations: renameLocations,
      oldName: oldNameString,
      in: snapshot
    )

    try Task.checkCancellation()

    return compoundRenameRanges.flatMap { (compoundRenameRange) -> [TextEdit] in
      switch compoundRenameRange.category {
      case .unmatched, .mismatch:
        // The location didn't match. Don't rename it
        return []
      case .activeCode, .inactiveCode, .selector:
        // Occurrences in active code and selectors should always be renamed.
        // Inactive code is currently never returned by sourcekitd.
        break
      case .string, .comment:
        // We currently never get any results in strings or comments because the related identifiers request doesn't
        // provide any locations inside strings or comments. We would need to have a textual index to find these
        // locations.
        return []
      }
      return compoundRenameRange.pieces.compactMap { (piece) -> TextEdit? in
        if piece.kind == .baseName {
          if let firstNameToken = tree.token(at: snapshot.absolutePosition(of: piece.range.lowerBound)),
            firstNameToken.keyPathInParent == \FunctionParameterSyntax.firstName,
            let parameterSyntax = firstNameToken.parent(as: FunctionParameterSyntax.self),
            parameterSyntax.secondName == nil  // Should always be true because otherwise decl would be second name
          {
            // We are renaming a function parameter from inside the function body.
            // This should be a local rename and it shouldn't affect all the callers of the function. Introduce the new
            // name as a second name.
            return TextEdit(
              range: Range(snapshot.position(of: firstNameToken.endPositionBeforeTrailingTrivia)),
              newText: " " + newName.baseName
            )
          }

          return TextEdit(range: piece.range, newText: newName.baseName)
        } else if piece.kind == .keywordBaseName {
          // Keyword base names can't be renamed
          return nil
        }

        guard let parameterIndex = piece.parameterIndex,
          parameterIndex < newName.parameters.count,
          parameterIndex < oldName.parameters.count
        else {
          // Be lenient and just keep the old parameter names if the new name doesn't specify them, eg. if we are
          // renaming `func foo(a: Int, b: Int)` and the user specified `bar(x:)` as the new name.
          return nil
        }

        return self.textEdit(
          for: piece,
          in: snapshot,
          oldParameter: oldName.parameters[parameterIndex],
          newParameter: newName.parameters[parameterIndex]
        )
      }
    }
  }

  public func prepareRename(
    _ request: PrepareRenameRequest
  ) async throws -> (prepareRename: PrepareRenameResponse, usr: String?)? {
    let snapshot = try self.documentManager.latestSnapshot(request.textDocument.uri)

    let (renamePosition, usr, functionLikeRange) = await symbolToRename(at: request.position, in: snapshot)
    guard let renamePosition else {
      return nil
    }

    let response = try await self.relatedIdentifiers(
      at: renamePosition,
      in: snapshot,
      includeNonEditableBaseNames: true
    )
    guard var name = response.name else {
      throw ResponseError.unknown("Running sourcekit-lsp with a version of sourcekitd that does not support rename")
    }
    if name.hasSuffix("()") {
      name = String(name.dropLast(2))
    }
    guard let relatedIdentRange = response.relatedIdentifiers.first(where: { $0.range.contains(renamePosition) })?.range
    else {
      return nil
    }
    return (PrepareRenameResponse(range: functionLikeRange ?? relatedIdentRange, placeholder: name), usr)
  }
}

// MARK: - Clang

extension ClangLanguageService {
  func rename(_ renameRequest: RenameRequest) async throws -> (edits: WorkspaceEdit, usr: String?) {
    async let edits = forwardRequestToClangd(renameRequest)
    let symbolInfoRequest = SymbolInfoRequest(
      textDocument: renameRequest.textDocument,
      position: renameRequest.position
    )
    let symbolDetail = try await forwardRequestToClangd(symbolInfoRequest).only
    return (try await edits ?? WorkspaceEdit(), symbolDetail?.usr)
  }

  func editsToRename(
    locations renameLocations: [RenameLocation],
    in snapshot: DocumentSnapshot,
    oldName oldCrossLanguageName: CrossLanguageName,
    newName newCrossLanguageName: CrossLanguageName
  ) async throws -> [TextEdit] {
    let positions = [
      snapshot.uri: renameLocations.compactMap { snapshot.position(of: $0) }
    ]
    guard
      let oldName = oldCrossLanguageName.clangName,
      let newName = newCrossLanguageName.clangName
    else {
      throw ResponseError.unknown(
        "Failed to rename \(snapshot.uri.forLogging) because the clang name for rename is unknown"
      )
    }
    let request = IndexedRenameRequest(
      textDocument: TextDocumentIdentifier(snapshot.uri),
      oldName: oldName,
      newName: newName,
      positions: positions
    )
    do {
      let edits = try await forwardRequestToClangd(request)
      return edits?.changes?[snapshot.uri] ?? []
    } catch {
      logger.error("Failed to get indexed rename edits: \(error.forLogging)")
      return []
    }
  }

  public func prepareRename(
    _ request: PrepareRenameRequest
  ) async throws -> (prepareRename: PrepareRenameResponse, usr: String?)? {
    guard let prepareRename = try await forwardRequestToClangd(request) else {
      return nil
    }
    let symbolInfo = try await forwardRequestToClangd(
      SymbolInfoRequest(textDocument: request.textDocument, position: request.position)
    )
    return (prepareRename, symbolInfo.only?.usr)
  }

  public func editsToRenameParametersInFunctionBody(
    snapshot: DocumentSnapshot,
    renameLocation: RenameLocation,
    newName: CrossLanguageName
  ) async -> [TextEdit] {
    // When renaming a clang function name, we don't need to rename any references to the arguments.
    return []
  }
}

fileprivate extension SyntaxProtocol {
  /// Returns the parent node and casts it to the specified type.
  func parent<S: SyntaxProtocol>(as syntaxType: S.Type) -> S? {
    return parent?.as(S.self)
  }
}

fileprivate extension RelatedIdentifiersResponse {
  func renameLocations(in snapshot: DocumentSnapshot) -> [RenameLocation] {
    return self.relatedIdentifiers.map {
      (relatedIdentifier) -> RenameLocation in
      let position = relatedIdentifier.range.lowerBound
      let utf8Column = snapshot.lineTable.utf8ColumnAt(line: position.line, utf16Column: position.utf16index)
      return RenameLocation(line: position.line + 1, utf8Column: utf8Column + 1, usage: relatedIdentifier.usage)
    }
  }
}
