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

import LSPTestSupport
import LanguageServerProtocol
import XCTest

// Workaround ambiguity with Foundation.
typealias Notification = LanguageServerProtocol.Notification

class ConnectionTests: XCTestCase {

  var connection: TestLocalConnection! = nil

  override func setUp() {
    connection = TestLocalConnection()
    connection.client.allowUnexpectedNotification = false
  }

  override func tearDown() {
    connection.close()
  }

  func testEcho() {
    let client = connection.client
    let expectation = self.expectation(description: "response received")

    _ = client.send(EchoRequest(string: "hello!")) { resp in
      assertNoThrow {
        XCTAssertEqual(try resp.get(), "hello!")
      }
      expectation.fulfill()
    }

    waitForExpectations(timeout: defaultTimeout)
  }

  func testEchoError() {
    let client = connection.client
    let expectation = self.expectation(description: "response received 1")
    let expectation2 = self.expectation(description: "response received 2")

    _ = client.send(EchoError(code: nil)) { resp in
      assertNoThrow {
        XCTAssertEqual(try resp.get(), VoidResponse())
      }
      expectation.fulfill()
    }

    _ = client.send(EchoError(code: .unknownErrorCode, message: "hey!")) { resp in
      XCTAssertEqual(resp, LSPResult<VoidResponse>.failure(ResponseError(code: .unknownErrorCode, message: "hey!")))
      expectation2.fulfill()
    }

    waitForExpectations(timeout: defaultTimeout)
  }

  func testEchoNotification() {
    let client = connection.client
    let expectation = self.expectation(description: "notification received")

    client.handleNextNotification { (notification: Notification<EchoNotification>) in
      XCTAssertEqual(notification.params.string, "hello!")
      expectation.fulfill()
    }

    client.send(EchoNotification(string: "hello!"))

    waitForExpectations(timeout: defaultTimeout)
  }
}
