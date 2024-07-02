//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import LanguageServerProtocol
import SourceKitD

/// Detailed information about a symbol under the cursor.
///
/// Wraps the information returned by sourcekitd's `cursor_info` request, such as symbol name, USR,
/// and declaration location. This is intended to only do lightweight processing of the data to make
/// it easier to use from Swift. Any expensive processing, such as parsing the XML strings, is
/// handled elsewhere.
struct CursorInfo {

  /// Information common between CursorInfo and SymbolDetails from the `symbolInfo` request, such as
  /// name and USR.
  var symbolInfo: SymbolDetails

  /// The annotated declaration XML string.
  var annotatedDeclaration: String?

  #if swift(>=6.2)
  #warning(
    "Documentation transitioned from XML to the raw string in Swift 6.0. We should be able to remove documentationXML now"
  )
  #endif
  /// The documentation comment XML string. The schema is at
  /// https://github.com/apple/swift/blob/main/bindings/xml/comment-xml-schema.rng
  var documentationXML: String?

  /// The documentation as it is spelled in
  var documentation: String?

  /// The refactor actions available at this position.
  var refactorActions: [SemanticRefactorCommand]? = nil

  init(
    _ symbolInfo: SymbolDetails,
    annotatedDeclaration: String?,
    documentationXML: String?,
    documentation: String?
  ) {
    self.symbolInfo = symbolInfo
    self.annotatedDeclaration = annotatedDeclaration
    self.documentationXML = documentationXML
    self.documentation = documentation
  }

  init?(
    _ dict: SKDResponseDictionary,
    sourcekitd: some SourceKitD
  ) {
    let keys = sourcekitd.keys
    guard let kind: sourcekitd_api_uid_t = dict[keys.kind] else {
      // Nothing to report.
      return nil
    }

    let location: Location?
    if let filepath: String = dict[keys.filePath],
      let line: Int = dict[keys.line],
      let column: Int = dict[keys.column]
    {
      let position = Position(
        line: line - 1,
        // FIXME: we need to convert the utf8/utf16 column, which may require reading the file!
        utf16index: column - 1
      )
      location = Location(uri: DocumentURI(filePath: filepath, isDirectory: false), range: Range(position))
    } else {
      location = nil
    }

    let module: SymbolDetails.ModuleInfo?
    if let moduleName: String = dict[keys.moduleName] {
      let groupName: String? = dict[keys.groupName]
      module = SymbolDetails.ModuleInfo(moduleName: moduleName, groupName: groupName)
    } else {
      module = nil
    }

    self.init(
      SymbolDetails(
        name: dict[keys.name],
        containerName: nil,
        usr: dict[keys.usr],
        bestLocalDeclaration: location,
        kind: kind.asSymbolKind(sourcekitd.values),
        isDynamic: dict[keys.isDynamic] ?? false,
        isSystem: dict[keys.isSystem] ?? false,
        receiverUsrs: dict[keys.receivers]?.compactMap { $0[keys.usr] as String? } ?? [],
        systemModule: module
      ),
      annotatedDeclaration: dict[keys.annotatedDecl],
      documentationXML: dict[keys.docFullAsXML],
      documentation: dict[keys.docComment]
    )
  }
}

/// An error from a cursor info request.
enum CursorInfoError: Error, Equatable {
  /// The given range is not valid in the document snapshot.
  case invalidRange(Range<Position>)

  /// The underlying sourcekitd request failed with the given error.
  case responseError(ResponseError)
}

extension CursorInfoError: CustomStringConvertible {
  var description: String {
    switch self {
    case .invalidRange(let range):
      return "invalid range \(range)"
    case .responseError(let error):
      return "\(error)"
    }
  }
}

extension SwiftLanguageService {
  /// Provides detailed information about a symbol under the cursor, if any.
  ///
  /// Wraps the information returned by sourcekitd's `cursor_info` request, such as symbol name,
  /// USR, and declaration location. This request does minimal processing of the result.
  ///
  /// - Parameters:
  ///   - url: Document URI in which to perform the request. Must be an open document.
  ///   - range: The position range within the document to lookup the symbol at.
  ///   - completion: Completion block to asynchronously receive the CursorInfo, or error.
  func cursorInfo(
    _ uri: DocumentURI,
    _ range: Range<Position>,
    additionalParameters appendAdditionalParameters: ((SKDRequestDictionary) -> Void)? = nil
  ) async throws -> (cursorInfo: [CursorInfo], refactorActions: [SemanticRefactorCommand]) {
    let snapshot = try documentManager.latestSnapshot(uri)

    let offsetRange = snapshot.utf8OffsetRange(of: range)

    let keys = self.keys

    let skreq = sourcekitd.dictionary([
      keys.request: requests.cursorInfo,
      keys.cancelOnSubsequentRequest: 0,
      keys.offset: offsetRange.lowerBound,
      keys.length: offsetRange.upperBound != offsetRange.lowerBound ? offsetRange.count : nil,
      keys.sourceFile: snapshot.uri.pseudoPath,
      keys.compilerArgs: await self.buildSettings(for: uri)?.compilerArgs as [SKDRequestValue]?,
    ])

    appendAdditionalParameters?(skreq)

    let dict = try await sendSourcekitdRequest(skreq, fileContents: snapshot.text)

    var cursorInfoResults: [CursorInfo] = []
    if let cursorInfo = CursorInfo(dict, sourcekitd: sourcekitd) {
      cursorInfoResults.append(cursorInfo)
    }
    cursorInfoResults += dict[keys.secondarySymbols]?.compactMap { CursorInfo($0, sourcekitd: sourcekitd) } ?? []
    let refactorActions =
      [SemanticRefactorCommand](
        array: dict[keys.refactorActions],
        range: range,
        textDocument: TextDocumentIdentifier(uri),
        keys,
        self.sourcekitd.api
      ) ?? []
    return (cursorInfoResults, refactorActions)
  }
}
