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

import SourceKitD
import LanguageServerProtocol
import LSPLogging

/// A ranged token in the document used for syntax highlighting.
public struct SyntaxHighlightingToken: Hashable {
  public var start: Position
  public var length: Int
  public var kind: Kind
  public var modifiers: Modifiers

  /// The end of a token. Note that this requires the token to be
  /// on a single line, which is the case for all tokens emitted
  /// by parseTokens, however.
  public var sameLineEnd: Position {
    Position(line: start.line, utf16index: start.utf16index + length)
  }
  public var sameLineRange: Range<Position> {
    start..<sameLineEnd
  }

  public init(
    start: Position,
    length: Int,
    kind: Kind,
    modifiers: Modifiers = []
  ) {
    self.start = start
    self.length = length
    self.kind = kind
    self.modifiers = modifiers
  }

  /// Splits a potentially multi-line token to multiple single-line tokens.
  public func splitToSingleLineTokens(in snapshot: DocumentSnapshot) -> [Self] {
    guard let startIndex = snapshot.index(of: start) else {
      fatalError("Token \(self) begins outside of the document")
    }

    let endIndex = snapshot.text.index(startIndex, offsetBy: length)
    let text = snapshot.text[startIndex..<endIndex]
    let lines = text.split(separator: "\n")

    return lines
      .enumerated()
      .map { (i, content) in
        Self(
          start: Position(
            line: start.line + i,
            utf16index: i == 0 ? start.utf16index : 0
          ),
          length: content.count,
          kind: kind,
          modifiers: modifiers
        )
      }
  }

  /// The token type. Represented using an int to make the conversion to
  /// LSP tokens efficient. The order of this enum does not have to be
  /// stable, since we provide a `SemanticTokensLegend` during initialization.
  /// It is, however, important that the values are numbered from 0 due to
  /// the way the kinds are encoded in LSP.
  /// Also note that we intentionally use an enum here instead of e.g. a
  /// `RawRepresentable` struct, since we want to have a conversion to
  /// strings for known kinds and since these kinds are only provided by the
  /// server, i.e. there is no need to handle cases where unknown kinds
  /// have to be decoded.
  public enum Kind: UInt32, CaseIterable, Hashable {
    case namespace = 0
    case type
    case `class`
    case `enum`
    case interface
    case `struct`
    case typeParameter
    case parameter
    case variable
    case property
    case enumMember
    case event
    case function
    case method
    case macro
    case keyword
    case modifier
    case comment
    case string
    case number
    case regexp
    case `operator`

    /// The name of the token type used by LSP.
    var lspName: String {
      switch self {
      case .namespace: return "namespace"
      case .type: return "type"
      case .class: return "class"
      case .enum: return "enum"
      case .interface: return "interface"
      case .struct: return "struct"
      case .typeParameter: return "typeParameter"
      case .parameter: return "parameter"
      case .variable: return "variable"
      case .property: return "property"
      case .enumMember: return "enumMember"
      case .event: return "event"
      case .function: return "function"
      case .method: return "method"
      case .macro: return "macro"
      case .keyword: return "keyword"
      case .modifier: return "modifier"
      case .comment: return "comment"
      case .string: return "string"
      case .number: return "number"
      case .regexp: return "regexp"
      case .operator: return "operator"
      }
    }

    /// **Public for testing**
    public var _lspName: String {
      lspName
    }
  }

  /// Additional metadata about a token. Similar to `Kind`, the raw
  /// values do not actually have to be stable, do note however that
  /// the bit indices should be numbered starting at 0 and that
  /// the ordering should correspond to `allCases`.
  public struct Modifiers: OptionSet, CaseIterable, Hashable {
    public static let declaration = Self(rawValue: 1 << 0)
    public static let definition = Self(rawValue: 1 << 1)
    public static let readonly = Self(rawValue: 1 << 2)
    public static let `static` = Self(rawValue: 1 << 3)
    public static let deprecated = Self(rawValue: 1 << 4)
    public static let abstract = Self(rawValue: 1 << 5)
    public static let async = Self(rawValue: 1 << 6)
    public static let modification = Self(rawValue: 1 << 7)
    public static let documentation = Self(rawValue: 1 << 8)
    public static let defaultLibrary = Self(rawValue: 1 << 9)

    /// All available modifiers, in ascending order of the bit index
    /// they are represented with (starting at the rightmost bit).
    public static let allCases: [Self] = [
      .declaration,
      .definition,
      .readonly,
      .static,
      .deprecated,
      .abstract,
      .async,
      .modification,
      .documentation,
      .defaultLibrary,
    ]

    public let rawValue: UInt32

    /// The name of the modifier used by LSP, if this
    /// is a single modifier. Note that every modifier
    /// in `allCases` must have an associated `lspName`.
    var lspName: String? {
      switch self {
      case .declaration: return "declaration"
      case .definition: return "definition"
      case .readonly: return "readonly"
      case .static: return "static"
      case .deprecated: return "deprecated"
      case .abstract: return "abstract"
      case .async: return "async"
      case .modification: return "modification"
      case .documentation: return "documentation"
      case .defaultLibrary: return "defaultLibrary"
      default: return nil
      }
    }

    /// **Public for testing**
    public var _lspName: String? {
      lspName
    }

    public init(rawValue: UInt32) {
      self.rawValue = rawValue
    }
  }
}

extension Array where Element == SyntaxHighlightingToken {
  /// The LSP representation of syntax highlighting tokens. Note that this
  /// requires the tokens in this array to be sorted.
  public var lspEncoded: [UInt32] {
    var previous = Position(line: 0, utf16index: 0)
    var rawTokens: [UInt32] = []
    rawTokens.reserveCapacity(count * 5)

    for token in self {
      let lineDelta = token.start.line - previous.line
      let charDelta = token.start.utf16index - (
        // The character delta is relative to the previous token's start
        // only if the token is on the previous token's line.
        previous.line == token.start.line ? previous.utf16index : 0
      )

      // We assert that the tokens are actually sorted
      assert(lineDelta >= 0)
      assert(charDelta >= 0)

      previous = token.start
      rawTokens += [
        UInt32(lineDelta),
        UInt32(charDelta),
        UInt32(token.length),
        token.kind.rawValue,
        token.modifiers.rawValue
      ]
    }

    return rawTokens
  }

  /// Merges the tokens in this array into a new token array,
  /// preferring the given array's tokens if duplicate ranges are
  /// found.
  public func mergingTokens(with other: [SyntaxHighlightingToken]) -> [SyntaxHighlightingToken] {
    let otherRanges = Set(other.map(\.sameLineRange))
    return filter { !otherRanges.contains($0.sameLineRange) } + other
  }
}

/// Parses tokens from sourcekitd response dictionaries.
struct SyntaxHighlightingTokenParser {
  private let sourcekitd: SourceKitD
  /// Use `keys.nameoffset` and `keys.namelength` instead of `keys.offset`
  /// and `keys.length`. This is useful in AST structures provided by
  /// sourcekitd, since these contain both a name range and a normal range,
  /// where the latter refers to the entire node (e.g. the entire function
  /// declaration).
  private let useName: Bool

  init(sourcekitd: SourceKitD, useName: Bool = false) {
    self.sourcekitd = sourcekitd
    self.useName = useName
  }

  func parseTokens(_ response: SKDResponseDictionary, in snapshot: DocumentSnapshot) -> [SyntaxHighlightingToken] {
    let keys = sourcekitd.keys
    var tokens: [SyntaxHighlightingToken] = []

    if let offset: Int = useName ? response[keys.nameoffset] : response[keys.offset],
       var length: Int = useName ? response[keys.namelength] : response[keys.length],
       let start: Position = snapshot.positionOf(utf8Offset: offset),
       let skKind: sourcekitd_uid_t = response[keys.kind],
       let (kind, modifiers) = parseKindAndModifiers(skKind) {

      // We treat function declaration and enum member name tokens as a special
      // case, e.g. SourceKit returns `f(x: Int, y: Int)` as a name instead of just `f`.
      if useName && [.function, .method, .enumMember].contains(kind) && modifiers.contains(.declaration),
         let name: String = response[keys.name],
         name.contains("("),
         let funcNameLength: Int = name.split(separator: "(").first?.utf16.count {
        length = funcNameLength
      }

      // If the name is escaped in backticks, we need to add two characters to the
      // length for the backticks.
      if modifiers.contains(.declaration),
         let index = snapshot.indexOf(utf8Offset: offset), snapshot.text[index] == "`" {
        length += 2
      }

      let multiLineToken = SyntaxHighlightingToken(
        start: start,
        length: length,
        kind: kind,
        modifiers: modifiers
      )

      tokens += multiLineToken.splitToSingleLineTokens(in: snapshot)
    }

    if let substructure: SKDResponseArray = response[keys.substructure] {
      tokens += parseTokens(substructure, in: snapshot)
    }

    return tokens
  }

  func parseTokens(_ response: SKDResponseArray, in snapshot: DocumentSnapshot) -> [SyntaxHighlightingToken] {
    var result: [SyntaxHighlightingToken] = []
    response.forEach { (_, value) in
      result += parseTokens(value, in: snapshot)
      return true
    }
    return result
  }

  private func parseKindAndModifiers(_ uid: sourcekitd_uid_t) -> (SyntaxHighlightingToken.Kind, SyntaxHighlightingToken.Modifiers)? {
    let api = sourcekitd.api
    let values = sourcekitd.values
    switch uid {
    case values.kind_keyword,
         values.syntaxtype_keyword:
      return (.keyword, [])
    case values.syntaxtype_attribute_builtin:
      return (.modifier, [])
    case values.decl_module:
      return (.namespace, [])
    case values.decl_class:
      return (.class, [.declaration])
    case values.ref_class:
      return (.class, [])
    case values.decl_struct:
      return (.struct, [.declaration])
    case values.ref_struct:
      return (.struct, [])
    case values.decl_enum:
      return (.enum, [.declaration])
    case values.ref_enum:
      return (.enum, [])
    case values.decl_enumelement:
      return (.enumMember, [.declaration])
    case values.ref_enumelement:
      return (.enumMember, [])
    case values.decl_protocol:
      return (.interface, [.declaration])
    case values.ref_protocol:
      return (.interface, [])
    case values.decl_associatedtype,
         values.decl_typealias,
         values.decl_generic_type_param:
      return (.typeParameter, [.declaration])
    case values.ref_associatedtype,
         values.ref_typealias,
         values.ref_generic_type_param:
      return (.typeParameter, [])
    case values.decl_function_free:
      return (.function, [.declaration])
    case values.decl_function_method_static,
         values.decl_function_method_class,
         values.decl_function_constructor:
      return (.method, [.declaration, .static])
    case values.decl_function_method_instance,
         values.decl_function_destructor,
         values.decl_function_subscript:
      return (.method, [.declaration])
    case values.ref_function_free:
      return (.function, [])
    case values.ref_function_method_static,
         values.ref_function_method_class,
         values.ref_function_constructor:
      return (.method, [.static])
    case values.ref_function_method_instance,
         values.ref_function_destructor,
         values.ref_function_subscript:
      return (.method, [])
    case values.decl_function_operator_prefix,
         values.decl_function_operator_postfix,
         values.decl_function_operator_infix:
      return (.operator, [.declaration])
    case values.ref_function_operator_prefix,
         values.ref_function_operator_postfix,
         values.ref_function_operator_infix:
      return (.operator, [])
    case values.decl_var_static,
         values.decl_var_class,
         values.decl_var_instance:
      return (.property, [.declaration])
    case values.decl_var_parameter:
      // SourceKit seems to use these to refer to parameter labels,
      // therefore we don't use .parameter here (which LSP clients like
      // VSCode seem to interpret as variable identifiers, however
      // causing a 'wrong highlighting' e.g. of `x` in `f(x y: Int) {}`)
      return (.function, [.declaration])
    case values.ref_var_static,
         values.ref_var_class,
         values.ref_var_instance:
      return (.property, [])
    case values.decl_var_local,
         values.decl_var_global:
      return (.variable, [.declaration])
    case values.ref_var_local,
         values.ref_var_global:
      return (.variable, [])
    case values.syntaxtype_comment,
         values.syntaxtype_comment_marker,
         values.syntaxtype_comment_url:
      return (.comment, [])
    case values.syntaxtype_doccomment,
         values.syntaxtype_doccomment_field:
      return (.comment, [.documentation])
    case values.syntaxtype_type_identifier:
      return (.type, [])
    case values.syntaxtype_number:
      return (.number, [])
    case values.syntaxtype_string:
      return (.string, [])
    default:
      let ignoredKinds: Set<sourcekitd_uid_t> = [
        values.syntaxtype_identifier,
        values.syntaxtype_string_interpolation_anchor,
      ]
      if !ignoredKinds.contains(uid) {
        let name = api.uid_get_string_ptr(uid).map(String.init(cString:))
        log("Unknown token kind: \(name ?? "?")", level: .debug)
      }
      return nil
    }
  }
}
