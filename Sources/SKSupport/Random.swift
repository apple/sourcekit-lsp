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

/// A linear congruential generator with user-specified seed value. Useful for generating a predictable "random" number sequence.
public struct SimpleLCG: RandomNumberGenerator {

      var state: UInt64

      public init(seed: UInt64) { state = seed }

      public mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005
                  &+ 1_442_695_040_888_963_407
            return state
      }
}
