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

import ArgumentParser
import Foundation
import SKCore
import SKSupport
import SourceKitD

import struct TSCBasic.AbsolutePath

public struct RunSourceKitdRequestCommand: AsyncParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "run-sourcekitd-request",
    abstract: "Run a sourcekitd request and print its result"
  )

  @Option(
    name: .customLong("sourcekitd"),
    help: "Path to sourcekitd.framework/sourcekitd"
  )
  var sourcekitdPath: String?

  @Option(
    name: .customLong("request-file"),
    help: "Path to a JSON sourcekitd request"
  )
  var sourcekitdRequestPath: String

  @Option(help: "line:column override for key.offset")
  var position: String?

  public init() {}

  public func run() async throws {
    var requestString = try String(contentsOf: URL(fileURLWithPath: sourcekitdRequestPath))

    let installPath = try AbsolutePath(validating: Bundle.main.bundlePath)
    let sourcekitdPath =
      if let sourcekitdPath {
        sourcekitdPath
      } else if let path = await ToolchainRegistry(installPath: installPath).default?.sourcekitd?.pathString {
        path
      } else {
        print("Did not find sourcekitd in the toolchain. Specify path to sourcekitd manually by passing --sourcekitd")
        throw ExitCode(1)
      }
    let sourcekitd = try await DynamicallyLoadedSourceKitD.getOrCreate(
      dylibPath: try! AbsolutePath(validating: sourcekitdPath)
    )

    if let lineColumn = position?.split(separator: ":", maxSplits: 2).map(Int.init),
      lineColumn.count == 2,
      let line = lineColumn[0],
      let column = lineColumn[1]
    {
      let requestInfo = try RequestInfo(request: requestString)

      let lineTable = LineTable(requestInfo.fileContents)
      let offset = lineTable.utf8OffsetOf(line: line - 1, utf8Column: column - 1)
      print("Adjusting request offset to \(offset)")
      requestString.replace(#/key.offset: [0-9]+/#, with: "key.offset: \(offset)")
    }

    let request = try requestString.cString(using: .utf8)!.withUnsafeBufferPointer { buffer in
      var error: UnsafeMutablePointer<CChar>?
      let req = sourcekitd.api.request_create_from_yaml(buffer.baseAddress!, &error)!
      if let error {
        throw ReductionError("Failed to parse sourcekitd request from JSON: \(String(cString: error))")
      }
      return req
    }
    let response: SKDResponse = await withCheckedContinuation { continuation in
      var handle: sourcekitd_api_request_handle_t? = nil
      sourcekitd.api.send_request(request, &handle) { resp in
        continuation.resume(returning: SKDResponse(resp!, sourcekitd: sourcekitd))
      }
    }

    switch response.error {
    case .requestFailed(let message):
      print(message)
      throw ExitCode(1)
    case .requestInvalid(let message):
      print(message)
      throw ExitCode(1)
    case .requestCancelled:
      print("request cancelled")
      throw ExitCode(1)
    case .timedOut:
      print("request timed out")
      throw ExitCode(1)
    case .missingRequiredSymbol:
      print("missing required symbol")
      throw ExitCode(1)
    case .connectionInterrupted:
      throw ExitCode(255)
    case nil:
      print(response.description)
    }
  }
}
