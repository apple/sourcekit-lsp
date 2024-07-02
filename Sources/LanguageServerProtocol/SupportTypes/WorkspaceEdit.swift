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

/// A workspace edit represents changes to many resources managed in the workspace.
public struct WorkspaceEdit: Hashable, ResponseType, Sendable {

  /// The edits to be applied to existing resources.
  public var changes: [DocumentURI: [TextEdit]]?

  public var documentChanges: [WorkspaceEditDocumentChange]?

  /// A map of change annotations that can be referenced in
  /// `AnnotatedTextEdit`s or create, rename and delete file / folder
  /// operations.
  ///
  /// Whether clients honor this property depends on the client capability
  /// `workspace.changeAnnotationSupport`.
  public var changeAnnotations: [ChangeAnnotationIdentifier: ChangeAnnotation]?

  public init(
    changes: [DocumentURI: [TextEdit]]? = nil,
    documentChanges: [WorkspaceEditDocumentChange]? = nil,
    changeAnnotation: [ChangeAnnotationIdentifier: ChangeAnnotation]? = nil
  ) {
    self.changes = changes
    self.documentChanges = documentChanges
    self.changeAnnotations = changeAnnotation
  }
}

// Workaround for Codable not correctly encoding dictionaries whose keys aren't strings.
extension WorkspaceEdit: Codable {
  private enum CodingKeys: String, CodingKey {
    case changes
    case documentChanges
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let changesDict = try container.decodeIfPresent([String: [TextEdit]].self, forKey: .changes) {
      var changes = [DocumentURI: [TextEdit]]()
      for change in changesDict {
        let uri = try DocumentURI(string: change.key)
        changes[uri] = change.value
      }
      self.changes = changes
    } else {
      self.changes = nil
    }
    self.documentChanges = try container.decodeIfPresent([WorkspaceEditDocumentChange].self, forKey: .documentChanges)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    if let changes = changes {
      var stringDictionary = [String: [TextEdit]]()
      for (key, value) in changes {
        stringDictionary[key.stringValue] = value
      }
      try container.encodeIfPresent(stringDictionary, forKey: .changes)
    }
    try container.encodeIfPresent(documentChanges, forKey: .documentChanges)
  }
}

public enum WorkspaceEditDocumentChange: Codable, Hashable, Sendable {
  case textDocumentEdit(TextDocumentEdit)
  case createFile(CreateFile)
  case renameFile(RenameFile)
  case deleteFile(DeleteFile)

  public init(from decoder: Decoder) throws {
    if let edit = try? TextDocumentEdit(from: decoder) {
      self = .textDocumentEdit(edit)
    } else if let createFile = try? CreateFile(from: decoder) {
      self = .createFile(createFile)
    } else if let renameFile = try? RenameFile(from: decoder) {
      self = .renameFile(renameFile)
    } else if let deleteFile = try? DeleteFile(from: decoder) {
      self = .deleteFile(deleteFile)
    } else {
      let context = DecodingError.Context(
        codingPath: decoder.codingPath,
        debugDescription: "Expected TextDocumentEdit, CreateFile, RenameFile, or DeleteFile"
      )
      throw DecodingError.dataCorrupted(context)
    }
  }

  public func encode(to encoder: Encoder) throws {
    switch self {
    case .textDocumentEdit(let textDocumentEdit):
      try textDocumentEdit.encode(to: encoder)
    case .createFile(let createFile):
      try createFile.encode(to: encoder)
    case .renameFile(let renameFile):
      try renameFile.encode(to: encoder)
    case .deleteFile(let deleteFile):
      try deleteFile.encode(to: encoder)
    }
  }
}

/// Options to create a file.
public struct CreateFileOptions: Codable, Hashable, Sendable {
  /// Overwrite existing file. Overwrite wins over `ignoreIfExists`
  public var overwrite: Bool?
  /// Ignore if exists.
  public var ignoreIfExists: Bool?

  public init(overwrite: Bool? = nil, ignoreIfExists: Bool? = nil) {
    self.overwrite = overwrite
    self.ignoreIfExists = ignoreIfExists
  }
}

/// Create file operation
public struct CreateFile: Codable, Hashable, Sendable {
  /// The resource to create.
  public var uri: DocumentURI
  /// Additional options
  public var options: CreateFileOptions?
  /// An optional annotation identifier describing the operation.
  public var annotationId: ChangeAnnotationIdentifier?

  public init(uri: DocumentURI, options: CreateFileOptions? = nil, annotationId: ChangeAnnotationIdentifier? = nil) {
    self.uri = uri
    self.options = options
    self.annotationId = annotationId
  }

  // MARK: Codable conformance

  public enum CodingKeys: String, CodingKey {
    case kind
    case uri
    case options
    case annotationId
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(String.self, forKey: .kind)
    guard kind == "create" else {
      throw DecodingError.dataCorruptedError(
        forKey: .kind,
        in: container,
        debugDescription: "Kind of CreateFile is not 'create'"
      )
    }
    self.uri = try container.decode(DocumentURI.self, forKey: .uri)
    self.options = try container.decodeIfPresent(CreateFileOptions.self, forKey: .options)
    self.annotationId = try container.decodeIfPresent(ChangeAnnotationIdentifier.self, forKey: .annotationId)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode("create", forKey: .kind)
    try container.encode(self.uri, forKey: .uri)
    try container.encodeIfPresent(self.options, forKey: .options)
    try container.encodeIfPresent(self.annotationId, forKey: .annotationId)
  }
}

/// Rename file options
public struct RenameFileOptions: Codable, Hashable, Sendable {
  /// Overwrite target if existing. Overwrite wins over `ignoreIfExists`
  public var overwrite: Bool?
  /// Ignores if target exists.
  public var ignoreIfExists: Bool?

  public init(overwrite: Bool? = nil, ignoreIfExists: Bool? = nil) {
    self.overwrite = overwrite
    self.ignoreIfExists = ignoreIfExists
  }
}

/// Rename file operation
public struct RenameFile: Codable, Hashable, Sendable {
  /// The old (existing) location.
  public var oldUri: DocumentURI
  /// The new location.
  public var newUri: DocumentURI
  /// Rename options.
  public var options: RenameFileOptions?
  /// An optional annotation identifier describing the operation.
  public var annotationId: ChangeAnnotationIdentifier?

  public init(
    oldUri: DocumentURI,
    newUri: DocumentURI,
    options: RenameFileOptions? = nil,
    annotationId: ChangeAnnotationIdentifier? = nil
  ) {
    self.oldUri = oldUri
    self.newUri = newUri
    self.options = options
    self.annotationId = annotationId
  }

  // MARK: Codable conformance

  public enum CodingKeys: String, CodingKey {
    case kind
    case oldUri
    case newUri
    case options
    case annotationId
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(String.self, forKey: .kind)
    guard kind == "rename" else {
      throw DecodingError.dataCorruptedError(
        forKey: .kind,
        in: container,
        debugDescription: "Kind of RenameFile is not 'rename'"
      )
    }
    self.oldUri = try container.decode(DocumentURI.self, forKey: .oldUri)
    self.newUri = try container.decode(DocumentURI.self, forKey: .newUri)
    self.options = try container.decodeIfPresent(RenameFileOptions.self, forKey: .options)
    self.annotationId = try container.decodeIfPresent(ChangeAnnotationIdentifier.self, forKey: .annotationId)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode("rename", forKey: .kind)
    try container.encode(self.oldUri, forKey: .oldUri)
    try container.encode(self.newUri, forKey: .newUri)
    try container.encodeIfPresent(self.options, forKey: .options)
    try container.encodeIfPresent(self.annotationId, forKey: .annotationId)
  }
}

/// Delete file options
public struct DeleteFileOptions: Codable, Hashable, Sendable {
  /// Delete the content recursively if a folder is denoted.
  public var recursive: Bool?
  /// Ignore the operation if the file doesn't exist.
  public var ignoreIfNotExists: Bool?

  public init(recursive: Bool? = nil, ignoreIfNotExists: Bool? = nil) {
    self.recursive = recursive
    self.ignoreIfNotExists = ignoreIfNotExists
  }
}

/// Delete file operation
public struct DeleteFile: Codable, Hashable, Sendable {
  /// The file to delete.
  public var uri: DocumentURI
  /// Delete options.
  public var options: DeleteFileOptions?
  /// An optional annotation identifier describing the operation.
  public var annotationId: ChangeAnnotationIdentifier?

  public init(uri: DocumentURI, options: DeleteFileOptions? = nil, annotationId: ChangeAnnotationIdentifier? = nil) {
    self.uri = uri
    self.options = options
    self.annotationId = annotationId
  }

  // MARK: Codable conformance

  public enum CodingKeys: String, CodingKey {
    case kind
    case uri
    case options
    case annotationId
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(String.self, forKey: .kind)
    guard kind == "delete" else {
      throw DecodingError.dataCorruptedError(
        forKey: .kind,
        in: container,
        debugDescription: "Kind of DeleteFile is not 'delete'"
      )
    }
    self.uri = try container.decode(DocumentURI.self, forKey: .uri)
    self.options = try container.decodeIfPresent(DeleteFileOptions.self, forKey: .options)
    self.annotationId = try container.decodeIfPresent(ChangeAnnotationIdentifier.self, forKey: .annotationId)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode("delete", forKey: .kind)
    try container.encode(self.uri, forKey: .uri)
    try container.encodeIfPresent(self.options, forKey: .options)
    try container.encodeIfPresent(self.annotationId, forKey: .annotationId)
  }
}
