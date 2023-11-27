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

import Foundation

/// Protocol for capability registration options, which must be encodable to
/// `LSPAny` so they can be included in a `Registration`.
public protocol RegistrationOptions: Hashable {
  func encodeIntoLSPAny(dict: inout [String: LSPAny])
}

fileprivate func encode(strings: [String]) -> LSPAny {
  var values = [LSPAny]()
  values.reserveCapacity(strings.count)
  for str in strings {
    values.append(.string(str))
  }
  return .array(values)
}

/// General text document registration options.
public struct TextDocumentRegistrationOptions: RegistrationOptions, Hashable {
  /// A document selector to identify the scope of the registration. If not set,
  /// the document selector provided on the client side will be used.
  public var documentSelector: DocumentSelector?

  public init(documentSelector: DocumentSelector? = nil) {
    self.documentSelector = documentSelector
  }

  public init(fromLSPAny value: LSPAny) {
    guard case let .dictionary(dict) = value else {
      return
    }

    var documentSelector: DocumentSelector?
    if let value = dict["documentSelector"] {
      documentSelector = DocumentSelector(fromLSPArray: value)
    }

    self.documentSelector = documentSelector
  }

  public func encodeIntoLSPAny(dict: inout [String: LSPAny]) {
    guard let documentSelector = documentSelector else { return }
    dict["documentSelector"] = documentSelector.encodeToLSPAny()
  }
}

/// Protocol for a type which structurally represents`TextDocumentRegistrationOptions`.
public protocol TextDocumentRegistrationOptionsProtocol {
  var textDocumentRegistrationOptions: TextDocumentRegistrationOptions { get }
}

/// Code completiion registration options.
public struct CompletionRegistrationOptions: RegistrationOptions, TextDocumentRegistrationOptionsProtocol, Hashable {
  public var textDocumentRegistrationOptions: TextDocumentRegistrationOptions
  public var completionOptions: CompletionOptions

  public init(documentSelector: DocumentSelector? = nil, completionOptions: CompletionOptions) {
    self.textDocumentRegistrationOptions =
      TextDocumentRegistrationOptions(documentSelector: documentSelector)
    self.completionOptions = completionOptions
  }

  public func encodeIntoLSPAny(dict: inout [String: LSPAny]) {
    textDocumentRegistrationOptions.encodeIntoLSPAny(dict: &dict)

    if let resolveProvider = completionOptions.resolveProvider {
      dict["resolveProvider"] = .bool(resolveProvider)
    }
    if let triggerCharacters = completionOptions.triggerCharacters {
      dict["triggerCharacters"] = encode(strings: triggerCharacters)
    }
    if let allCommitCharacters = completionOptions.allCommitCharacters {
      dict["allCommitCharacters"] = encode(strings: allCommitCharacters)
    }
  }
}

/// Folding range registration options.
public struct FoldingRangeRegistrationOptions: RegistrationOptions, TextDocumentRegistrationOptionsProtocol, Hashable {
  public var textDocumentRegistrationOptions: TextDocumentRegistrationOptions
  public var foldingRangeOptions: FoldingRangeOptions

  public init(documentSelector: DocumentSelector? = nil, foldingRangeOptions: FoldingRangeOptions) {
    self.textDocumentRegistrationOptions =
      TextDocumentRegistrationOptions(documentSelector: documentSelector)
    self.foldingRangeOptions = foldingRangeOptions
  }

  public func encodeIntoLSPAny(dict: inout [String: LSPAny]) {
    textDocumentRegistrationOptions.encodeIntoLSPAny(dict: &dict)
    // foldingRangeOptions is currently empty.
  }
}

public struct SemanticTokensRegistrationOptions: RegistrationOptions, TextDocumentRegistrationOptionsProtocol, Hashable
{
  /// Method for registration, which defers from the actual requests' methods
  /// since this registration handles multiple requests.
  public static let method: String = "textDocument/semanticTokens"

  public var textDocumentRegistrationOptions: TextDocumentRegistrationOptions
  public var semanticTokenOptions: SemanticTokensOptions

  public init(documentSelector: DocumentSelector? = nil, semanticTokenOptions: SemanticTokensOptions) {
    self.textDocumentRegistrationOptions =
      TextDocumentRegistrationOptions(documentSelector: documentSelector)
    self.semanticTokenOptions = semanticTokenOptions
  }

  public init?(fromLSPAny value: LSPAny) {
    guard case let .dictionary(dict) = value else {
      return nil
    }

    textDocumentRegistrationOptions = TextDocumentRegistrationOptions(fromLSPAny: value)

    var range: ValueOrBool<SemanticTokensOptions.SemanticTokensRangeOptions>?
    if let rangeLSPAny = dict["range"] {
      switch rangeLSPAny {
      case let .bool(value):
        range = .bool(value)
      case .dictionary:
        range = .value(SemanticTokensOptions.SemanticTokensRangeOptions())
      default:
        break
      }
    }

    var full: ValueOrBool<SemanticTokensOptions.SemanticTokensFullOptions>?
    if let fullLSPAny = dict["full"] {
      switch fullLSPAny {
      case let .bool(value):
        full = .bool(value)
      case let .dictionary(optionsDict):
        var delta: Bool?
        if let value = optionsDict["delta"],
           case let .bool(deltaValue) = value
        {
          delta = deltaValue
        }

        full = .value(SemanticTokensOptions.SemanticTokensFullOptions(delta: delta))
      default:
        break
      }
    }

    guard case let .dictionary(legendDict) = dict["legend"] else {
      return nil
    }

    var tokenTypes: [String] = []
    if case let .array(types) = legendDict["tokenTypes"] {
      tokenTypes = types.compactMap {
        if case let .string(string) = $0 {
          return string
        }
        return nil
      }
    }

    var tokenModifiers: [String] = []
    if case let .array(types) = legendDict["tokenModifiers"] {
      tokenModifiers = types.compactMap {
        if case let .string(string) = $0 {
          return string
        }
        return nil
      }
    }

    let legend = SemanticTokensLegend(
      tokenTypes: tokenTypes,
      tokenModifiers: tokenModifiers
    )

    semanticTokenOptions = SemanticTokensOptions(
      legend: legend,
      range: range,
      full: full
    )
  }

  public func encodeIntoLSPAny(dict: inout [String: LSPAny]) {
    textDocumentRegistrationOptions.encodeIntoLSPAny(dict: &dict)
    let legend = semanticTokenOptions.legend
    dict["legend"] = .dictionary([
      "tokenTypes": encode(strings: legend.tokenTypes),
      "tokenModifiers": encode(strings: legend.tokenModifiers),
    ])
    if let range = semanticTokenOptions.range {
      let encodedRange: LSPAny
      switch range {
      case .bool(let value): encodedRange = .bool(value)
      case .value(_): encodedRange = .dictionary([:])
      }
      dict["range"] = encodedRange
    }
    if let full = semanticTokenOptions.full {
      let encodedFull: LSPAny
      switch full {
      case .bool(let value): encodedFull = .bool(value)
      case .value(let fullOptions):
        var encodedOptions: [String: LSPAny] = [:]
        if let delta = fullOptions.delta {
          encodedOptions["delta"] = .bool(delta)
        }
        encodedFull = .dictionary(encodedOptions)
      }
      dict["full"] = encodedFull
    }
  }
}

public struct InlayHintRegistrationOptions: RegistrationOptions, TextDocumentRegistrationOptionsProtocol, Hashable {
  public var textDocumentRegistrationOptions: TextDocumentRegistrationOptions
  public var inlayHintOptions: InlayHintOptions

  public init(
    documentSelector: DocumentSelector? = nil,
    inlayHintOptions: InlayHintOptions
  ) {
    textDocumentRegistrationOptions = TextDocumentRegistrationOptions(documentSelector: documentSelector)
    self.inlayHintOptions = inlayHintOptions
  }

  public func encodeIntoLSPAny(dict: inout [String: LSPAny]) {
    textDocumentRegistrationOptions.encodeIntoLSPAny(dict: &dict)
    if let resolveProvider = inlayHintOptions.resolveProvider {
      dict["resolveProvider"] = .bool(resolveProvider)
    }
  }
}

/// Describe options to be used when registering for pull diagnostics. Since LSP 3.17.0
public struct DiagnosticRegistrationOptions: RegistrationOptions, TextDocumentRegistrationOptionsProtocol {
  public var textDocumentRegistrationOptions: TextDocumentRegistrationOptions
  public var diagnosticOptions: DiagnosticOptions

  public init(
    documentSelector: DocumentSelector? = nil,
    diagnosticOptions: DiagnosticOptions
  ) {
    textDocumentRegistrationOptions = TextDocumentRegistrationOptions(documentSelector: documentSelector)
    self.diagnosticOptions = diagnosticOptions
  }

  public func encodeIntoLSPAny(dict: inout [String: LSPAny]) {
    textDocumentRegistrationOptions.encodeIntoLSPAny(dict: &dict)
    diagnosticOptions.encodeIntoLSPAny(dict: &dict)
  }
}

/// Describe options to be used when registering for file system change events.
public struct DidChangeWatchedFilesRegistrationOptions: RegistrationOptions {
  /// The watchers to register.
  public var watchers: [FileSystemWatcher]

  public init(watchers: [FileSystemWatcher]) {
    self.watchers = watchers
  }

  public func encodeIntoLSPAny(dict: inout [String: LSPAny]) {
    dict["watchers"] = watchers.encodeToLSPAny()
  }
}

/// Execute command registration options.
public struct ExecuteCommandRegistrationOptions: RegistrationOptions {
  /// The commands to be executed on this server.
  public var commands: [String]

  public init(commands: [String]) {
    self.commands = commands
  }

  public func encodeIntoLSPAny(dict: inout [String: LSPAny]) {
    dict["commands"] = encode(strings: commands)
  }
}
