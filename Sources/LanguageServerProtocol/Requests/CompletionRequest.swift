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

/// Request for code-completion items at the given document location.
///
/// The server may - or may not - filter and sort the results before returning them. If the server
/// performs server-side filtering, it should set the `isIncomplete` flag on the result. However,
/// since there are no particular rules specified for server-side filtering, the client likely will
/// want to perform its own filtering as well.
///
/// Servers that provide document highlights should set the `completionProvider` server capability.
///
/// - Parameters:
///   - textDocument: The document to perform completion in.
///   - position: The location to perform completion at.
///   - context: Optional code-completion context.
///
/// - Returns: A list of completion items to complete the code at the given position.
public struct CompletionRequest: TextDocumentRequest, Hashable {
  public static let method: String = "textDocument/completion"
  public typealias Response = CompletionList

  public var textDocument: TextDocumentIdentifier

  public var position: Position

  public var context: CompletionContext?

  public init(
    textDocument: TextDocumentIdentifier,
    position: Position,
    context: CompletionContext? = nil
  ) {
    self.textDocument = textDocument
    self.position = position
    self.context = context
  }
}

/// How a completion was triggered
public struct CompletionTriggerKind: RawRepresentable, Codable, Hashable, Sendable {
  /// Completion was triggered by typing an identifier (24x7 code complete), manual invocation (e.g Ctrl+Space) or via API.
  public static let invoked = CompletionTriggerKind(rawValue: 1)

  /// Completion was triggered by a trigger character specified by the `triggerCharacters` properties of the `CompletionRegistrationOptions`.
  public static let triggerCharacter = CompletionTriggerKind(rawValue: 2)

  /// Completion was re-triggered as the current completion list is incomplete.
  public static let triggerFromIncompleteCompletions = CompletionTriggerKind(rawValue: 3)

  public let rawValue: Int
  public init(rawValue: Int) {
    self.rawValue = rawValue
  }
}

/// Contains additional information about the context in which a completion request is triggered.
public struct CompletionContext: Codable, Hashable, Sendable {
  /// How the completion was triggered.
  public var triggerKind: CompletionTriggerKind

  /// The trigger character (a single character) that has trigger code complete. Is undefined if `triggerKind !== CompletionTriggerKind.TriggerCharacter`
  public var triggerCharacter: String?

  public init(triggerKind: CompletionTriggerKind, triggerCharacter: String? = nil) {
    self.triggerKind = triggerKind
    self.triggerCharacter = triggerCharacter
  }
}

/// List of completion items. If this list has been filtered already, the `isIncomplete` flag
/// indicates that the client should re-query code-completions if the filter text changes.
public struct CompletionList: ResponseType, Hashable {
  public struct InsertReplaceRanges: Codable, Hashable, Sendable {
    @CustomCodable<PositionRange>
    var insert: Range<Position>

    @CustomCodable<PositionRange>
    var replace: Range<Position>

    public init(insert: Range<Position>, replace: Range<Position>) {
      self.insert = insert
      self.replace = replace
    }
  }

  public enum ItemDefaultsEditRange: Codable, Hashable, Sendable {
    case range(Range<Position>)
    case insertReplaceRanges(InsertReplaceRanges)

    public init(from decoder: Decoder) throws {
      if let range = try? PositionRange(from: decoder).wrappedValue {
        self = .range(range)
      } else if let insertReplaceRange = try? InsertReplaceRanges(from: decoder) {
        self = .insertReplaceRanges(insertReplaceRange)
      } else {
        let context = DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "Expected Range or InsertReplaceRanges"
        )
        throw DecodingError.dataCorrupted(context)
      }
    }

    public func encode(to encoder: Encoder) throws {
      switch self {
      case .range(let range):
        try PositionRange(wrappedValue: range).encode(to: encoder)
      case .insertReplaceRanges(let insertReplaceRanges):
        try insertReplaceRanges.encode(to: encoder)
      }
    }
  }

  public struct ItemDefaults: Codable, Hashable, Sendable {
    /// A default commit character set.
    public var commitCharacters: [String]?

    /// A default edit range
    public var editRange: ItemDefaultsEditRange?

    /// A default insert text format
    public var insertTextFormat: InsertTextFormat?

    /// A default insert text mode
    public var insertTextMode: InsertTextMode?

    /// A default data value.
    public var data: LSPAny?

    public init(
      commitCharacters: [String]? = nil,
      editRange: ItemDefaultsEditRange? = nil,
      insertTextFormat: InsertTextFormat? = nil,
      insertTextMode: InsertTextMode? = nil,
      data: LSPAny? = nil
    ) {
      self.commitCharacters = commitCharacters
      self.editRange = editRange
      self.insertTextFormat = insertTextFormat
      self.insertTextMode = insertTextMode
      self.data = data
    }
  }

  /// Whether the list of completions is "complete" or not.
  ///
  /// When this value is `true`, the client should re-query the server when doing further filtering.
  public var isIncomplete: Bool

  /// In many cases the items of an actual completion result share the same
  /// value for properties like `commitCharacters` or the range of a text
  /// edit. A completion list can therefore define item defaults which will
  /// be used if a completion item itself doesn't specify the value.
  ///
  /// If a completion list specifies a default value and a completion item
  /// also specifies a corresponding value the one from the item is used.
  ///
  /// Servers are only allowed to return default values if the client
  /// signals support for this via the `completionList.itemDefaults`
  /// capability.
  public var itemDefaults: ItemDefaults?

  /// The resulting completions.
  public var items: [CompletionItem]

  public init(isIncomplete: Bool, itemDefaults: ItemDefaults? = nil, items: [CompletionItem]) {
    self.isIncomplete = isIncomplete
    self.itemDefaults = itemDefaults
    self.items = items
  }

  public init(from decoder: Decoder) throws {
    // Try decoding as CompletionList
    do {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.isIncomplete = try container.decode(Bool.self, forKey: .isIncomplete)
      self.items = try container.decode([CompletionItem].self, forKey: .items)
      return
    } catch {}

    // Try decoding as [CompletionItem]
    do {
      self.items = try [CompletionItem](from: decoder)
      self.isIncomplete = false
      return
    } catch {}

    let context = DecodingError.Context(
      codingPath: decoder.codingPath,
      debugDescription: "Expected CompletionList or [CompletionItem]"
    )
    throw DecodingError.dataCorrupted(context)
  }
}
