//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import LSPTestSupport
import LanguageServerProtocol
@_spi(Testing) import SKCore
import SKSupport
import SKTestSupport
import SemanticIndex
import SourceKitLSP
import XCTest

import class TSCBasic.Process

final class BackgroundIndexingTests: XCTestCase {
  func testBackgroundIndexingOfSingleFile() async throws {
    let project = try await SwiftPMTestProject(
      files: [
        "MyFile.swift": """
        func 1️⃣foo() {}
        func 2️⃣bar() {
          3️⃣foo()
        }
        """
      ],
      enableBackgroundIndexing: true
    )

    let (uri, positions) = try project.openDocument("MyFile.swift")
    let prepare = try await project.testClient.send(
      CallHierarchyPrepareRequest(textDocument: TextDocumentIdentifier(uri), position: positions["1️⃣"])
    )
    let initialItem = try XCTUnwrap(prepare?.only)
    let calls = try await project.testClient.send(CallHierarchyIncomingCallsRequest(item: initialItem))
    XCTAssertEqual(
      calls,
      [
        CallHierarchyIncomingCall(
          from: CallHierarchyItem(
            name: "bar()",
            kind: .function,
            tags: nil,
            uri: uri,
            range: Range(positions["2️⃣"]),
            selectionRange: Range(positions["2️⃣"]),
            data: .dictionary([
              "usr": .string("s:9MyLibrary3baryyF"),
              "uri": .string(uri.stringValue),
            ])
          ),
          fromRanges: [Range(positions["3️⃣"])]
        )
      ]
    )
  }

  func testBackgroundIndexingOfMultiFileModule() async throws {
    let project = try await SwiftPMTestProject(
      files: [
        "MyFile.swift": """
        func 1️⃣foo() {}
        """,
        "MyOtherFile.swift": """
        func 2️⃣bar() {
          3️⃣foo()
        }
        """,
      ],
      enableBackgroundIndexing: true
    )

    let (uri, positions) = try project.openDocument("MyFile.swift")
    let prepare = try await project.testClient.send(
      CallHierarchyPrepareRequest(textDocument: TextDocumentIdentifier(uri), position: positions["1️⃣"])
    )
    let initialItem = try XCTUnwrap(prepare?.only)
    let calls = try await project.testClient.send(CallHierarchyIncomingCallsRequest(item: initialItem))
    XCTAssertEqual(
      calls,
      [
        CallHierarchyIncomingCall(
          from: CallHierarchyItem(
            name: "bar()",
            kind: .function,
            tags: nil,
            uri: try project.uri(for: "MyOtherFile.swift"),
            range: Range(try project.position(of: "2️⃣", in: "MyOtherFile.swift")),
            selectionRange: Range(try project.position(of: "2️⃣", in: "MyOtherFile.swift")),
            data: .dictionary([
              "usr": .string("s:9MyLibrary3baryyF"),
              "uri": .string(try project.uri(for: "MyOtherFile.swift").stringValue),
            ])
          ),
          fromRanges: [Range(try project.position(of: "3️⃣", in: "MyOtherFile.swift"))]
        )
      ]
    )
  }

  func testBackgroundIndexingOfMultiModuleProject() async throws {
    let project = try await SwiftPMTestProject(
      files: [
        "LibA/MyFile.swift": """
        public func 1️⃣foo() {}
        """,
        "LibB/MyOtherFile.swift": """
        import LibA
        func 2️⃣bar() {
          3️⃣foo()
        }
        """,
      ],
      manifest: """
        let package = Package(
          name: "MyLibrary",
          targets: [
           .target(name: "LibA"),
           .target(name: "LibB", dependencies: ["LibA"]),
          ]
        )
        """,
      enableBackgroundIndexing: true
    )

    let (uri, positions) = try project.openDocument("MyFile.swift")
    let prepare = try await project.testClient.send(
      CallHierarchyPrepareRequest(textDocument: TextDocumentIdentifier(uri), position: positions["1️⃣"])
    )
    let initialItem = try XCTUnwrap(prepare?.only)
    let calls = try await project.testClient.send(CallHierarchyIncomingCallsRequest(item: initialItem))
    XCTAssertEqual(
      calls,
      [
        CallHierarchyIncomingCall(
          from: CallHierarchyItem(
            name: "bar()",
            kind: .function,
            tags: nil,
            uri: try project.uri(for: "MyOtherFile.swift"),
            range: Range(try project.position(of: "2️⃣", in: "MyOtherFile.swift")),
            selectionRange: Range(try project.position(of: "2️⃣", in: "MyOtherFile.swift")),
            data: .dictionary([
              "usr": .string("s:4LibB3baryyF"),
              "uri": .string(try project.uri(for: "MyOtherFile.swift").stringValue),
            ])
          ),
          fromRanges: [Range(try project.position(of: "3️⃣", in: "MyOtherFile.swift"))]
        )
      ]
    )
  }

  func testBackgroundIndexingHappensWithLowPriority() async throws {
    var testHooks = TestHooks()
    testHooks.indexTestHooks.preparationTaskDidFinish = { taskDescription in
      XCTAssert(Task.currentPriority == .low, "\(taskDescription) ran with priority \(Task.currentPriority)")
    }
    testHooks.indexTestHooks.updateIndexStoreTaskDidFinish = { taskDescription in
      XCTAssert(Task.currentPriority == .low, "\(taskDescription) ran with priority \(Task.currentPriority)")
    }
    let project = try await SwiftPMTestProject(
      files: [
        "LibA/MyFile.swift": """
        public func 1️⃣foo() {}
        """,
        "LibB/MyOtherFile.swift": """
        import LibA
        func 2️⃣bar() {
          3️⃣foo()
        }
        """,
      ],
      manifest: """
        let package = Package(
          name: "MyLibrary",
          targets: [
           .target(name: "LibA"),
           .target(name: "LibB", dependencies: ["LibA"]),
          ]
        )
        """,
      testHooks: testHooks,
      enableBackgroundIndexing: true,
      pollIndex: false
    )

    // Wait for indexing to finish without elevating the priority
    let semaphore = WrappedSemaphore(name: "Indexing finished")
    let testClient = project.testClient
    Task(priority: .low) {
      await assertNoThrow {
        try await testClient.send(PollIndexRequest())
      }
      semaphore.signal()
    }
    try semaphore.waitOrThrow()
  }

  func testBackgroundIndexingOfPackageDependency() async throws {
    let dependencyContents = """
      public func 1️⃣doSomething() {}
      """

    let dependencyProject = try await SwiftPMDependencyProject(files: [
      "Sources/MyDependency/MyDependency.swift": dependencyContents
    ])
    defer { dependencyProject.keepAlive() }

    let project = try await SwiftPMTestProject(
      files: [
        "Test.swift": """
        import MyDependency

        func 2️⃣test() {
          3️⃣doSomething()
        }
        """
      ],
      manifest: """
        let package = Package(
          name: "MyLibrary",
          dependencies: [.package(url: "\(dependencyProject.packageDirectory)", from: "1.0.0")],
          targets: [
            .target(
              name: "MyLibrary",
              dependencies: [.product(name: "MyDependency", package: "MyDependency")]
            )
          ]
        )
        """,
      enableBackgroundIndexing: true
    )

    let dependencyUrl = try XCTUnwrap(
      FileManager.default.findFiles(named: "MyDependency.swift", in: project.scratchDirectory).only
    )
    let dependencyUri = DocumentURI(dependencyUrl)
    let testFileUri = try project.uri(for: "Test.swift")
    let positions = project.testClient.openDocument(dependencyContents, uri: dependencyUri)
    let prepare = try await project.testClient.send(
      CallHierarchyPrepareRequest(textDocument: TextDocumentIdentifier(dependencyUri), position: positions["1️⃣"])
    )

    let calls = try await project.testClient.send(
      CallHierarchyIncomingCallsRequest(item: try XCTUnwrap(prepare?.only))
    )

    XCTAssertEqual(
      calls,
      [
        CallHierarchyIncomingCall(
          from: CallHierarchyItem(
            name: "test()",
            kind: .function,
            tags: nil,
            uri: testFileUri,
            range: try project.range(from: "2️⃣", to: "2️⃣", in: "Test.swift"),
            selectionRange: try project.range(from: "2️⃣", to: "2️⃣", in: "Test.swift"),
            data: .dictionary([
              "usr": .string("s:9MyLibrary4testyyF"),
              "uri": .string(testFileUri.stringValue),
            ])
          ),
          fromRanges: [try project.range(from: "3️⃣", to: "3️⃣", in: "Test.swift")]
        )
      ]
    )
  }

  func testIndexCFile() async throws {
    let project = try await SwiftPMTestProject(
      files: [
        "MyLibrary/include/destination.h": "",
        "MyFile.c": """
        void 1️⃣someFunc() {}

        void 2️⃣test() {
          3️⃣someFunc();
        }
        """,
      ],
      enableBackgroundIndexing: true
    )

    let (uri, positions) = try project.openDocument("MyFile.c")
    let prepare = try await project.testClient.send(
      CallHierarchyPrepareRequest(textDocument: TextDocumentIdentifier(uri), position: positions["1️⃣"])
    )
    let calls = try await project.testClient.send(
      CallHierarchyIncomingCallsRequest(item: try XCTUnwrap(prepare?.only))
    )
    XCTAssertEqual(
      calls,
      [
        CallHierarchyIncomingCall(
          from: CallHierarchyItem(
            name: "test",
            kind: .function,
            tags: nil,
            uri: uri,
            range: Range(positions["2️⃣"]),
            selectionRange: Range(positions["2️⃣"]),
            data: .dictionary([
              "usr": .string("c:@F@test"),
              "uri": .string(uri.stringValue),
            ])
          ),
          fromRanges: [Range(positions["3️⃣"])]
        )
      ]
    )
  }

  func testBackgroundIndexingStatusWorkDoneProgress() async throws {
    let receivedBeginProgressNotification = WrappedSemaphore(
      name: "Received work done progress saying build graph generation"
    )
    let receivedReportProgressNotification = WrappedSemaphore(
      name: "Received work done progress saying indexing"
    )
    var testHooks = TestHooks()
    testHooks.indexTestHooks = IndexTestHooks(
      buildGraphGenerationDidFinish: {
        receivedBeginProgressNotification.waitOrXCTFail()
      },
      updateIndexStoreTaskDidFinish: { _ in
        receivedReportProgressNotification.waitOrXCTFail()
      }
    )
    let project = try await SwiftPMTestProject(
      files: [
        "MyFile.swift": """
        func foo() {}
        func bar() {
          foo()
        }
        """
      ],
      capabilities: ClientCapabilities(window: WindowClientCapabilities(workDoneProgress: true)),
      testHooks: testHooks,
      enableBackgroundIndexing: true,
      pollIndex: false,
      preInitialization: { testClient in
        testClient.handleMultipleRequests { (request: CreateWorkDoneProgressRequest) in
          return VoidResponse()
        }
      }
    )

    let beginNotification = try await project.testClient.nextNotification(
      ofType: WorkDoneProgress.self,
      satisfying: { notification in
        guard case .begin(let data) = notification.value else {
          return false
        }
        return data.title == "Indexing"
      }
    )
    receivedBeginProgressNotification.signal()
    guard case .begin(let beginData) = beginNotification.value else {
      XCTFail("Expected begin notification")
      return
    }
    XCTAssertEqual(beginData.message, "Generating build graph")
    let indexingWorkDoneProgressToken = beginNotification.token

    _ = try await project.testClient.nextNotification(
      ofType: WorkDoneProgress.self,
      satisfying: { notification in
        guard notification.token == indexingWorkDoneProgressToken,
          case .report(let reportData) = notification.value,
          reportData.message == "0 / 1"
        else {
          return false
        }
        return true
      }
    )
    receivedReportProgressNotification.signal()

    _ = try await project.testClient.nextNotification(
      ofType: WorkDoneProgress.self,
      satisfying: { notification in
        guard notification.token == indexingWorkDoneProgressToken, case .end = notification.value else {
          return false
        }
        return true
      }
    )

    withExtendedLifetime(project) {}
  }

  func testBackgroundIndexingReindexesWhenSwiftFileIsModified() async throws {
    let project = try await SwiftPMTestProject(
      files: [
        "MyFile.swift": """
        func 1️⃣foo() {}
        """,
        "MyOtherFile.swift": "",
      ],
      enableBackgroundIndexing: true
    )

    let (uri, positions) = try project.openDocument("MyFile.swift")
    let prepare = try await project.testClient.send(
      CallHierarchyPrepareRequest(textDocument: TextDocumentIdentifier(uri), position: positions["1️⃣"])
    )

    let callsBeforeEdit = try await project.testClient.send(
      CallHierarchyIncomingCallsRequest(item: try XCTUnwrap(prepare?.only))
    )
    XCTAssertEqual(callsBeforeEdit, [])

    let otherFileMarkedContents = """
      func 2️⃣bar() {
        3️⃣foo()
      }
      """

    let otherFileUri = try project.uri(for: "MyOtherFile.swift")
    let otherFileUrl = try XCTUnwrap(otherFileUri.fileURL)
    let otherFilePositions = DocumentPositions(markedText: otherFileMarkedContents)

    try extractMarkers(otherFileMarkedContents).textWithoutMarkers.write(
      to: otherFileUrl,
      atomically: true,
      encoding: .utf8
    )

    project.testClient.send(DidChangeWatchedFilesNotification(changes: [FileEvent(uri: otherFileUri, type: .changed)]))
    _ = try await project.testClient.send(PollIndexRequest())

    let callsAfterEdit = try await project.testClient.send(
      CallHierarchyIncomingCallsRequest(item: try XCTUnwrap(prepare?.only))
    )
    XCTAssertEqual(
      callsAfterEdit,
      [
        CallHierarchyIncomingCall(
          from: CallHierarchyItem(
            name: "bar()",
            kind: .function,
            tags: nil,
            uri: otherFileUri,
            range: Range(otherFilePositions["2️⃣"]),
            selectionRange: Range(otherFilePositions["2️⃣"]),
            data: .dictionary([
              "usr": .string("s:9MyLibrary3baryyF"),
              "uri": .string(otherFileUri.stringValue),
            ])
          ),
          fromRanges: [Range(otherFilePositions["3️⃣"])]
        )
      ]
    )
  }

  func testBackgroundIndexingReindexesHeader() async throws {
    let project = try await SwiftPMTestProject(
      files: [
        "MyLibrary/include/Header.h": """
        void 1️⃣someFunc();
        """,
        "MyFile.c": """
        #include "Header.h"
        """,
      ],
      enableBackgroundIndexing: true
    )

    let (uri, positions) = try project.openDocument("Header.h", language: .c)
    let prepare = try await project.testClient.send(
      CallHierarchyPrepareRequest(textDocument: TextDocumentIdentifier(uri), position: positions["1️⃣"])
    )

    let callsBeforeEdit = try await project.testClient.send(
      CallHierarchyIncomingCallsRequest(item: try XCTUnwrap(prepare?.only))
    )
    XCTAssertEqual(callsBeforeEdit, [])

    let headerNewMarkedContents = """
      void someFunc();

      void 2️⃣test() {
        3️⃣someFunc();
      };
      """
    let newPositions = DocumentPositions(markedText: headerNewMarkedContents)

    try extractMarkers(headerNewMarkedContents).textWithoutMarkers.write(
      to: try XCTUnwrap(uri.fileURL),
      atomically: true,
      encoding: .utf8
    )

    project.testClient.send(DidChangeWatchedFilesNotification(changes: [FileEvent(uri: uri, type: .changed)]))
    _ = try await project.testClient.send(PollIndexRequest())

    let callsAfterEdit = try await project.testClient.send(
      CallHierarchyIncomingCallsRequest(item: try XCTUnwrap(prepare?.only))
    )
    XCTAssertEqual(
      callsAfterEdit,
      [
        CallHierarchyIncomingCall(
          from: CallHierarchyItem(
            name: "test",
            kind: .function,
            tags: nil,
            uri: uri,
            range: Range(newPositions["2️⃣"]),
            selectionRange: Range(newPositions["2️⃣"]),
            data: .dictionary([
              "usr": .string("c:@F@test"),
              "uri": .string(uri.stringValue),
            ])
          ),
          fromRanges: [Range(newPositions["3️⃣"])]
        )
      ]
    )
  }

  func testPrepareTargetAfterEditToDependency() async throws {
    var testHooks = TestHooks()
    let expectedPreparationTracker = ExpectedIndexTaskTracker(expectedPreparations: [
      [
        ExpectedPreparation(targetID: "LibA", runDestinationID: "destination"),
        ExpectedPreparation(targetID: "LibB", runDestinationID: "destination"),
      ],
      [
        ExpectedPreparation(targetID: "LibB", runDestinationID: "destination")
      ],
    ])
    testHooks.indexTestHooks = expectedPreparationTracker.testHooks

    let project = try await SwiftPMTestProject(
      files: [
        "LibA/MyFile.swift": "",
        "LibB/MyOtherFile.swift": """
        import LibA
        func bar() {
          1️⃣foo2️⃣()
        }
        """,
      ],
      manifest: """
        let package = Package(
          name: "MyLibrary",
          targets: [
           .target(name: "LibA"),
           .target(name: "LibB", dependencies: ["LibA"]),
          ]
        )
        """,
      capabilities: ClientCapabilities(window: WindowClientCapabilities(workDoneProgress: true)),
      testHooks: testHooks,
      enableBackgroundIndexing: true,
      cleanUp: { expectedPreparationTracker.keepAlive() }
    )

    let (uri, _) = try project.openDocument("MyOtherFile.swift")
    let initialDiagnostics = try await project.testClient.send(
      DocumentDiagnosticsRequest(textDocument: TextDocumentIdentifier(uri))
    )
    guard case .full(let initialDiagnostics) = initialDiagnostics else {
      XCTFail("Expected full diagnostics")
      return
    }
    XCTAssertNotEqual(initialDiagnostics.items, [])

    try "public func foo() {}".write(
      to: try XCTUnwrap(project.uri(for: "MyFile.swift").fileURL),
      atomically: true,
      encoding: .utf8
    )

    project.testClient.send(
      DidChangeWatchedFilesNotification(changes: [FileEvent(uri: try project.uri(for: "MyFile.swift"), type: .changed)])
    )

    let receivedEmptyDiagnostics = self.expectation(description: "Received diagnostic refresh request")
    receivedEmptyDiagnostics.assertForOverFulfill = false
    project.testClient.handleMultipleRequests { (_: CreateWorkDoneProgressRequest) in
      return VoidResponse()
    }

    let testClient = project.testClient
    project.testClient.handleMultipleRequests { [weak testClient] (_: DiagnosticsRefreshRequest) in
      Task { [weak testClient] in
        let updatedDiagnostics = try await testClient?.send(
          DocumentDiagnosticsRequest(textDocument: TextDocumentIdentifier(uri))
        )
        guard case .full(let updatedDiagnostics) = updatedDiagnostics else {
          XCTFail("Expected full diagnostics")
          return
        }
        if updatedDiagnostics.items.isEmpty {
          receivedEmptyDiagnostics.fulfill()
        }
      }
      return VoidResponse()
    }

    // Send a document request for `uri` to trigger re-preparation of its target. We don't actually care about the
    // response for this request. Instead, we wait until SourceKit-LSP sends us a `DiagnosticsRefreshRequest`,
    // indicating that the target of `uri` has been prepared.
    _ = try await project.testClient.send(
      DocumentDiagnosticsRequest(textDocument: TextDocumentIdentifier(uri))
    )

    try await fulfillmentOfOrThrow([receivedEmptyDiagnostics])

    // Check that we received a work done progress for the re-preparation of the target
    _ = try await project.testClient.nextNotification(
      ofType: WorkDoneProgress.self,
      satisfying: { notification in
        switch notification.value {
        case .begin(let value): return value.message == "Preparing current file"
        case .report(let value): return value.message == "Preparing current file"
        case .end: return false
        }
      }
    )
  }

  func testDontStackTargetPreparationForEditorFunctionality() async throws {
    let allDocumentsOpened = WrappedSemaphore(name: "All documents opened")
    let libBStartedPreparation = WrappedSemaphore(name: "LibB started preparing")
    let libDPreparedForEditing = WrappedSemaphore(name: "LibD prepared for editing")

    var testHooks = TestHooks()
    let expectedPreparationTracker = ExpectedIndexTaskTracker(expectedPreparations: [
      // Preparation of targets during the initial of the target
      [
        ExpectedPreparation(targetID: "LibA", runDestinationID: "destination"),
        ExpectedPreparation(targetID: "LibB", runDestinationID: "destination"),
        ExpectedPreparation(targetID: "LibC", runDestinationID: "destination"),
        ExpectedPreparation(targetID: "LibD", runDestinationID: "destination"),
      ],
      // LibB's preparation has already started by the time we browse through the other files, so we finish its preparation
      [
        ExpectedPreparation(
          targetID: "LibB",
          runDestinationID: "destination",
          didStart: { libBStartedPreparation.signal() },
          didFinish: { allDocumentsOpened.waitOrXCTFail() }
        )
      ],
      // And now we just want to prepare LibD, and not LibC
      [
        ExpectedPreparation(
          targetID: "LibD",
          runDestinationID: "destination",
          didFinish: { libDPreparedForEditing.signal() }
        )
      ],
    ])
    testHooks.indexTestHooks = expectedPreparationTracker.testHooks

    let project = try await SwiftPMTestProject(
      files: [
        "LibA/LibA.swift": "",
        "LibB/LibB.swift": "",
        "LibC/LibC.swift": "",
        "LibD/LibD.swift": "",
      ],
      manifest: """
        let package = Package(
          name: "MyLibrary",
          targets: [
           .target(name: "LibA"),
           .target(name: "LibB", dependencies: ["LibA"]),
           .target(name: "LibC", dependencies: ["LibA"]),
           .target(name: "LibD", dependencies: ["LibA"]),
          ]
        )
        """,
      testHooks: testHooks,
      enableBackgroundIndexing: true,
      cleanUp: { expectedPreparationTracker.keepAlive() }
    )

    // Clean the preparation status of all libraries
    project.testClient.send(
      DidChangeWatchedFilesNotification(changes: [FileEvent(uri: try project.uri(for: "LibA.swift"), type: .changed)])
    )

    // Quickly flip through all files. The way the test is designed to work is as follows:
    //  - LibB.swift gets opened and prepared. Preparation is simulated to take a long time until both LibC.swift and
    //    LibD.swift have been opened.
    //  - LibC.swift gets opened. This queues preparation of LibC but doesn't cancel preparation of LibB because we
    //    don't cancel in-progress preparation tasks to guarantee forward progress (see comment at the end of
    //    `SemanticIndexManager.prepare`).
    //  - Now LibD.swift gets opened. This cancels preparation of LibC which actually cancels LibC's preparation for
    //    real because LibC's preparation hasn't started yet (it's only queued).
    // Thus, the only targets that are being prepared are LibB and LibD, which is checked by the
    // `ExpectedIndexTaskTracker`.
    _ = try project.openDocument("LibB.swift")
    try libBStartedPreparation.waitOrThrow()

    _ = try project.openDocument("LibC.swift")

    // Ensure that LibC gets opened before LibD, so that LibD is the latest document. Two open requests don't have
    // dependencies between each other, so SourceKit-LSP is free to execute them in parallel or re-order them without
    // the barrier.
    _ = try await project.testClient.send(BarrierRequest())
    _ = try project.openDocument("LibD.swift")

    // Send a barrier request to ensure we have finished opening LibD before allowing the preparation of LibB to finish.
    _ = try await project.testClient.send(BarrierRequest())

    allDocumentsOpened.signal()
    try libDPreparedForEditing.waitOrThrow()
  }

  public func testProduceIndexLog() async throws {
    let didReceivePreparationIndexLogMessage = WrappedSemaphore(name: "Did receive preparation log message")
    let didReceiveIndexingLogMessage = WrappedSemaphore(name: "Did receive indexing log message")
    let updateIndexStoreTaskDidFinish = WrappedSemaphore(name: "Update index store task did finish")

    // Block the index tasks until we have received a log notification to make sure we stream out results as they come
    // in and not only when the indexing task has finished
    var testHooks = TestHooks()
    testHooks.indexTestHooks.preparationTaskDidFinish = { _ in
      didReceivePreparationIndexLogMessage.waitOrXCTFail()
    }
    testHooks.indexTestHooks.updateIndexStoreTaskDidFinish = { _ in
      didReceiveIndexingLogMessage.waitOrXCTFail()
      updateIndexStoreTaskDidFinish.signal()
    }

    let project = try await SwiftPMTestProject(
      files: [
        "MyFile.swift": ""
      ],
      testHooks: testHooks,
      enableBackgroundIndexing: true,
      pollIndex: false
    )
    _ = try await project.testClient.nextNotification(
      ofType: LogMessageNotification.self,
      satisfying: { notification in
        return notification.message.contains("Preparing MyLibrary")
      }
    )
    didReceivePreparationIndexLogMessage.signal()
    _ = try await project.testClient.nextNotification(
      ofType: LogMessageNotification.self,
      satisfying: { notification in
        notification.message.contains("Indexing \(try project.uri(for: "MyFile.swift").pseudoPath)")
      }
    )
    didReceiveIndexingLogMessage.signal()
    try updateIndexStoreTaskDidFinish.waitOrThrow()
  }

  func testIndexingHappensInParallel() async throws {
    let fileAIndexingStarted = WrappedSemaphore(name: "FileA indexing started")
    let fileBIndexingStarted = WrappedSemaphore(name: "FileB indexing started")

    var testHooks = TestHooks()
    let expectedIndexTaskTracker = ExpectedIndexTaskTracker(
      expectedIndexStoreUpdates: [
        [
          ExpectedIndexStoreUpdate(
            sourceFileName: "FileA.swift",
            didStart: {
              fileAIndexingStarted.signal()
            },
            didFinish: {
              fileBIndexingStarted.waitOrXCTFail()
            }
          ),
          ExpectedIndexStoreUpdate(
            sourceFileName: "FileB.swift",
            didStart: {
              fileBIndexingStarted.signal()
            },
            didFinish: {
              fileAIndexingStarted.waitOrXCTFail()
            }
          ),
        ]
      ]
    )
    testHooks.indexTestHooks = expectedIndexTaskTracker.testHooks

    _ = try await SwiftPMTestProject(
      files: [
        "FileA.swift": "",
        "FileB.swift": "",
      ],
      testHooks: testHooks,
      enableBackgroundIndexing: true,
      cleanUp: { expectedIndexTaskTracker.keepAlive() }
    )
  }

  func testNoIndexingHappensWhenPackageIsReopened() async throws {
    let project = try await SwiftPMTestProject(
      files: [
        "SwiftLib/NonEmptySwiftFile.swift": """
        func test() {}
        """,
        "CLib/include/EmptyHeader.h": "",
        "CLib/Assembly.S": "",
        "CLib/EmptyC.c": "",
        "CLib/NonEmptyC.c": """
        void test() {}
        """,
      ],
      manifest: """
        let package = Package(
          name: "MyLibrary",
          targets: [
            .target(name: "SwiftLib"),
            .target(name: "CLib"),
          ]
        )
        """,
      enableBackgroundIndexing: true
    )

    var otherClientOptions = TestHooks()
    otherClientOptions.indexTestHooks = IndexTestHooks(
      preparationTaskDidStart: { taskDescription in
        XCTFail("Did not expect any target preparation, got \(taskDescription.targetsToPrepare)")
      },
      updateIndexStoreTaskDidStart: { taskDescription in
        XCTFail("Did not expect any indexing tasks, got \(taskDescription.filesToIndex)")
      }
    )
    let otherClient = try await TestSourceKitLSPClient(
      testHooks: otherClientOptions,
      enableBackgroundIndexing: true,
      workspaceFolders: [
        WorkspaceFolder(uri: DocumentURI(project.scratchDirectory))
      ]
    )
    _ = try await otherClient.send(PollIndexRequest())
  }

  func testOpeningFileThatIsNotPartOfThePackageDoesntGenerateABuildFolderThere() async throws {
    let project = try await SwiftPMTestProject(
      files: [
        "Lib.swift": "",
        "OtherLib/OtherLib.swift": "",
      ],
      enableBackgroundIndexing: true
    )
    _ = try project.openDocument("OtherLib.swift")
    // Wait for 1 second to increase the likelihood of this test failing in case we would start scheduling some
    // background task that causes a build in the `OtherLib` directory.
    try await Task.sleep(for: .seconds(1))
    let nestedIndexBuildURL = try XCTUnwrap(
      project.uri(for: "OtherLib.swift").fileURL?
        .deletingLastPathComponent()
        .appendingPathComponent(".index-build")
    )
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: nestedIndexBuildURL.path),
      "No file should exist at \(nestedIndexBuildURL)"
    )
  }

  func testShowMessageWhenOpeningAProjectThatDoesntSupportBackgroundIndexing() async throws {
    let project = try await MultiFileTestProject(
      files: [
        "compile_commands.json": ""
      ],
      enableBackgroundIndexing: true
    )
    let message = try await project.testClient.nextNotification(ofType: ShowMessageNotification.self)
    XCTAssert(message.message.contains("Background indexing"), "Received unexpected message: \(message.message)")
  }

  func testNoPreparationStatusIfTargetIsUpToDate() async throws {
    let project = try await SwiftPMTestProject(
      files: [
        "Lib.swift": ""
      ],
      capabilities: ClientCapabilities(window: WindowClientCapabilities(workDoneProgress: true)),
      enableBackgroundIndexing: true
    )

    // Opening the document prepares it for editor functionality. Its target is already prepared, so we shouldn't show
    // a work done progress for it.
    project.testClient.handleSingleRequest { (request: CreateWorkDoneProgressRequest) in
      XCTFail("Received unexpected create work done progress: \(request)")
      return VoidResponse()
    }
    _ = try project.openDocument("Lib.swift")
    _ = try await project.testClient.send(BarrierRequest())
  }

  func testImportPreparedModuleWithFunctionBodiesSkipped() async throws {
    try await SkipUnless.sourcekitdSupportsRename()
    // This test case was crashing the indexing compiler invocation for Client if Lib was built for index preparation
    // (using `-enable-library-evolution -experimental-skip-all-function-bodies -experimental-lazy-typecheck`) but the
    // Client was not indexed with `-experimental-allow-module-with-compiler-errors`. rdar://129071600
    let project = try await SwiftPMTestProject(
      files: [
        "Lib/Lib.swift": """
        public class TerminalController {
          public var 1️⃣width: Int { 1 }
        }
        """,
        "Client/Client.swift": """
        import Lib

        func test(terminal: TerminalController) {
          let width = terminal.width
        }
        """,
      ],
      manifest: """
        let package = Package(
          name: "MyLibrary",
          targets: [
            .target(name: "Lib"),
            .target(name: "Client", dependencies: ["Lib"]),
          ]
        )
        """,
      enableBackgroundIndexing: true
    )
    let (uri, positions) = try project.openDocument("Lib.swift")

    // Check that we indexed `Client.swift` by checking that we return a rename location within it.
    let result = try await project.testClient.send(
      RenameRequest(textDocument: TextDocumentIdentifier(uri), position: positions["1️⃣"], newName: "height")
    )
    XCTAssertEqual((result?.changes?.keys).map(Set.init), [uri, try project.uri(for: "Client.swift")])
  }

  func testDontPreparePackageManifest() async throws {
    let project = try await SwiftPMTestProject(
      files: [
        "Lib.swift": ""
      ],
      enableBackgroundIndexing: true
    )

    _ = try await project.testClient.nextNotification(
      ofType: LogMessageNotification.self,
      satisfying: { $0.message.contains("Preparing MyLibrary") }
    )

    // Opening the package manifest shouldn't cause any `swift build` calls to prepare them because they are not part of
    // a target that can be prepared.
    let (uri, _) = try project.openDocument("Package.swift")
    _ = try await project.testClient.send(DocumentDiagnosticsRequest(textDocument: TextDocumentIdentifier(uri)))
    try await project.testClient.assertDoesNotReceiveNotification(
      ofType: LogMessageNotification.self,
      satisfying: { $0.message.contains("Preparing") }
    )
  }

  func testUseBuildFlagsDuringPreparation() async throws {
    var options = SourceKitLSPOptions.testDefault()
    options.swiftPM.swiftCompilerFlags = ["-D", "MY_FLAG"]
    let project = try await SwiftPMTestProject(
      files: [
        "Lib/Lib.swift": """
        #if MY_FLAG
        public func foo() -> Int { 1 }
        #endif
        """,
        "Client/Client.swift": """
        import Lib

        func test() -> String {
          return foo()
        }
        """,
      ],
      manifest: """
        let package = Package(
          name: "MyLibrary",
          targets: [
            .target(name: "Lib"),
            .target(name: "Client", dependencies: ["Lib"]),
          ]
        )
        """,
      options: options,
      enableBackgroundIndexing: true
    )

    // Check that we get an error about the return type of `foo` (`Int`) not being convertible to the return type of
    // `test` (`String`), which indicates that `Lib` had `foo` and was thus compiled with `-D MY_FLAG`
    let (uri, _) = try project.openDocument("Client.swift")
    let diagnostics = try await project.testClient.send(
      DocumentDiagnosticsRequest(textDocument: TextDocumentIdentifier(uri))
    )
    guard case .full(let diagnostics) = diagnostics else {
      XCTFail("Expected full diagnostics report")
      return
    }
    XCTAssert(
      diagnostics.items.contains(where: {
        $0.message == "Cannot convert return expression of type 'Int' to return type 'String'"
      }),
      "Did not get expected diagnostic: \(diagnostics)"
    )
  }

  func testLibraryUsedByExecutableTargetAndPackagePlugin() async throws {
    try await SkipUnless.swiftPMStoresModulesForTargetAndHostInSeparateFolders()
    let project = try await SwiftPMTestProject(
      files: [
        "Lib/MyFile.swift": """
        public func 1️⃣foo() {}
        """,
        "MyExec/MyExec.swift": """
        import Lib
        func bar() {
          2️⃣foo()
        }
        """,
        "Plugins/MyPlugin/MyPlugin.swift": """
        import PackagePlugin
        @main
        struct MyPlugin: CommandPlugin {
          func performCommand(context: PluginContext, arguments: [String]) async throws {}
        }
        """,
      ],
      manifest: """
        let package = Package(
          name: "MyLibrary",
          targets: [
           .target(name: "Lib"),
           .executableTarget(name: "MyExec", dependencies: ["Lib"]),
           .plugin(
             name: "MyPlugin",
             capability: .command(
               intent: .sourceCodeFormatting(),
               permissions: []
             ),
             dependencies: ["MyExec"]
           )
          ]
        )
        """,
      enableBackgroundIndexing: true
    )

    let (uri, positions) = try project.openDocument("MyExec.swift")
    let definition = try await project.testClient.send(
      DefinitionRequest(textDocument: TextDocumentIdentifier(uri), position: positions["2️⃣"])
    )
    XCTAssertEqual(definition, .locations([try project.location(from: "1️⃣", to: "1️⃣", in: "MyFile.swift")]))
  }

  func testCrossModuleFunctionalityEvenIfLowLevelModuleHasErrors() async throws {
    try await SkipUnless.swiftPMSupportsExperimentalPrepareForIndexing()
    let options = SourceKitLSPOptions.testDefault(experimentalFeatures: [.swiftpmPrepareForIndexing])
    let project = try await SwiftPMTestProject(
      files: [
        "LibA/LibA.swift": """
        public func test() -> Invalid {
          return ""
        }
        """,
        "LibB/LibB.swift": """
        import LibA

        public func 1️⃣libBTest() -> Int {
          return libATest()
        }
        """,
        "MyExec/MyExec.swift": """
        import LibB

        func test() -> Int {
          return 2️⃣libBTest()
        }
        """,
      ],
      manifest: """
        let package = Package(
          name: "MyLibrary",
          targets: [
           .target(name: "LibA"),
           .target(name: "LibB", dependencies: ["LibA"]),
           .executableTarget(name: "MyExec", dependencies: ["LibB"]),
          ]
        )
        """,
      options: options,
      enableBackgroundIndexing: true
    )

    let (uri, positions) = try project.openDocument("MyExec.swift")
    let response = try await project.testClient.send(
      DefinitionRequest(textDocument: TextDocumentIdentifier(uri), position: positions["2️⃣"])
    )
    XCTAssertEqual(response, .locations([try project.location(from: "1️⃣", to: "1️⃣", in: "LibB.swift")]))
  }

  func testUpdatePackageDependency() async throws {
    try SkipUnless.longTestsEnabled()

    let dependencyProject = try await SwiftPMDependencyProject(files: [
      "Sources/MyDependency/Dependency.swift": """
      /// Do something v1.0.0
      public func doSomething() {}
      """
    ])
    let dependencySwiftURL = dependencyProject.packageDirectory
      .appendingPathComponent("Sources")
      .appendingPathComponent("MyDependency")
      .appendingPathComponent("Dependency.swift")
    defer { dependencyProject.keepAlive() }

    let project = try await SwiftPMTestProject(
      files: [
        "Test.swift": """
        import MyDependency

        func test() {
          1️⃣doSomething()
        }
        """
      ],
      manifest: """
        let package = Package(
          name: "MyLibrary",
          dependencies: [.package(url: "\(dependencyProject.packageDirectory)", from: "1.0.0")],
          targets: [
            .target(
              name: "MyLibrary",
              dependencies: [.product(name: "MyDependency", package: "MyDependency")]
            )
          ]
        )
        """,
      enableBackgroundIndexing: true
    )
    let packageResolvedURL = project.scratchDirectory.appendingPathComponent("Package.resolved")

    let originalPackageResolvedContents = try String(contentsOf: packageResolvedURL)

    // First check our setup to see that we get the expected hover response before changing the dependency project.
    let (uri, positions) = try project.openDocument("Test.swift")
    let hoverBeforeUpdate = try await project.testClient.send(
      HoverRequest(textDocument: TextDocumentIdentifier(uri), position: positions["1️⃣"])
    )
    XCTAssert(
      hoverBeforeUpdate?.contents.markupContent?.value.contains("Do something v1.0.0") ?? false,
      "Did not contain expected string: \(String(describing: hoverBeforeUpdate))"
    )

    // Just committing a new version of the dependency shouldn't change anything because we didn't update the package
    // dependencies.
    try """
    /// Do something v1.1.0
    public func doSomething() {}
    """.write(to: dependencySwiftURL, atomically: true, encoding: .utf8)
    try await dependencyProject.tag(changedFiles: [dependencySwiftURL], version: "1.1.0")

    let hoverAfterNewVersionCommit = try await project.testClient.send(
      HoverRequest(textDocument: TextDocumentIdentifier(uri), position: positions["1️⃣"])
    )
    XCTAssert(
      hoverAfterNewVersionCommit?.contents.markupContent?.value.contains("Do something v1.0.0") ?? false,
      "Did not contain expected string: \(String(describing: hoverBeforeUpdate))"
    )

    // Updating Package.swift causes a package reload but should not cause dependencies to be updated.
    project.testClient.send(
      DidChangeWatchedFilesNotification(changes: [
        FileEvent(uri: DocumentURI(project.scratchDirectory.appendingPathComponent("Package.resolved")), type: .changed)
      ])
    )
    _ = try await project.testClient.send(PollIndexRequest())
    XCTAssertEqual(try String(contentsOf: packageResolvedURL), originalPackageResolvedContents)

    // Simulate a package update which goes as follows:
    //  - The user runs `swift package update`
    //  - This updates `Package.resolved`, which we watch
    //  - We reload the package, which updates `Dependency.swift` in `.index-build/checkouts`, which we also watch.
    try await Process.run(
      arguments: [
        unwrap(ToolchainRegistry.forTesting.default?.swift?.pathString),
        "package", "update",
        "--package-path", project.scratchDirectory.path,
      ],
      workingDirectory: nil
    )
    XCTAssertNotEqual(try String(contentsOf: packageResolvedURL), originalPackageResolvedContents)
    project.testClient.send(
      DidChangeWatchedFilesNotification(changes: [
        FileEvent(uri: DocumentURI(project.scratchDirectory.appendingPathComponent("Package.resolved")), type: .changed)
      ])
    )
    _ = try await project.testClient.send(PollIndexRequest())
    project.testClient.send(
      DidChangeWatchedFilesNotification(
        changes: FileManager.default.findFiles(named: "Dependency.swift", in: project.scratchDirectory).map {
          FileEvent(uri: DocumentURI($0), type: .changed)
        }
      )
    )

    try await repeatUntilExpectedResult {
      let hoverAfterPackageUpdate = try await project.testClient.send(
        HoverRequest(textDocument: TextDocumentIdentifier(uri), position: positions["1️⃣"])
      )
      return hoverAfterPackageUpdate?.contents.markupContent?.value.contains("Do something v1.1.0") ?? false
    }
  }

  func testAddingRandomSwiftFileDoesNotTriggerPackageReload() async throws {
    let packageInitialized = AtomicBool(initialValue: false)

    var testHooks = TestHooks()
    testHooks.swiftpmTestHooks.reloadPackageDidStart = {
      if packageInitialized.value {
        XCTFail("Build graph should not get reloaded when random file gets added")
      }
    }
    let project = try await SwiftPMTestProject(
      files: ["Test.swift": ""],
      testHooks: testHooks,
      enableBackgroundIndexing: true
    )
    packageInitialized.value = true
    project.testClient.send(
      DidChangeWatchedFilesNotification(changes: [
        FileEvent(uri: DocumentURI(project.scratchDirectory.appendingPathComponent("random.swift")), type: .created)
      ])
    )
    _ = try await project.testClient.send(PollIndexRequest())
  }

  func testCancelIndexing() async throws {
    try await SkipUnless.swiftPMSupportsExperimentalPrepareForIndexing()
    try SkipUnless.longTestsEnabled()

    var options = SourceKitLSPOptions.testDefault(experimentalFeatures: [.swiftpmPrepareForIndexing])
    options.index.updateIndexStoreTimeout = 1 /* second */

    let dateStarted = Date()
    _ = try await SwiftPMTestProject(
      files: [
        "Test.swift": """
        func slow(x: Invalid1, y: Invalid2) {
          x / y / x / y / x / y / x / y
        }
        """
      ],
      options: options,
      enableBackgroundIndexing: true
    )
    // Creating the `SwiftPMTestProject` implicitly waits for background indexing to finish.
    // Preparation of `Test.swift` should finish instantly because it doesn't type check the function body.
    // Type-checking the body relies on rdar://80582770, which makes the line hard to type check. We should hit the
    // timeout of 1s. Adding another 2s to escalate a SIGINT (to which swift-frontend doesn't respond) to a SIGKILL mean
    // that the initial indexing should be done in ~3s. 30s should be enough to always finish within this time while
    // also testing that we don't wait for type checking of Test.swift to finish.
    XCTAssert(Date().timeIntervalSince(dateStarted) < 30)
  }

  func testManualReindex() async throws {
    // This test relies on the issue described in https://github.com/apple/sourcekit-lsp/issues/1264 that we don't
    // re-index dependent files if a function of a low-level module gains a new default parameter, which changes the
    // function's USR but is API compatible with all dependencies.
    // Check that after running the re-index request, the index gets updated.

    let project = try await SwiftPMTestProject(
      files: [
        "LibA/LibA.swift": """
        public func 1️⃣getInt() -> Int {
          return 1
        }
        """,
        "LibB/LibB.swift": """
        import LibA

        public func 2️⃣test() -> Int {
          return 3️⃣getInt()
        }
        """,
      ],
      manifest: """
        let package = Package(
          name: "MyLibrary",
          targets: [
           .target(name: "LibA"),
           .target(name: "LibB", dependencies: ["LibA"]),
          ]
        )
        """,
      enableBackgroundIndexing: true
    )

    let expectedCallHierarchyItem = CallHierarchyIncomingCall(
      from: CallHierarchyItem(
        name: "test()",
        kind: .function,
        tags: nil,
        uri: try project.uri(for: "LibB.swift"),
        range: try project.range(from: "2️⃣", to: "2️⃣", in: "LibB.swift"),
        selectionRange: try project.range(from: "2️⃣", to: "2️⃣", in: "LibB.swift"),
        data: .dictionary([
          "usr": .string("s:4LibB4testSiyF"),
          "uri": .string(try project.uri(for: "LibB.swift").stringValue),
        ])
      ),
      fromRanges: [try project.range(from: "3️⃣", to: "3️⃣", in: "LibB.swift")]
    )

    /// Start by making a call hierarchy request to check that we get the expected results without any edits.
    let (uri, positions) = try project.openDocument("LibA.swift")
    let prepareBeforeUpdate = try await project.testClient.send(
      CallHierarchyPrepareRequest(textDocument: TextDocumentIdentifier(uri), position: positions["1️⃣"])
    )
    let callHierarchyBeforeUpdate = try await project.testClient.send(
      CallHierarchyIncomingCallsRequest(item: XCTUnwrap(prepareBeforeUpdate?.only))
    )
    XCTAssertEqual(callHierarchyBeforeUpdate, [expectedCallHierarchyItem])

    // Now add a new default parameter to `getInt`.
    project.testClient.send(DidCloseTextDocumentNotification(textDocument: TextDocumentIdentifier(uri)))
    let newLibAContents = """
      public func getInt(value: Int = 1) -> Int {
        return value
      }
      """
    try newLibAContents.write(to: XCTUnwrap(uri.fileURL), atomically: true, encoding: .utf8)
    project.testClient.send(
      DidOpenTextDocumentNotification(
        textDocument: TextDocumentItem(uri: uri, language: .swift, version: 0, text: newLibAContents)
      )
    )
    project.testClient.send(DidChangeWatchedFilesNotification(changes: [FileEvent(uri: uri, type: .changed)]))
    _ = try await project.testClient.send(PollIndexRequest())

    // The USR of `getInt` has changed but LibB.swift has not been re-indexed due to
    // https://github.com/apple/sourcekit-lsp/issues/1264. We expect to get an empty call hierarchy.
    let prepareAfterUpdate = try await project.testClient.send(
      CallHierarchyPrepareRequest(textDocument: TextDocumentIdentifier(uri), position: positions["1️⃣"])
    )
    let callHierarchyAfterUpdate = try await project.testClient.send(
      CallHierarchyIncomingCallsRequest(item: XCTUnwrap(prepareAfterUpdate?.only))
    )
    XCTAssertEqual(callHierarchyAfterUpdate, [])

    // After re-indexing, we expect to get a full call hierarchy again.
    _ = try await project.testClient.send(TriggerReindexRequest())
    _ = try await project.testClient.send(PollIndexRequest())

    let prepareAfterReindex = try await project.testClient.send(
      CallHierarchyPrepareRequest(textDocument: TextDocumentIdentifier(uri), position: positions["1️⃣"])
    )
    let callHierarchyAfterReindex = try await project.testClient.send(
      CallHierarchyIncomingCallsRequest(item: XCTUnwrap(prepareAfterReindex?.only))
    )
    XCTAssertEqual(callHierarchyAfterReindex, [expectedCallHierarchyItem])
  }
}

extension HoverResponseContents {
  var markupContent: MarkupContent? {
    switch self {
    case .markupContent(let markupContent): return markupContent
    default: return nil
    }
  }
}
