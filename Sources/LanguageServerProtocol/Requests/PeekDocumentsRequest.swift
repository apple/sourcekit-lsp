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

/// Request from the server to the client to show the given documents in a "peeked" editor **(LSP Extension)**
///
/// This request is handled by the client to show the given documents in a
/// "peeked" editor (i.e. inline with / inside the editor canvas). This is
/// similar to VS Code's built-in "editor.action.peekLocations" command.
///
/// - Parameters:
///   - uri: The DocumentURI of the text document in which to show the "peeked" editor
///   - position: The position in the given text document in which to show the "peeked editor"
///   - locations: The DocumentURIs of documents to appear inside the "peeked" editor
///
/// - Returns: `PeekDocumentsResponse` which indicates the `success` of the request.
///
/// ### LSP Extension
///
/// This request is an extension to LSP supported by SourceKit-LSP.
/// It requires the experimental client capability `"workspace/peekDocuments"` to use.
/// It also needs the client to handle the request and present the "peeked" editor.
public struct PeekDocumentsRequest: RequestType {
  public static let method: String = "workspace/peekDocuments"
  public typealias Response = PeekDocumentsResponse

  public var uri: DocumentURI
  public var position: Position
  public var locations: [DocumentURI]

  public init(
    uri: DocumentURI,
    position: Position,
    locations: [DocumentURI]
  ) {
    self.uri = uri
    self.position = position
    self.locations = locations
  }
}

/// Response to indicate the `success` of the `PeekDocumentsRequest`
public struct PeekDocumentsResponse: ResponseType {
  public var success: Bool

  public init(success: Bool) {
    self.success = success
  }
}
