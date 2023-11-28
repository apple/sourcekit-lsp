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

import LSPLogging
import LanguageServerProtocol

/// Handler responsible for registering a capability with the client.
public typealias ClientRegistrationHandler = (CapabilityRegistration) -> Void

/// A class which tracks the client's capabilities as well as our dynamic
/// capability registrations in order to avoid registering conflicting
/// capabilities.
public final class CapabilityRegistry {
  /// Dynamically registered completion options.
  private var completion: [CapabilityRegistration: CompletionRegistrationOptions] = [:]

  /// Dynamically registered folding range options.
  private var foldingRange: [CapabilityRegistration: FoldingRangeRegistrationOptions] = [:]

  /// Dynamically registered semantic tokens options.
  private var semanticTokens: [CapabilityRegistration: SemanticTokensRegistrationOptions] = [:]

  /// Dynamically registered inlay hint options.
  private var inlayHint: [CapabilityRegistration: InlayHintRegistrationOptions] = [:]

  /// Dynamically registered pull diagnostics options.
  private var pullDiagnostics: [CapabilityRegistration: DiagnosticRegistrationOptions] = [:]

  /// Dynamically registered file watchers.
  private var didChangeWatchedFiles: DidChangeWatchedFilesRegistrationOptions?

  /// Dynamically registered command IDs.
  private var commandIds: Set<String> = []

  public let clientCapabilities: ClientCapabilities

  public init(clientCapabilities: ClientCapabilities) {
    self.clientCapabilities = clientCapabilities
  }

  public var clientHasDynamicCompletionRegistration: Bool {
    clientCapabilities.textDocument?.completion?.dynamicRegistration == true
  }

  public var clientHasDynamicFoldingRangeRegistration: Bool {
    clientCapabilities.textDocument?.foldingRange?.dynamicRegistration == true
  }

  public var clientHasDynamicSemanticTokensRegistration: Bool {
    clientCapabilities.textDocument?.semanticTokens?.dynamicRegistration == true
  }

  public var clientHasDynamicInlayHintRegistration: Bool {
    clientCapabilities.textDocument?.inlayHint?.dynamicRegistration == true
  }

  public var clientHasDynamicDocumentDiagnosticsRegistration: Bool {
    clientCapabilities.textDocument?.diagnostic?.dynamicRegistration == true
  }

  public var clientHasDynamicExecuteCommandRegistration: Bool {
    clientCapabilities.workspace?.executeCommand?.dynamicRegistration == true
  }

  public var clientHasDynamicDidChangeWatchedFilesRegistration: Bool {
    clientCapabilities.workspace?.didChangeWatchedFiles?.dynamicRegistration == true
  }

  public var clientHasDiagnosticsCodeDescriptionSupport: Bool {
    clientCapabilities.textDocument?.publishDiagnostics?.codeDescriptionSupport == true
  }

  /// Dynamically register completion capabilities if the client supports it and
  /// we haven't yet registered any completion capabilities for the given
  /// languages.
  public func registerCompletionIfNeeded(
    options: CompletionOptions,
    for languages: [Language],
    registerOnClient: ClientRegistrationHandler
  ) {
    guard clientHasDynamicCompletionRegistration else { return }
    if let registration = registration(for: languages, in: completion) {
      if options != registration.completionOptions {
        logger.error(
          """
            Unable to register new completion options \(String(reflecting: options), privacy: .public) \
            for \(languages, privacy: .public) \
            due to pre-existing options \(String(reflecting: registration.completionOptions), privacy: .public)
          """
        )
      }
      return
    }
    let registrationOptions = CompletionRegistrationOptions(
      documentSelector: self.documentSelector(for: languages),
      completionOptions: options
    )
    let registration = CapabilityRegistration(
      method: CompletionRequest.method,
      registerOptions: self.encode(registrationOptions)
    )

    self.completion[registration] = registrationOptions

    registerOnClient(registration)
  }

  public func registerDidChangeWatchedFiles(
    watchers: [FileSystemWatcher],
    registerOnClient: ClientRegistrationHandler
  ) {
    guard clientHasDynamicDidChangeWatchedFilesRegistration else { return }
    if let registration = didChangeWatchedFiles {
      if watchers != registration.watchers {
        logger.error(
          "Unable to register new file system watchers \(watchers) due to pre-existing options \(registration.watchers)"
        )
      }
      return
    }
    let registrationOptions = DidChangeWatchedFilesRegistrationOptions(
      watchers: watchers
    )
    let registration = CapabilityRegistration(
      method: DidChangeWatchedFilesNotification.method,
      registerOptions: self.encode(registrationOptions)
    )

    self.didChangeWatchedFiles = registrationOptions

    registerOnClient(registration)
  }

  /// Dynamically register folding range capabilities if the client supports it and
  /// we haven't yet registered any folding range capabilities for the given
  /// languages.
  public func registerFoldingRangeIfNeeded(
    options: FoldingRangeOptions,
    for languages: [Language],
    registerOnClient: ClientRegistrationHandler
  ) {
    guard clientHasDynamicFoldingRangeRegistration else { return }
    if let registration = registration(for: languages, in: foldingRange) {
      if options != registration.foldingRangeOptions {
        logger.error(
          """
            Unable to register new folding range options \(String(reflecting: options), privacy: .public) \
            for "\(languages, privacy: .public) \
            due to pre-existing options \(String(reflecting: registration.foldingRangeOptions), privacy: .public)
          """
        )
      }
      return
    }
    let registrationOptions = FoldingRangeRegistrationOptions(
      documentSelector: self.documentSelector(for: languages),
      foldingRangeOptions: options
    )
    let registration = CapabilityRegistration(
      method: FoldingRangeRequest.method,
      registerOptions: self.encode(registrationOptions)
    )

    self.foldingRange[registration] = registrationOptions

    registerOnClient(registration)
  }

  /// Dynamically register semantic tokens capabilities if the client supports
  /// it and we haven't yet registered any semantic tokens capabilities for the
  /// given languages.
  public func registerSemanticTokensIfNeeded(
    options: SemanticTokensOptions,
    for languages: [Language],
    registerOnClient: ClientRegistrationHandler
  ) {
    guard clientHasDynamicSemanticTokensRegistration else { return }
    if let registration = registration(for: languages, in: semanticTokens) {
      if options != registration.semanticTokenOptions {
        logger.error(
          """
          Unable to register new semantic tokens options \(String(reflecting: options), privacy: .public) \
          for \(languages, privacy: .public) \
          due to pre-existing options \(String(reflecting: registration.semanticTokenOptions), privacy: .public)
          """
        )
      }
      return
    }
    let registrationOptions = SemanticTokensRegistrationOptions(
      documentSelector: self.documentSelector(for: languages),
      semanticTokenOptions: options
    )
    let registration = CapabilityRegistration(
      method: SemanticTokensRegistrationOptions.method,
      registerOptions: self.encode(registrationOptions)
    )

    self.semanticTokens[registration] = registrationOptions

    registerOnClient(registration)
  }

  /// Dynamically register inlay hint capabilities if the client supports
  /// it and we haven't yet registered any inlay hint capabilities for the
  /// given languages.
  public func registerInlayHintIfNeeded(
    options: InlayHintOptions,
    for languages: [Language],
    registerOnClient: ClientRegistrationHandler
  ) {
    guard clientHasDynamicInlayHintRegistration else { return }
    if let registration = registration(for: languages, in: inlayHint) {
      if options != registration.inlayHintOptions {
        logger.error(
          """
          Unable to register new inlay hint options \(String(reflecting: options), privacy: .public) \
          for \(languages, privacy: .public) \
          due to pre-existing options \(String(reflecting: registration.inlayHintOptions), privacy: .public)
          """
        )
      }
      return
    }
    let registrationOptions = InlayHintRegistrationOptions(
      documentSelector: self.documentSelector(for: languages),
      inlayHintOptions: options
    )
    let registration = CapabilityRegistration(
      method: InlayHintRequest.method,
      registerOptions: self.encode(registrationOptions)
    )

    self.inlayHint[registration] = registrationOptions

    registerOnClient(registration)
  }

  /// Dynamically register (pull model) diagnostic capabilities,
  /// if the client supports it.
  public func registerDiagnosticIfNeeded(
    options: DiagnosticOptions,
    for languages: [Language],
    registerOnClient: ClientRegistrationHandler
  ) {
    guard clientHasDynamicDocumentDiagnosticsRegistration else { return }
    if let registration = registration(for: languages, in: pullDiagnostics) {
      if options != registration.diagnosticOptions {
        logger.error(
          """
          Unable to register new pull diagnostics options \(String(reflecting: options), privacy: .public) \
          for \(languages, privacy: .public) \
          due to pre-existing options \(String(reflecting: registration.diagnosticOptions), privacy: .public)
          """
        )
      }
      return
    }
    let registrationOptions = DiagnosticRegistrationOptions(
      documentSelector: self.documentSelector(for: languages),
      diagnosticOptions: options
    )
    let registration = CapabilityRegistration(
      method: DocumentDiagnosticsRequest.method,
      registerOptions: self.encode(registrationOptions)
    )

    self.pullDiagnostics[registration] = registrationOptions

    registerOnClient(registration)
  }

  /// Dynamically register executeCommand with the given IDs if the client supports
  /// it and we haven't yet registered the given command IDs yet.
  public func registerExecuteCommandIfNeeded(
    commands: [String],
    registerOnClient: ClientRegistrationHandler
  ) {
    guard clientHasDynamicExecuteCommandRegistration else { return }
    var newCommands = Set(commands)
    newCommands.subtract(self.commandIds)

    // We only want to send the registration with unregistered command IDs since
    // clients such as VS Code only allow a command to be registered once. We could
    // unregister all our commandIds first but this is simpler.
    guard !newCommands.isEmpty else { return }
    self.commandIds.formUnion(newCommands)

    let registrationOptions = ExecuteCommandRegistrationOptions(commands: Array(newCommands))
    let registration = CapabilityRegistration(
      method: ExecuteCommandRequest.method,
      registerOptions: self.encode(registrationOptions)
    )

    registerOnClient(registration)
  }

  /// Unregister a previously registered registration, e.g. if no longer needed
  /// or if registration fails.
  public func remove(registration: CapabilityRegistration) {
    if registration.method == CompletionRequest.method {
      completion.removeValue(forKey: registration)
    }
    if registration.method == FoldingRangeRequest.method {
      foldingRange.removeValue(forKey: registration)
    }
    if registration.method == SemanticTokensRegistrationOptions.method {
      semanticTokens.removeValue(forKey: registration)
    }
    if registration.method == InlayHintRequest.method {
      inlayHint.removeValue(forKey: registration)
    }
    if registration.method == DocumentDiagnosticsRequest.method {
      pullDiagnostics.removeValue(forKey: registration)
    }
  }

  public func pullDiagnosticsRegistration(for language: Language) -> DiagnosticRegistrationOptions? {
    registration(for: [language], in: pullDiagnostics)
  }

  private func documentSelector(for languages: [Language]) -> DocumentSelector {
    return DocumentSelector(languages.map { DocumentFilter(language: $0.rawValue) })
  }

  private func encode<T: RegistrationOptions>(_ options: T) -> LSPAny {
    options.encodeToLSPAny()
  }

  /// Return a registration in `registrations` for one or more of the given
  /// `languages`.
  private func registration<T: TextDocumentRegistrationOptionsProtocol>(
    for languages: [Language],
    in registrations: [CapabilityRegistration: T]
  ) -> T? {
    var languageIds: Set<String> = []
    for language in languages {
      languageIds.insert(language.rawValue)
    }

    for registration in registrations {
      let options = registration.value.textDocumentRegistrationOptions
      guard let filters = options.documentSelector else { continue }
      for filter in filters {
        guard let filterLanguage = filter.language else { continue }
        if languageIds.contains(filterLanguage) {
          return registration.value
        }
      }
    }
    return nil
  }
}
