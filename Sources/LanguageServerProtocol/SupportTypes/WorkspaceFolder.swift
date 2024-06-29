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

/// Unique identifier for a document.
public struct WorkspaceFolder: ResponseType, Hashable, Codable, Sendable {

  /// A URI that uniquely identifies the workspace.
  public var uri: DocumentURI

  /// The name of the workspace (default: basename of url).
  public var name: String

  public init(uri: DocumentURI, name: String? = nil) {
    self.uri = uri

    self.name = name ?? uri.fileURL?.lastPathComponent ?? "unknown_workspace"

    if self.name.isEmpty {
      self.name = "unknown_workspace"
    }
  }
}
