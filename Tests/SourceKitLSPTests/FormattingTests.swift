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

import LanguageServerProtocol
import SKTestSupport
import XCTest
import ISDBTestSupport


// Note that none of the indentation values choosen are equal to the default
// indentation level, which is two spaces.
final class FormattingTests: XCTestCase {
  var workspace: SKTibsTestWorkspace! = nil

  func initialize() throws {
    workspace = try XCTUnwrap(staticSourceKitTibsWorkspace(name: "Formatting"))
    try workspace.buildAndIndex()
    try workspace.openDocument(workspace.testLoc("Root").url, language: .swift)
    try workspace.openDocument(workspace.testLoc("Directory").url, language: .swift)
    try workspace.openDocument(workspace.testLoc("NestedWithConfig").url, language: .swift)
    try workspace.openDocument(workspace.testLoc("NestedWithoutConfig").url, language: .swift)
  }

  override func tearDown() {
    workspace = nil
  }

  func performFormattingRequest(file url: URL, options: FormattingOptions) throws -> [TextEdit]? {
    let request = DocumentFormattingRequest(
      textDocument: TextDocumentIdentifier(url), 
      options: options
    )
    return try workspace.sk.sendSync(request)
  }

  func testSpaces() throws {
    try initialize()
    let url = workspace.testLoc("Root").url
    let options = FormattingOptions(tabSize: 3, insertSpaces: true)
    let edits = try XCTUnwrap(performFormattingRequest(file: url, options: options))
    XCTAssertEqual(edits.count, 1)
    let firstEdit = try XCTUnwrap(edits.first)
    XCTAssertEqual(firstEdit.range.lowerBound, Position(line: 0, utf16index: 0))
    XCTAssertEqual(firstEdit.range.upperBound, Position(line: 3, utf16index: 1))
    // var bar needs to be indented with three spaces
    // which is the value from lsp
    XCTAssertEqual(firstEdit.newText, """
    /*Root*/
    struct Root {
       var bar = 123
    }

    """)
  }

  func testTabs() throws {
    try initialize()
    let url = workspace.testLoc("Root").url
    let options = FormattingOptions(tabSize: 3, insertSpaces: false)
    let edits = try XCTUnwrap(performFormattingRequest(file: url, options: options))
    XCTAssertEqual(edits.count, 1)
    let firstEdit = try XCTUnwrap(edits.first)
    XCTAssertEqual(firstEdit.range.lowerBound, Position(line: 0, utf16index: 0))
    XCTAssertEqual(firstEdit.range.upperBound, Position(line: 3, utf16index: 1))
    // var bar needs to be indented with a tab
    // which is the value from lsp
    XCTAssertEqual(firstEdit.newText, """
    /*Root*/
    struct Root {
    \tvar bar = 123
    }

    """)
  }

  func testConfigFile() throws {
    try initialize()
    let url = workspace.testLoc("Directory").url
    let options = FormattingOptions(tabSize: 3, insertSpaces: true)
    let edits = try XCTUnwrap(performFormattingRequest(file: url, options: options))
    XCTAssertEqual(edits.count, 1)
    let firstEdit = try XCTUnwrap(edits.first)
    XCTAssertEqual(firstEdit.range.lowerBound, Position(line: 0, utf16index: 0))
    XCTAssertEqual(firstEdit.range.upperBound, Position(line: 3, utf16index: 1))
    // var bar needs to be indented with one space
    // which is the value from ".swift-format" in "Directory"
    XCTAssertEqual(firstEdit.newText, """
    /*Directory*/
    struct Directory {
     var bar = 123
    }

    """)
  }
  
  func testConfigFileInParentDirectory() throws {
    try initialize()
    let url = workspace.testLoc("NestedWithoutConfig").url
    let options = FormattingOptions(tabSize: 3, insertSpaces: true)
    let edits = try XCTUnwrap(performFormattingRequest(file: url, options: options))
    XCTAssertEqual(edits.count, 1)
    let firstEdit = try XCTUnwrap(edits.first)
    XCTAssertEqual(firstEdit.range.lowerBound, Position(line: 0, utf16index: 0))
    XCTAssertEqual(firstEdit.range.upperBound, Position(line: 3, utf16index: 1))
    // var bar needs to be indented with one space
    // which is the value from ".swift-format" in "Directory"
    XCTAssertEqual(firstEdit.newText, """
    /*NestedWithoutConfig*/
    struct NestedWithoutConfig {
     var bar = 123
    }

    """)
  }

  func testConfigFileInNestedDirectory() throws {
    try initialize()
    let url = workspace.testLoc("NestedWithConfig").url
    let options = FormattingOptions(tabSize: 3, insertSpaces: true)
    let edits = try XCTUnwrap(performFormattingRequest(file: url, options: options))
    XCTAssertEqual(edits.count, 1)
    let firstEdit = try XCTUnwrap(edits.first)
    XCTAssertEqual(firstEdit.range.lowerBound, Position(line: 0, utf16index: 0))
    XCTAssertEqual(firstEdit.range.upperBound, Position(line: 3, utf16index: 1))
    // var bar needs to be indented with four spaces
    // which is the value from ".swift-format" in "NestedWithConfig"
    XCTAssertEqual(firstEdit.newText, """
    /*NestedWithConfig*/
    struct NestedWithConfig {
        var bar = 123
    }

    """)
  }
}
