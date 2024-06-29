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

import struct TSCBasic.AbsolutePath

extension AbsolutePath {
  /// Same as `init(validating:)` but returns `nil` on validation failure instead of throwing.
  public init?(validatingOrNil string: String?) {
    guard let string, let path = try? AbsolutePath(validating: string) else {
      return nil
    }
    self = path
  }

}
