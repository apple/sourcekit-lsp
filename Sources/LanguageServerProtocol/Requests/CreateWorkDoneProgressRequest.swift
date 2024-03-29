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

public struct CreateWorkDoneProgressRequest: RequestType {
  public static let method: String = "window/workDoneProgress/create"
  public typealias Response = VoidResponse

  /// The token to be used to report progress.
  public var token: ProgressToken

  public init(token: ProgressToken) {
    self.token = token
  }
}
