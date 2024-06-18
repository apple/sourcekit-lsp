//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

@_spi(Testing) import LSPLogging
import SKTestSupport
import SwiftExtensions
import XCTest

fileprivate func assertLogging(
  logLevel: NonDarwinLogLevel = .default,
  privacyLevel: NonDarwinLogPrivacy = .private,
  expected: [String],
  _ body: (NonDarwinLogger) -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  // nonisolated(unsafe) because calls of `assertLogging` do not log to `logHandler` concurrently.
  nonisolated(unsafe) var messages: [String] = []
  let logger = NonDarwinLogger(
    subsystem: LoggingScope.subsystem,
    category: "test",
    logLevel: logLevel,
    privacyLevel: privacyLevel,
    overrideLogHandler: { messages.append($0) }
  )
  body(logger)
  await NonDarwinLogger.flush()
  guard messages.count == expected.count else {
    XCTFail(
      """
      Number of messages does not match expected does not match expected

      Received:
      \(messages.joined(separator: "\n"))
      """,
      file: file,
      line: line
    )
    return
  }
  for (message, expected) in zip(messages, expected) {
    guard let firstNewline = message.firstIndex(of: "\n") else {
      XCTFail(
        """
        Did not find newline separating header from message in
        \(message)
        """,
        file: file,
        line: line
      )
      continue
    }
    guard message.hasSuffix("\n---") else {
      XCTFail("Message is expected to end with `---`", file: file, line: line)
      return
    }
    let messageContent = String(message[message.index(after: firstNewline)...].dropLast(4))
    XCTAssertEqual(messageContent, expected, "Message does not match expected", file: file, line: line)
  }

  messages.removeAll()
}

final class LoggingTests: XCTestCase {
  func testLoggingFormat() async throws {
    let expectation = self.expectation(description: "message logged")
    // nonisolated(unsafe) because we only have a single call to `logger.log` and that cannot race.
    let message = ThreadSafeBox<String>(initialValue: "")
    let logger = NonDarwinLogger(
      subsystem: LoggingScope.subsystem,
      category: "test",
      overrideLogHandler: {
        message.value = $0
        expectation.fulfill()
      }
    )
    logger.log(level: .error, "my message")
    try await fulfillmentOfOrThrow([expectation])
    XCTAssert(
      message.value.starts(with: "[org.swift.sourcekit-lsp:test] error"),
      "Message did not have expected header. Received \n\(message)"
    )
    XCTAssert(message.value.hasSuffix("\nmy message\n---"), "Message did not have expected body. Received \n\(message)")
  }

  func testLoggingBasic() async {
    await assertLogging(
      expected: ["a"],
      {
        $0.log("a")
      }
    )

    await assertLogging(
      expected: [],
      { _ in
      }
    )

    await assertLogging(expected: ["b\n\nc"]) {
      $0.log("b\n\nc")
    }
  }

  func testLogLevels() async {
    await assertLogging(
      logLevel: .default,
      expected: ["d", "e", "f"]
    ) {
      $0.fault("d")
      $0.error("e")
      $0.log("f")
      $0.info("g")
      $0.debug("h")
    }

    await assertLogging(
      logLevel: .error,
      expected: ["d", "e"]
    ) {
      $0.fault("d")
      $0.error("e")
      $0.log("f")
      $0.info("g")
      $0.debug("h")
    }

    await assertLogging(
      logLevel: .fault,
      expected: ["d"]
    ) {
      $0.fault("d")
      $0.error("e")
      $0.log("f")
      $0.info("g")
      $0.debug("h")
    }
  }

  func testPrivacyMaskingLevels() async {
    await assertLogging(expected: ["password is <private>"]) {
      let password: String = "1234"
      $0.log("password is \(password, privacy: .sensitive)")
    }

    await assertLogging(expected: ["username is root"]) {
      let username: String = "root"
      $0.log("username is \(username, privacy: .private)")
    }

    await assertLogging(expected: ["username is root"]) {
      let username: String = "root"
      $0.log("username is \(username)")
    }

    await assertLogging(
      privacyLevel: .public,
      expected: ["username is <private>"]
    ) {
      let username: String = "root"
      $0.log("username is \(username, privacy: .private)")
    }

    await assertLogging(
      privacyLevel: .public,
      expected: ["username is <private>"]
    ) {
      let username: String = "root"
      $0.log("username is \(username)")
    }
  }

  func testPrivacyMaskingTypes() async {
    await assertLogging(
      privacyLevel: .public,
      expected: ["logging a static string"]
    ) {
      $0.log("logging a \("static string")")
    }

    await assertLogging(
      privacyLevel: .public,
      expected: ["logging from LSPLoggingTests.LoggingTests"]
    ) {
      $0.log("logging from \(LoggingTests.self)")
    }

    struct LogStringConvertible: CustomLogStringConvertible {
      var description: String = "full description"
      var redactedDescription: String = "redacted description"
    }

    await assertLogging(
      privacyLevel: .public,
      expected: ["got redacted description"]
    ) {
      $0.log("got \(LogStringConvertible().forLogging)")
    }

    await assertLogging(
      privacyLevel: .private,
      expected: ["got full description"]
    ) {
      $0.log("got \(LogStringConvertible().forLogging)")
    }
  }
}
