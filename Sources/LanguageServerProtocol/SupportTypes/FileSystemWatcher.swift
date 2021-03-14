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

/// Defines a watcher interested in specific file system change events.
public struct FileSystemWatcher: Codable, Hashable {
  /// The glob pattern to watch.
  public var globPattern: String

  /// The kind of events of interest. If omitted it defaults to
  /// WatchKind.create | WatchKind.change | WatchKind.delete.
  public var kind: WatchKind?

  public init(globPattern: String, kind: WatchKind? = nil) {
    self.globPattern = globPattern
    self.kind = kind
  }
}

/// The type of file event a watcher is interested in.
///
/// In LSP, this is an integer, so we don't use a closed set.
public struct WatchKind: OptionSet, Codable, Hashable {
  public var rawValue: Int

  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  public static let create: FileChangeType = FileChangeType(rawValue: 1)
  public static let change: FileChangeType = FileChangeType(rawValue: 2)
  public static let delete: FileChangeType = FileChangeType(rawValue: 4)
}