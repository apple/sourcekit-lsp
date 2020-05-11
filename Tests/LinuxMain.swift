import XCTest

import LSPLoggingTests
import LanguageServerProtocolJSONRPCTests
import LanguageServerProtocolTests
import SKCoreTests
import SKSupportTests
import SKSwiftPMWorkspaceTests
import SourceKitTests

var tests = [XCTestCaseEntry]()
tests += LSPLoggingTests.__allTests()
tests += LanguageServerProtocolJSONRPCTests.__allTests()
tests += LanguageServerProtocolTests.__allTests()
tests += SKCoreTests.__allTests()
tests += SKSupportTests.__allTests()
tests += SKSwiftPMWorkspaceTests.__allTests()
tests += SourceKitTests.__allTests()

XCTMain(tests)
