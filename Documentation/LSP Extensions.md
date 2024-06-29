# LSP Extensions

SourceKit-LSP extends the LSP protocol in the following ways.

## `PublishDiagnosticsClientCapabilities`

Added field (this is an extension from clangd that SourceKit-LSP re-exposes):

```ts
/**
 * Requests that SourceKit-LSP send `Diagnostic.codeActions`.
 */
codeActionsInline?: bool
```

## `Diagnostic`

Added field (this is an extension from clangd that SourceKit-LSP re-exposes):

```ts
/**
 * All the code actions that address this diagnostic.
 */
codeActions: CodeAction[]?
```

## `DiagnosticRelatedInformation`

Added field (this is an extension from clangd that SourceKit-LSP re-exposes):

```ts
/**
 * All the code actions that address the parent diagnostic via this note.
 */
codeActions: CodeAction[]?
```

## Semantic token modifiers

Added the following cases from clangd

```ts
deduced = 'deduced'
virtual = 'virtual'
dependentName = 'dependentName'
usedAsMutableReference = 'usedAsMutableReference'
usedAsMutablePointer = 'usedAsMutablePointer'
constructorOrDestructor = 'constructorOrDestructor'
userDefined = 'userDefined'
functionScope = 'functionScope'
classScope = 'classScope'
fileScope = 'fileScope'
globalScope = 'globalScope'
```

## Semantic token types

Added the following cases from clangd

```ts
bracket = 'bracket'
label = 'label'
concept = 'concept'
unknown = 'unknown'
```

Added case

```ts
/**
 * An identifier that hasn't been further classified
 */
identifier = 'identifier'
```

## `textDocument/interface`

New request that request a textual interface of a module to display in the IDE. Used internally within SourceKit-LSP

- params: `OpenInterfaceParams`
- result: `InterfaceDetails?`

```ts
export interface OpenInterfaceRequest: TextDocumentRequest, Hashable {
  /**
   * The document whose compiler arguments should be used to generate the interface.
   */
  textDocument: TextDocumentIdentifier

  /**
   * The module to generate an index for.
   */
  moduleName: string

  /**
   * The module group name.
   */
  groupName?: string

  /**
   * The symbol USR to search for in the generated module interface.
   */
  symbolUSR?: string
}

interface InterfaceDetails {
  uri: DocumentURI
  position?: Position
}
```

## `textDocument/symbolInfo`

New request for semantic information about the symbol at a given location.

This request looks up the symbol (if any) at a given text document location and returns
SymbolDetails for that location, including information such as the symbol's USR. The symbolInfo
request is not primarily designed for editors, but instead as an implementation detail of how
one LSP implementation (e.g. SourceKit) gets information from another (e.g. clangd) to use in
performing index queries or otherwise implementing the higher level requests such as definition.

This request is an extension of the `textDocument/symbolInfo` request defined by clangd.

- params: `SymbolInfoParams`
- result: `SymbolDetails[]`


```ts
export interface SymbolInfoParams {
  /**
   * The document in which to lookup the symbol location.
   */
  textDocument: TextDocumentIdentifier

  /**
   * The document location at which to lookup symbol information.
   */
  position: Position
}

interface ModuleInfo {
  /**
   * The name of the module in which the symbol is defined.
   */
  moduleName: string

  /**
   * If the symbol is defined within a subgroup of a module, the name of the group. Otherwise `nil`.
   */
  groupName?: string
}

interface SymbolDetails {
  /**
   * The name of the symbol, if any.
   */
  name?: string

  /**
   * The name of the containing type for the symbol, if any.
   *
   * For example, in the following snippet, the `containerName` of `foo()` is `C`.
   *
   * ```c++
   * class C {
   *   void foo() {}
   * }
   */
  containerName?: string

  /**
   * The USR of the symbol, if any.
   */
  usr?: string

  /**
   * Best known declaration or definition location without global knowledge.
   *
   * For a local or private variable, this is generally the canonical definition location -
   * appropriate as a response to a `textDocument/definition` request. For global symbols this is
   * the best known location within a single compilation unit. For example, in C++ this might be
   * the declaration location from a header as opposed to the definition in some other
   * translation unit.
   */
  bestLocalDeclaration?: Location

  /**
   * The kind of the symbol
   */
  kind?: SymbolKind

  /**
   * Whether the symbol is a dynamic call for which it isn't known which method will be invoked at runtime. This is
   * the case for protocol methods and class functions.
   *
   * Optional because `clangd` does not return whether a symbol is dynamic.
   */
  isDynamic?: bool

  /**
   * Whether this symbol is defined in the SDK or standard library.
   *
   * This property only applies to Swift symbols
   */
  isSystem?: bool

  /**
   * If the symbol is dynamic, the USRs of the types that might be called.
   *
   * This is relevant in the following cases
   * ```swift
   * class A {
   *   func doThing() {}
   * }
   * class B: A {}
   * class C: B {
   *   override func doThing() {}
   * }
   * class D: A {
   *   override func doThing() {}
   * }
   * func test(value: B) {
   *   value.doThing()
   * }
   * ```
   *
   * The USR of the called function in `value.doThing` is `A.doThing` (or its
   * mangled form) but it can never call `D.doThing`. In this case, the
   * receiver USR would be `B`, indicating that only overrides of subtypes in
   * `B` may be called dynamically.
   */
  receiverUsrs?: string[]

  /**
   * If the symbol is defined in a module that doesn't have source information associated with it, the name and group
   * and group name that defines this symbol.
   *
   * This property only applies to Swift symbols.
   */
  systemModule?: ModuleInfo
}
```

## `textDocument/tests`

New request that returns symbols for all the test classes and test methods within a file.

- params: `DocumentTestsParams`
- result: `TestItem[]`

```ts
interface TestTag {
  /**
   * ID of the test tag. `TestTag` instances with the same ID are considered to be identical.
   */
  id: string
}

/**
 * A test item that can be shown an a client's test explorer or used to identify tests alongside a source file.
 *
 * A `TestItem` can represent either a test suite or a test itself, since they both have similar capabilities.
 *
 * This type matches the `TestItem` type in Visual Studio Code to a fair degree.
 */
interface TestItem {
  /**
   * Identifier for the `TestItem`.
   *
   * This identifier uniquely identifies the test case or test suite. It can be used to run an individual test (suite).
   */
  id: string

  /**
   * Display name describing the test.
   */
  label: string

  /**
   * Optional description that appears next to the label.
   */
  description?: string

  /**
   * A string that should be used when comparing this item with other items.
   *
   * When `nil` the `label` is used.
   */
  sortText?: string

  /**
   * Whether the test is disabled.
   */
  disabled: bool

  /**
   * The type of test, eg. the testing framework that was used to declare the test.
   */
  style: string

  /**
   * The location of the test item in the source code.
   */
  location: Location

  /**
   * The children of this test item.
   *
   * For a test suite, this may contain the individual test cases or nested suites.
   */
  children: TestItem[]]

  /**
   * Tags associated with this test item.
   */
  tags: TestTag[]
}

export interface DocumentTestsParams {
  /**
   * The text document.
  */
  textDocument: TextDocumentIdentifier;
}
```

## `textDocument/symbolInfo`

TODO

## `window/logMessage`

Added field:

```ts
/**
 * Asks the client to log the message to a log with this name, to organize log messages from different aspects (eg. general logging vs. logs from background indexing).
 *
 * Clients may ignore this parameter and add the message to the global log
 */
logName?: string
```

## `workspace/_pollIndex`

New request to wait until the index is up-to-date.

- params: `PollIndexParams`
- result: `void`

```ts
export interface PollIndexParams {}
```

## `workspace/tests`

New request that returns symbols for all the test classes and test methods within the current workspace.

- params: `WorkspaceTestsParams`
- result: `TestItem[]`

```ts
export interface WorkspaceTestsParams {}
```

## `workspace/triggerReindex`

New request to re-index all files open in the SourceKit-LSP server.

Users should not need to rely on this request. The index should always be updated automatically in the background. Having to invoke this request means there is a bug in SourceKit-LSP's automatic re-indexing. It does, however, offer a workaround to re-index files when such a bug occurs where otherwise there would be no workaround.


- params: `TriggerReindexParams`
- result: `void`

```ts
export interface TriggerReindexParams {}
```
