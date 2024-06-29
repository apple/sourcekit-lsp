//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

/// Poll the index for unit changes and wait for them to be registered.
/// **LSP Extension, For Testing**.
public struct PollIndexRequest: RequestType {
  public static let method: String = "workspace/_pollIndex"
  public typealias Response = VoidResponse

  public init() {}
}
