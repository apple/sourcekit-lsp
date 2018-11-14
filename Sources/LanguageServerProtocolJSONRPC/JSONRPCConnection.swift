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

import SKSupport
import LanguageServerProtocol
import Dispatch
import Foundation

/// A connection between a message handler (e.g. language server) in the same process as the connection object and a remote message handler (e.g. language client) that may run in another process using JSON RPC messages sent over a pair of in/out file descriptors.
///
/// For example, inside a language server, the `JSONRPCConnection` takes the language service implemenation as its `receiveHandler` and itself provides the client connection for sending notifications and callbacks.
public final class JSONRPCConection {

  var receiveHandler: MessageHandler? = nil
  let queue = DispatchQueue(label: "jsonrpc-queue", qos: .userInitiated)
  let sendQueue = DispatchQueue(label: "jsonrpc-send-queue", qos: .userInitiated)
  let receiveIO: DispatchIO
  let sendIO: DispatchIO

  enum State {
    case created, running, closed
  }

  /// Current state of the connection, used to ensure correct usage.
  var state: State

  /// Buffer of received bytes that haven't been parsed.
  var requestBuffer: [UInt8] = []

  private var _nextRequestID: Int = 0

  struct OutstandingRequest {
    var requestType: _RequestType.Type
    var responseType: ResponseType.Type
    var queue: DispatchQueue
    var replyHandler: (LSPResult<Any>) -> ()
  }

  /// The set of currently outstanding outgoing requests along with information about how to decode and handle their responses.
  var outstandingRequests: [RequestID: OutstandingRequest] = [:]

  var closeHandler: () -> ()

  public init(inFD: Int32, outFD: Int32, closeHandler: @escaping () -> () = {}) {
    state = .created
    self.closeHandler = closeHandler

    receiveIO = DispatchIO(type: .stream, fileDescriptor: inFD, queue: queue) { (error: Int32) in
      if error != 0 {
        log("IO error \(error)", level: .error)
      }
    }

    sendIO = DispatchIO(type: .stream, fileDescriptor: outFD, queue: sendQueue) { (error: Int32) in
      if error != 0 {
        log("IO error \(error)", level: .error)
      }
    }

    // We cannot assume the client will send us bytes in packets of any particular size, so set the lower limit to 1.
    receiveIO.setLimit(lowWater: 1)
    receiveIO.setLimit(highWater: Int.max)

    sendIO.setLimit(lowWater: 1)
    sendIO.setLimit(highWater: Int.max)
  }

  deinit {
    assert(state == .closed)
  }

  /// Start processing `inFD` and send messages to `receiveHandler`.
  ///
  /// - parameter receiveHandler: The message handler to invoke for requests received on the `inFD`.
  public func start(receiveHandler: MessageHandler) {
    precondition(state == .created)
    state = .running
    self.receiveHandler = receiveHandler

    receiveIO.read(offset: 0, length: Int.max, queue: queue) { done, data, errorCode in
      guard errorCode == 0 else {
        log("IO error \(errorCode)", level: .error)
        if done { self.close() }
        return
      }

      if done {
        self.close()
        return
      }

      guard let data = data, !data.isEmpty else {
        return
      }

      // Parse and handle any messages in `buffer + data`, leaving any remaining unparsed bytes in `buffer`.
      if self.requestBuffer.isEmpty {
        data.withUnsafeBytes { (pointer: UnsafePointer<UInt8>) in
          let rest = self.parseAndHandleMessages(from: UnsafeBufferPointer(start: pointer, count: data.count))
          self.requestBuffer.append(contentsOf: rest)
        }
      } else {
        self.requestBuffer.append(contentsOf: data)
        var unused = 0
        self.requestBuffer.withUnsafeBufferPointer { buffer in
          let rest = self.parseAndHandleMessages(from: buffer)
          unused = rest.count
        }
        self.requestBuffer.removeFirst(self.requestBuffer.count - unused)
      }
    }
  }

  /// Whether we can send messages in the current state.
  ///
  /// - parameter shouldLog: Whether to log an info message if not ready.
  func readyToSend(shouldLog: Bool = true) -> Bool {
    precondition(state != .created, "tried to send message before calling start(messageHandler:)")
    let ready = state == .running
    if shouldLog && !ready {
      log("ignoring message; state = \(state)")
    }
    return ready
  }

  /// Parse and handle all messages in `bytes`, returning a slice containing any remaining incomplete data.
  func parseAndHandleMessages(from bytes: UnsafeBufferPointer<UInt8>) -> UnsafeBufferPointer<UInt8>.SubSequence {

    let decoder = JSONDecoder()

    // Setup callback for response type.
    decoder.userInfo[.responseTypeCallbackKey] = { id in
      guard let outstanding = self.outstandingRequests[id] else {
        // Unknown request!
        // FIXME: Log
        return nil
      }
      return outstanding.responseType
    } as Message.ResponseTypeCallback

    var bytes = bytes[...]

    MESSAGE_LOOP: while true {
      do {
        guard let ((messageBytes, _), rest) = try bytes.splitMessage() else {
          return bytes
        }
        bytes = rest

        let pointer = UnsafeMutableRawPointer(mutating: UnsafeBufferPointer(rebasing: messageBytes).baseAddress!)
        let message = try decoder.decode(Message.self, from: Data(bytesNoCopy: pointer, count: messageBytes.count, deallocator: .none))

        handle(message)

      } catch let error as MessageDecodingError {

        switch error.messageKind {
          case .request:
            if let id = error.id {
              send { encoder in
                try encoder.encode(Message.errorResponse(ResponseError(error), id: id))
              }
              continue MESSAGE_LOOP
            }
          case .response:
            if let id = error.id {
              if let outstanding = self.outstandingRequests.removeValue(forKey: id) {
                outstanding.replyHandler(.failure(ResponseError(error)))
              } else {
                log("error in response to unknown request \(id) \(error)", level: .error)
              }
              continue MESSAGE_LOOP
            }
          case .notification:
            if error.code == .methodNotFound {
              log("ignoring unknown notification \(error)")
              continue MESSAGE_LOOP
            }
          case .unknown:
            break
        }
        // FIXME: graceful shutdown?
        fatalError("fatal error encountered decoding message \(error)")

      } catch {
        // FIXME: graceful shutdown?
        fatalError("fatal error encountered decoding message \(error)")
      }
    }
  }

  /// Handle a single message by dispatching it to `receiveHandler` or an appropriate reply handler.
  func handle(_ message: Message) {
    switch message {
    case .notification(let notification):
      notification._handle(receiveHandler!, connection: self)
    case .request(let request, id: let id):
      request._handle(receiveHandler!, id: id, connection: self)
    case .response(let response, id: let id):
      guard let outstanding = outstandingRequests.removeValue(forKey: id) else {
        // Unknown request!
        // FIXME: Log
        return
      }
      outstanding.replyHandler(.success(response))
    case .errorResponse(let error, id: let id):
      guard let outstanding = outstandingRequests.removeValue(forKey: id) else {
        // Unknown request!
        // FIXME: Log
        return
      }
      outstanding.replyHandler(.failure(error))
    }
  }

  func send(rawData dispatchData: DispatchData) {
    guard readyToSend() else { return }

    sendIO.write(offset: 0, data: dispatchData, queue: sendQueue) { [weak self] done, _, errorCode in
      if errorCode != 0 {
        log("IO error sending message \(errorCode)", level: .error)
        if done {
          self?.close()
        }
      }
    }
  }

  func send(messageData: Data) {

    var dispatchData = DispatchData.empty
    let header = "Content-Length: \(messageData.count)\r\n\r\n"
    header.utf8.map{$0}.withUnsafeBytes { buffer in
      dispatchData.append(buffer)
    }
    messageData.withUnsafeBytes { pointer in
      dispatchData.append(UnsafeRawBufferPointer(start: pointer, count: messageData.count))
    }

    send(rawData: dispatchData)
  }

  func send(encoding: (JSONEncoder) throws -> Data) {
    guard readyToSend() else { return }

    let encoder = JSONEncoder()

    let data: Data
    do {
      data = try encoding(encoder)

    } catch {
      // FIXME: attempt recovery?
      fatalError("unexpected error while encoding response: \(error)")
    }

    send(messageData: data)
  }

  /// Close the connection.
  public func close() {
    guard state == .running else { return }

    log("\(JSONRPCConection.self): closing...")
    receiveIO.close(flags: .stop)
    sendIO.close(flags: .stop)
    state = .closed
    receiveHandler = nil // break retain cycle
    closeHandler()
  }

  /// Request id for the next outgoing request.
  func nextRequestID() -> RequestID {
    _nextRequestID += 1
    return .number(_nextRequestID)
  }

}

extension JSONRPCConection: _IndirectConnection {
  // MARK: Connection interface

  public func send<Notification>(_ notification: Notification) where Notification: NotificationType {
    guard readyToSend() else { return }
    send { encoder in
      return try encoder.encode(Message.notification(notification))
    }
  }

  public func send<Request>(_ request: Request, queue: DispatchQueue, reply: @escaping (LSPResult<Request.Response>) -> ()) -> RequestID where Request: RequestType {

    let id: RequestID = self.queue.sync {
      let id = nextRequestID()

      guard readyToSend() else {
        reply(.failure(.cancelled))
        return id
      }

      outstandingRequests[id] = OutstandingRequest(
        requestType: Request.self,
        responseType: Request.Response.self,
        queue: queue,
        replyHandler: { anyResult in
          queue.async {
            reply(anyResult.map { $0 as! Request.Response })
          }
      })
      return id
    }

    send { encoder in
      return try encoder.encode(Message.request(request, id: id))
    }

    return id
  }

  public func sendReply<Response>(_ response: LSPResult<Response>, id: RequestID) where Response: ResponseType {
    guard readyToSend() else { return }

    send { encoder in
      switch response {
      case .success(let result):
        return try encoder.encode(Message.response(result, id: id))
      case .failure(let error):
        return try encoder.encode(Message.errorResponse(error, id: id))
      }
    }
  }
}
