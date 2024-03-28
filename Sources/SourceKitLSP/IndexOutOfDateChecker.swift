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

import Foundation
import IndexStoreDB
import LSPLogging

/// Helper class to check if symbols from the index are up-to-date or if the source file has been modified after it was
/// indexed.
///
/// The checker caches mod dates of source files. It should thus not be long lived. Its intended lifespan is the
/// evaluation of a single request.
struct IndexOutOfDateChecker {
  /// The last modification time of a file. Can also represent the fact that the file does not exist.
  private enum ModificationTime {
    case fileDoesNotExist
    case date(Date)
  }

  private enum Error: Swift.Error, CustomStringConvertible {
    case fileAttributesDontHaveModificationDate

    var description: String {
      switch self {
      case .fileAttributesDontHaveModificationDate:
        return "File attributes don't contain a modification date"
      }
    }
  }

  /// File paths to modification times that have already been computed.
  private var modTimeCache: [String: ModificationTime] = [:]

  private func modificationDateUncached(of path: String) throws -> ModificationTime {
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: path)
      guard let modificationDate = attributes[FileAttributeKey.modificationDate] as? Date else {
        throw Error.fileAttributesDontHaveModificationDate
      }
      return .date(modificationDate)
    } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
      return .fileDoesNotExist
    }
  }

  private mutating func modificationDate(of path: String) throws -> ModificationTime {
    if let cached = modTimeCache[path] {
      return cached
    }
    let modTime = try modificationDateUncached(of: path)
    modTimeCache[path] = modTime
    return modTime
  }

  /// Returns `true` if the source file for the given symbol location exists and has not been modified after it has been
  /// indexed.
  mutating func isUpToDate(_ symbolLocation: SymbolLocation) -> Bool {
    do {
      let sourceFileModificationDate = try modificationDate(of: symbolLocation.path)
      switch sourceFileModificationDate {
      case .fileDoesNotExist:
        return false
      case .date(let sourceFileModificationDate):
        return sourceFileModificationDate <= symbolLocation.timestamp
      }
    } catch {
      logger.fault("Unable to determine if SymbolLocation is up-to-date: \(error.forLogging)")
      return true
    }
  }

  /// Return `true` if a unit file has been indexed for the given file path after its last modification date.
  ///
  /// This means that at least a single build configuration of this file has been indexed since its last modification.
  mutating func indexHasUpToDateUnit(for filePath: String, index: IndexStoreDB) -> Bool {
    guard let lastUnitDate = index.dateOfLatestUnitFor(filePath: filePath) else {
      return false
    }
    do {
      let sourceModificationDate = try modificationDate(of: filePath)
      switch sourceModificationDate {
      case .fileDoesNotExist:
        return false
      case .date(let sourceModificationDate):
        return sourceModificationDate <= lastUnitDate
      }
    } catch {
      logger.fault("Unable to determine if source file has up-to-date unit: \(error.forLogging)")
      return true
    }
  }
}
