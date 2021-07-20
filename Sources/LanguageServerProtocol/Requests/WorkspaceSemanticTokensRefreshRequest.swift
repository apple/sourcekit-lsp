//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

/// Sent from the server to the client. Servers can use this to ask clients to
/// refresh semantic tokens for editors for which this server provides semantic
/// tokens, useful in cases of project wide configuration changes.
public struct WorkspaceSemanticTokensRefreshRequest: RequestType, Hashable {
  public static let method: String = "workspace/semanticTokens/refresh"
  public typealias Response = VoidResponse

  public init() {}
}
