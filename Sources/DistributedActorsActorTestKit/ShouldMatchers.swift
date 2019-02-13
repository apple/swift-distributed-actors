//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import XCTest

// bear with me; we need testing facilities for the async things.
// Yeah, I know about https://github.com/Quick/Nimble

fileprivate let isTty = isatty(fileno(stdin)) == 0

public struct TestMatchers<T> {

    private let it: T

    private let callSite: CallSiteInfo

    init(it: T, callSite: CallSiteInfo) {
        self.it = it
        self.callSite = callSite
    }

    func toBe<T>(_ expected: T.Type) {
        if !(it is T) {
            let msg = self.callSite.detailedMessage(got: it, expected: expected)
            XCTAssert(false, msg, file: callSite.file, line: callSite.line)
        }
    }
}

public extension TestMatchers where T: Equatable {
    func toEqual(_ expected: T) {
        let msg = self.callSite.detailedMessage(got: it, expected: expected)
        XCTAssertEqual(it, expected, msg, file: callSite.file, line: callSite.line)
    }

    func toNotEqual(_ expected: T) {
        let msg = self.callSite.detailedMessage(got: it, expected: expected)
        XCTAssertNotEqual(it, expected, msg, file: callSite.file, line: callSite.line)
    }

    func toBe<Other>(_ expected: Other.Type) {
        if !(it is Other) {
            let msg = self.callSite.detailedMessage(got: it, expected: expected)
            XCTAssert(false, msg, file: callSite.file, line: callSite.line)
        }
    }
}

public extension TestMatchers where T: Collection, T.Element: Equatable {

    /// Asserts that `it` starts with the passed in `prefix`.
    ///
    /// If `it` does not completely start with the passed in `prefix`, the error message will also include the a matching
    /// sub-prefix (if any), so one can easier spot at which position the sequences differ.
    public func toStartWith<PossiblePrefix>(prefix: PossiblePrefix) where PossiblePrefix: Collection, T.Element == PossiblePrefix.Element {
        if !it.starts(with: prefix) {
            let partialMatch = it.commonPrefix(with: prefix)

            // classic printout without prefix matching:
            // let msg = self.callSite.detailedMessage("Expected [\(it)] to start with prefix: [\(prefix)]. " + partialMatchMessage)

            // fancy printout:
            var m = "Expected "
            if isTty { m += "[\(ANSIColors.bold.rawValue)" }
            m += "\(partialMatch)"
            if isTty { m += "\(ANSIColors.reset.rawValue)\(ANSIColors.red.rawValue)" }
            m += "\(it.dropFirst(partialMatch.underestimatedCount))] "
            m += "to start with prefix: "
            if isTty { m += "\n                " } // align with "[error] Expected "
            m += "["
            if isTty { m += "[\(ANSIColors.bold.rawValue)" }
            m += "\(partialMatch)"
            if isTty { m += "\(ANSIColors.reset.rawValue)\(ANSIColors.red.rawValue)" }
            m += "\(prefix.dropFirst(partialMatch.underestimatedCount))]."
            if isTty { m += " (Matching sub-prefix marked in \(ANSIColors.bold.rawValue)bold\(ANSIColors.reset.rawValue)\(ANSIColors.red.rawValue))" }

            let msg = self.callSite.detailedMessage(m)
            XCTAssert(false, msg, file: callSite.file, line: callSite.line)
        }
    }

    /// Asserts that `it` contains the `el` element.
    public func toContain(_ el: T.Element) {
        if !it.contains(el) {
            // fancy printout:
            var m = "Expected [\(it)] to contain: ["
            if isTty { m += "\(ANSIColors.bold.rawValue)" }
            m += "\(el)"
            if isTty { m += "\(ANSIColors.reset.rawValue)\(ANSIColors.red.rawValue)" }
            m += "]"

            let msg = self.callSite.detailedMessage(m)
            XCTAssert(false, msg, file: callSite.file, line: callSite.line)
        }
    }
  
}

private extension Collection where Element: Equatable {
    func commonPrefix<OtherSequence>(with other: OtherSequence) -> SubSequence where OtherSequence: Collection, Element == OtherSequence.Element {
        var otherIterator = other.makeIterator()
        return self.prefix(while: { el in el == otherIterator.next() })
    }
}

// MARK: assertion extensions on specific types

extension Optional {
    public func shouldBeNil(file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
        let callSite = CallSiteInfo(file: file, line: line, column: column, function: #function)
        let msg = callSite.detailedMessage("Expected nil, got [\(String(describing: self))]")
        XCTAssertNil(self, msg, file: callSite.file, line: callSite.line)
    }

    public func shouldNotBeNil(file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
        let callSite = CallSiteInfo(file: file, line: line, column: column, function: #function)
        let msg = callSite.detailedMessage("Expected not nil")
        XCTAssertNotNil(self, msg, file: callSite.file, line: callSite.line)
    }
}

extension Equatable {

    /// Asserts that the value is equal to the `other` value
    public func shouldEqual(_ other: @autoclosure () -> Self, file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
        let callSiteInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
        return TestMatchers(it: self, callSite: callSiteInfo).toEqual(other())
    }

    /// Asserts that the value is of the expected Type `T`
    public func shouldBe<T>(_ expectedType: T.Type, file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
        let callSiteInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
        return TestMatchers(it: self, callSite: callSiteInfo).toBe(expectedType)
    }

    public func shouldNotEqual(_ other: @autoclosure () -> Self, file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
        let callSiteInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
        return TestMatchers(it: self, callSite: callSiteInfo).toNotEqual(other())
    }
}

extension Bool {
    public func shouldBeFalse(file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
        let csInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
        return TestMatchers(it: self, callSite: csInfo).toEqual(false)
    }

    public func shouldBeTrue(file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
        let csInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
        return TestMatchers(it: self, callSite: csInfo).toEqual(true)
    }
}

extension Collection where Element: Equatable {
    public func shouldStartWith<PossiblePrefix>(prefix: PossiblePrefix, file: StaticString = #file, line: UInt = #line, column: UInt = #column)
        where PossiblePrefix: Collection, Element == PossiblePrefix.Element {
        let csInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
        return TestMatchers(it: self, callSite: csInfo).toStartWith(prefix: prefix)
    }
    public func shouldContain(_ el: Element, file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
        let csInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
        return TestMatchers(it: self, callSite: csInfo).toContain(el)
    }
}

// MARK: free functions

public func shouldThrow<E: Error, T>(expected: E.Type, file: StaticString = #file, line: UInt = #line, column: UInt = #column, _ block: () throws -> T) {
    let callSiteInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
    let error = shouldThrow(file: file, line: line, column: column, block)

    guard error is E else {
        let msg = callSiteInfo.detailedMessage("Expected block to throw [\(expected)], but threw: [\(error)]")
        XCTFail(msg, file: callSiteInfo.file, line: callSiteInfo.line)
        fatalError("Failed: \(ShouldMatcherError.expectedErrorToBeThrown)")
    }
}

public func shouldThrow<T>(file: StaticString = #file, line: UInt = #line, column: UInt = #column, _ block: () throws -> T) -> Error {
    let callSiteInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
    var it: T? = nil
    do {
        it = try block()
    } catch {
        return error
    }

    let msg = callSiteInfo.detailedMessage("Expected block to throw, but returned: [\(it!)]")
    XCTFail(msg, file: callSiteInfo.file, line: callSiteInfo.line)
    fatalError("Failed: \(ShouldMatcherError.expectedErrorToBeThrown)")
}

/// Provides improved error logging in case of an unexpected throw.
/// XCTest output without wrapping in shouldNotThrow:
///
/// ```
///   <unknown>:0: error: -[Swift Distributed ActorsActorTests.ActorLifecycleTests test_beAbleToStop_immediately] :
///   failed: caught error: The operation couldn’t be completed. (Swift Distributed ActorsActor.ActorPathError error 0.)
/// ```
///
/// Error report with shouldNotThrow includes more details about the thrown value:
///
/// ```
/// sact/Tests/Swift Distributed ActorsActorTests/ActorLifecycleTests.swift:55: error: -[Swift Distributed ActorsActorTests.ActorLifecycleTests test_beAbleToStop_immediately] : failed -
///    shouldNotThrow({
///    ^~~~~~~~~~~~~~~
/// error: Unexpected throw captured: illegalActorPathElement(name: "/user", illegal: "/", index: 0)
/// Fatal error: Failed: expectedErrorToBeThrown: file sact/Sources/Swift Distributed ActorsActorTestKit/ShouldMatchers.swift, line 79
/// ```
///
/// Mostly used for debugging what was thrown in a test in a more command line friendly way, e.g. on CI.
public func shouldNotThrow<T>(file: StaticString = #file, line: UInt = #line, column: UInt = #column, _ block: () throws -> T) throws -> T {
    let callSiteInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
    do {
        return try block()
    } catch {
        let msg = callSiteInfo.detailedMessage("Unexpected throw captured: [\(error)]")
        XCTFail(msg, file: callSiteInfo.file, line: callSiteInfo.line)
        throw ShouldMatcherError.unexpectedErrorWasThrown
    }
}

// MARK: Errors and metadata

public enum ShouldMatcherError: Error {
    case expectedErrorToBeThrown
    case unexpectedErrorWasThrown
}

struct CallSiteInfo {
    let file: StaticString
    let line: UInt
    let column: UInt
    let appliedAssertionName: String

    init(file: StaticString, line: UInt, column: UInt, function: String) {
        self.file = file
        self.line = line
        self.column = column
        self.appliedAssertionName = String(function[function.startIndex...function.firstIndex(of: "(")!])
    }

    /// Prepares a detailed error information, specialized for two values being equal
    /// // TODO: DRY this all up
    /// - Warning: Performs file IO in order to read source location line where failure happened
    func detailedMessage(got it: Any, expected: Any) -> String {
        let msg = "[\(it)] does not equal expected: [\(expected)]\n"
        return detailedMessage(msg)
    }

    /// Prepares a detailed error information
    ///
    /// - Warning: Performs file IO in order to read source location line where failure happened
    func detailedMessage(_ explained: String) -> String {
        let lines = try! String(contentsOfFile: "\(self.file)")
            .components(separatedBy: .newlines)
        let failingLine = lines
            .dropFirst(Int(self.line - 1))
            .first!

        var s = ""
        if isTty { s += "\n" } else { s += "\(explained)\n" }
        s += "\(failingLine)\n"
        s += "\(String(repeating: " ", count: Int(self.column) - 1 - self.appliedAssertionName.count))"
        if isTty { s += ANSIColors.red.rawValue }
        s += "^\(String(repeating: "~", count: self.appliedAssertionName.count - 1))\n"
        s += "error: "
        s += explained
        if isTty { s += ANSIColors.reset.rawValue }
        return s
    }

}

extension CallSiteInfo {

    /// Returns an Error that should be thrown by the called.
    /// The failure contains the passed in message as well as source location of the call site, for easier locating of the issue.
    public func failure(message: String) -> Error {
        let details = detailedMessage(message)
        XCTAssert(false, details, file: self.file, line: self.line)

        return CallSiteError.CallSiteError(message: details)
    }

}

public enum CallSiteError: Error {
    case CallSiteError(message: String)

}

enum ANSIColors: String {
    case black = "\u{001B}[0;30m"
    case red = "\u{001B}[0;31m"
    case green = "\u{001B}[0;32m"
    case yellow = "\u{001B}[0;33m"
    case blue = "\u{001B}[0;34m"
    case magenta = "\u{001B}[0;35m"
    case cyan = "\u{001B}[0;36m"
    case white = "\u{001B}[0;37m"

    case bold = "\u{001B}[1m"

    case reset = "\u{001B}[0;0m"
}
