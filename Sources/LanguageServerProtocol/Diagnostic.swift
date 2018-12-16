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

/// The serverity level of a Diagnostic, between hint and error.
public enum DiagnosticSeverity: Int, Codable, Hashable {
  case error = 1
  case warning = 2
  case information = 3
  case hint = 4
}

/// A unique diagnostic code, which may be used identifier the diagnostic in e.g. documentation.
public enum DiagnosticCode: Hashable {
  case number(Int)
  case string(String)
}

/// A diagnostic message such a compiler error or warning.
public struct Diagnostic: Codable, Hashable {

  /// The primary position/range of the diagnostic.
  public var range: PositionRange

  /// Whether this is a warning, error, etc.
  public var severity: DiagnosticSeverity?

  /// The "code" of the diagnostice, which might be a number or string, typically providing a unique
  /// way to reference the diagnostic in e.g. documentation.
  public var code: DiagnosticCode?

  /// A human-readable description of the source of this diagnostic, e.g. "sourcekitd"
  public var source: String?

  /// The diagnostic message.
  public var message: String

  /// Related diagnostic notes.
  public var relatedInformation: [DiagnosticRelatedInformation]?

  public var fixits: [DiagnosticFixit]?

  public init(range: Range<Position>, severity: DiagnosticSeverity?, code: DiagnosticCode? = nil, source: String?, message: String, relatedInformation: [DiagnosticRelatedInformation]? = nil, diagnosticFixits: [DiagnosticFixit]? = nil) {
    self.range = range
    self.severity = severity
    self.code = code
    self.source = source
    self.message = message
    self.relatedInformation = relatedInformation
    self.fixits = diagnosticFixits
  }
}

/// A 'note' diagnostic attached to a primary diagnostic that provides additional information.
public struct DiagnosticRelatedInformation: Codable, Hashable {

  public var location: Position

  public var message: String

  public init(location: Position, message: String) {
    self.location = location
    self.message = message
  }
}

/// A code suggestion that can be automatically applied to fix a compile error.
public struct DiagnosticFixit: Codable, Hashable {

  public var range: Range<Position>

  public var fixit: String

  public init(range: Range<Position>, fixit: String) {
    self.range = range
    self.fixit = fixit
  }
}

extension DiagnosticCode: Codable {
  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer()
    if let intValue = try? value.decode(Int.self) {
      self = .number(intValue)
    } else if let strValue = try? value.decode(String.self) {
      self = .string(strValue)
    } else {
      throw MessageDecodingError.invalidRequest("could not decode diagnostic code")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    }
  }
}

extension DiagnosticCode: CustomStringConvertible {
  public var description: String {
    switch self {
    case .number(let n): return String(n)
    case .string(let s): return "\"\(s)\""
    }
  }
}
