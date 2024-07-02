//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import LSPLogging
import LanguageServerProtocol
import SKSupport
import SourceKitD

struct GeneratedInterfaceInfo {
  var contents: String
}

extension SwiftLanguageService {
  public func openGeneratedInterface(
    _ request: OpenGeneratedInterfaceRequest
  ) async throws -> GeneratedInterfaceDetails? {
    let name = request.name
    let symbol = request.symbolUSR
    let interfaceFilePath = self.generatedInterfacesPath.appendingPathComponent("\(name).swiftinterface")
    let interfaceDocURI = DocumentURI(interfaceFilePath)
    // has interface already been generated
    if let snapshot = try? self.documentManager.latestSnapshot(interfaceDocURI) {
      return await self.generatedInterfaceDetails(
        request: request,
        uri: interfaceDocURI,
        snapshot: snapshot,
        symbol: symbol
      )
    } else {
      let interfaceInfo = try await self.generatedInterfaceInfo(request: request, interfaceURI: interfaceDocURI)
      try interfaceInfo.contents.write(to: interfaceFilePath, atomically: true, encoding: String.Encoding.utf8)
      let snapshot = DocumentSnapshot(
        uri: interfaceDocURI,
        language: .swift,
        version: 0,
        lineTable: LineTable(interfaceInfo.contents)
      )
      let result = await self.generatedInterfaceDetails(
        request: request,
        uri: interfaceDocURI,
        snapshot: snapshot,
        symbol: symbol
      )
      _ = await orLog("Closing generated interface") {
        try await sendSourcekitdRequest(closeDocumentSourcekitdRequest(uri: interfaceDocURI), fileContents: nil)
      }
      return result
    }
  }

  /// Open the Swift interface for a module.
  ///
  /// - Parameters:
  ///   - request: The OpenGeneratedInterfaceRequest.
  ///   - interfaceURI: The file where the generated interface should be written.
  ///
  /// - Important: This opens a document with name `interfaceURI.pseudoPath` in sourcekitd. The caller is responsible
  ///   for ensuring that the document will eventually get closed in sourcekitd again.
  private func generatedInterfaceInfo(
    request: OpenGeneratedInterfaceRequest,
    interfaceURI: DocumentURI
  ) async throws -> GeneratedInterfaceInfo {
    let keys = self.keys
    let skreq = sourcekitd.dictionary([
      keys.request: requests.editorOpenInterface,
      keys.moduleName: request.moduleName,
      keys.groupName: request.groupName,
      keys.name: interfaceURI.pseudoPath,
      keys.synthesizedExtension: 1,
      keys.compilerArgs: await self.buildSettings(for: request.textDocument.uri)?.compilerArgs as [SKDRequestValue]?,
    ])

    let dict = try await sendSourcekitdRequest(skreq, fileContents: nil)
    return GeneratedInterfaceInfo(contents: dict[keys.sourceText] ?? "")
  }

  private func generatedInterfaceDetails(
    request: OpenGeneratedInterfaceRequest,
    uri: DocumentURI,
    snapshot: DocumentSnapshot,
    symbol: String?
  ) async -> GeneratedInterfaceDetails {
    do {
      guard let symbol = symbol else {
        return GeneratedInterfaceDetails(uri: uri, position: nil)
      }
      let keys = self.keys
      let skreq = sourcekitd.dictionary([
        keys.request: requests.editorFindUSR,
        keys.sourceFile: uri.pseudoPath,
        keys.usr: symbol,
      ])

      let dict = try await sendSourcekitdRequest(skreq, fileContents: snapshot.text)
      if let offset: Int = dict[keys.offset] {
        return GeneratedInterfaceDetails(uri: uri, position: snapshot.positionOf(utf8Offset: offset))
      } else {
        return GeneratedInterfaceDetails(uri: uri, position: nil)
      }
    } catch {
      return GeneratedInterfaceDetails(uri: uri, position: nil)
    }
  }
}
