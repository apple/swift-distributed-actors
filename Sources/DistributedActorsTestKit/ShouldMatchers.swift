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

/// Used to determine if "pretty printing" errors should be done or not.
/// Pretty errors help tremendously to quickly spot exact errors and track them back to source locations,
/// e.g. on CI or when testing in command line and developing in a separate IDE or editor.
private let isTty = isatty(fileno(stdin)) == 0

public struct TestMatchers<T> {
    private let it: T

    private let callSite: CallSiteInfo

    init(it: T, callSite: CallSiteInfo) {
        self.it = it
        self.callSite = callSite
    }

    func toBe<T>(_ expected: T.Type) {
        if !(self.it is T) {
            let error = self.callSite.notEqualError(got: self.it, expected: expected)
            XCTFail("\(error)", file: self.callSite.file, line: self.callSite.line)
        }
    }
}

public extension TestMatchers where T: Equatable {
    func toEqual(_ expected: T) {
        if self.it != expected {
            let error = self.callSite.notEqualError(got: self.it, expected: expected)
            XCTFail("\(error)", file: self.callSite.file, line: self.callSite.line)
        }
    }

    func toNotEqual(_ unexpectedEqual: T) {
        if self.it == unexpectedEqual {
            let error = self.callSite.equalError(got: self.it, unexpectedEqual: unexpectedEqual)
            XCTFail("\(error)", file: self.callSite.file, line: self.callSite.line)
        }
    }

    func toBe<Other>(_ expected: Other.Type) {
        if !(self.it is Other) {
            let error = self.callSite.notEqualError(got: self.it, expected: expected)
            XCTFail("\(error)", file: self.callSite.file, line: self.callSite.line)
        }
    }
}

public extension TestMatchers where T: Collection, T.Element: Equatable {
    /// Asserts that `it` starts with the passed in `prefix`.
    ///
    /// If `it` does not completely start with the passed in `prefix`, the error message will also include the a matching
    /// sub-prefix (if any), so one can easier spot at which position the sequences differ.
    func toStartWith<PossiblePrefix>(prefix: PossiblePrefix) where PossiblePrefix: Collection, T.Element == PossiblePrefix.Element {
        if !self.it.starts(with: prefix) {
            let partialMatch = self.it.commonPrefix(with: prefix)

            // classic printout without prefix matching:
            // let error = self.callSite.error("Expected [\(it)] to start with prefix: [\(prefix)]. " + partialMatchMessage)

            // fancy printout:
            var m = "Expected "
            if isTty { m += "[\(ANSIColors.bold.rawValue)" }
            m += "\(partialMatch)"
            if isTty { m += "\(ANSIColors.reset.rawValue)\(ANSIColors.red.rawValue)" }
            m += "\(self.it.dropFirst(partialMatch.underestimatedCount))] "
            m += "to start with prefix: "
            if isTty { m += "\n" }
            if isTty { m += String(repeating: " ", count: "[error] Expected ".count) } // align with the error message prefix
            m += "["
            if isTty { m += "\(ANSIColors.bold.rawValue)" }
            m += "\(partialMatch)"
            if isTty { m += "\(ANSIColors.reset.rawValue)\(ANSIColors.red.rawValue)" }
            m += "\(prefix.dropFirst(partialMatch.underestimatedCount))]."
            if isTty { m += " (Matching sub-prefix marked in \(ANSIColors.bold.rawValue)bold\(ANSIColors.reset.rawValue)\(ANSIColors.red.rawValue))" }

            let error = self.callSite.error(m)
            XCTFail("\(error)", file: self.callSite.file, line: self.callSite.line)
        }
    }

    /// Asserts that `it` contains the `el` element.
    func toContain(_ el: T.Element) {
        if !self.it.contains(el) {
            // fancy printout:
            var m = "Expected \(T.self):\n    "
            m += self.it.map { "\($0)" }.joined(separator: "\n    ")
            m += "\n"
            m += "to contain: ["
            if isTty { m += "\(ANSIColors.bold.rawValue)" }
            m += "\(el)"
            if isTty { m += "\(ANSIColors.reset.rawValue)\(ANSIColors.red.rawValue)" }
            m += "]"

            let error = self.callSite.error(m)
            XCTFail("\(error)", file: self.callSite.file, line: self.callSite.line)
        }
    }

    func toNotContain(_ el: T.Element) {
        if self.it.contains(el) {
            // fancy printout:
            var m = "Expected \(T.self):\n    "
            m += self.it.map { "\($0)" }.joined(separator: "\n    ")
            m += "\n"
            m += "to NOT contain: ["
            if isTty { m += "\(ANSIColors.bold.rawValue)" }
            m += "\(el)"
            if isTty { m += "\(ANSIColors.reset.rawValue)\(ANSIColors.red.rawValue)" }
            m += "]"

            let error = self.callSite.error(m)
            XCTFail("\(error)", file: self.callSite.file, line: self.callSite.line)
        }
    }

    /// Asserts that `it` contains at least one element matching the predicate.
    func toContain(where predicate: (T.Element) -> Bool) {
        if !self.it.contains(where: { el in predicate(el) }) {
            // fancy printout:
            let m = "Expected [\(it)] to contain element matching predicate"

            let error = self.callSite.error(m)
            XCTFail("\(error)", file: self.callSite.file, line: self.callSite.line)
        }
    }
}

public extension TestMatchers where T == String {
    /// Asserts that `it` contains the `subString`.
    func toContain(_ subString: String, negate: Bool = false) {
        let contains = self.it.contains(subString)
        if (negate && contains) || (!negate && !contains) {
            // fancy printout:
            let negateString = negate ? "NOT " : ""
            var m = "Expected String [\(it)] to \(negateString)contain: ["
            if isTty { m += "\(ANSIColors.bold.rawValue)" }
            m += "\(subString)"
            if isTty { m += "\(ANSIColors.reset.rawValue)\(ANSIColors.red.rawValue)" }
            m += "]"

            let error = self.callSite.error(m)
            XCTFail("\(error)", file: self.callSite.file, line: self.callSite.line)
        }
    }

    /// Asserts that `it` does NOT contain the `subString`.
    func toNotContain(_ subString: String) {
        self.toContain(subString, negate: true)
    }
}

public extension TestMatchers where T: Comparable {
    func toBeLessThan(_ expected: T) {
        if !(self.it < expected) {
            let error = self.callSite.error("\(self.it) is not less than \(expected)")
            XCTAssertLessThan(self.it, expected, "\(error)", file: self.callSite.file, line: self.callSite.line)
        }
    }

    func toBeLessThanOrEqual(_ expected: T) {
        if !(self.it <= expected) {
            let error = self.callSite.error("\(self.it) is not less than or equal \(expected)")
            XCTAssertLessThanOrEqual(self.it, expected, "\(error)", file: self.callSite.file, line: self.callSite.line)
        }
    }

    func toBeGreaterThan(_ expected: T) {
        if !(self.it > expected) {
            let error = self.callSite.error("\(self.it) is not greater than \(expected)")
            XCTAssertGreaterThan(self.it, expected, "\(error)", file: self.callSite.file, line: self.callSite.line)
        }
    }

    func toBeGreaterThanOrEqual(_ expected: T) {
        if !(self.it >= expected) {
            let error = self.callSite.error("\(self.it) is not greater than or equal \(expected)")
            XCTAssertGreaterThanOrEqual(self.it, expected, "\(error)", file: self.callSite.file, line: self.callSite.line)
        }
    }
}

public extension TestMatchers where T: Collection {
    /// Asserts that `it` is empty
    func toBeEmpty() {
        if !self.it.isEmpty {
            let m = "Expected [\(it)] to be empty"

            let error = self.callSite.error(m)
            XCTFail("\(error)", file: self.callSite.file, line: self.callSite.line)
        }
    }

    /// Asserts that `it` is not empty
    func toBeNotEmpty() {
        if self.it.isEmpty {
            let m = "Expected [\(it)] to to be non-empty"

            let error = self.callSite.error(m)
            XCTFail("\(error)", file: self.callSite.file, line: self.callSite.line)
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
        if self != nil {
            let callSite = CallSiteInfo(file: file, line: line, column: column, function: #function)
            let error = callSite.error("Expected nil, got [\(String(describing: self))]")
            XCTAssertNil(self, "\(error)", file: callSite.file, line: callSite.line)
        }
    }

    public func shouldNotBeNil(file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
        if self == nil {
            let callSite = CallSiteInfo(file: file, line: line, column: column, function: #function)
            let error = callSite.error("Expected not nil, got [\(String(describing: self))]")
            XCTAssertNotNil(self, "\(error)", file: callSite.file, line: callSite.line)
        }
    }
}

extension Set {
    public func shouldEqual(_ other: @autoclosure () -> Self, file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
        let callSiteInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
        let rhs = other()
        if self == rhs {
            ()
        } else {
            var message = "Set \(rhs) did not equal \(self)."

            let rhsMinusSelf = rhs.subtracting(self)
            if !rhsMinusSelf.isEmpty {
                message += "\nElements present in `other` but not `self`:"
                message += "\n    \(rhsMinusSelf)"
            }

            let selfMinusRhs = self.subtracting(rhs)
            if !selfMinusRhs.isEmpty {
                message += "\nElements present in `self` but not `other`:"
                message += "\n    \(selfMinusRhs)"
            }

            XCTAssertEqual(
                self, rhs,
                "\(callSiteInfo.error(message))",
                file: callSiteInfo.file,
                line: callSiteInfo.line
            )
        }
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
    public func shouldBe(_ expected: Bool, file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
        let csInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
        return TestMatchers(it: self, callSite: csInfo).toEqual(expected)
    }

    public func shouldBeFalse(file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
        self.shouldBe(false, file: file, line: line, column: column)
    }

    public func shouldBeTrue(file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
        self.shouldBe(true, file: file, line: line, column: column)
    }
}

extension Comparable {
    public func shouldBeLessThan(_ expected: Self, file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
        let csInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
        return TestMatchers(it: self, callSite: csInfo).toBeLessThan(expected)
    }

    public func shouldBeLessThanOrEqual(_ expected: Self, file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
        let csInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
        return TestMatchers(it: self, callSite: csInfo).toBeLessThanOrEqual(expected)
    }

    public func shouldBeGreaterThan(_ expected: Self, file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
        let csInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
        return TestMatchers(it: self, callSite: csInfo).toBeGreaterThan(expected)
    }

    public func shouldBeGreaterThanOrEqual(_ expected: Self, file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
        let csInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
        return TestMatchers(it: self, callSite: csInfo).toBeGreaterThanOrEqual(expected)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Collection `should*` matchers

extension Collection {
    public func shouldBeEmpty(file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
        let callSiteInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
        return TestMatchers(it: self, callSite: callSiteInfo).toBeEmpty() // TODO: lazy impl, should get "expected empty" messages etc
    }

    public func shouldBeNotEmpty(file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
        let callSiteInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
        return TestMatchers(it: self, callSite: callSiteInfo).toBeNotEmpty() // TODO: lazy impl, should get "expected non-empty" messages etc
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

    public func shouldNotContain(_ el: Element, file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
        let csInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
        return TestMatchers(it: self, callSite: csInfo).toNotContain(el)
    }

    /// Applies the `where` predicate while trying to locate at least one element in the collection.
    public func shouldContain(where predicate: (Element) -> Bool, file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
        let csInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
        return TestMatchers(it: self, callSite: csInfo).toContain(where: { predicate($0) })
    }
}

extension String {
    public func shouldContain(_ el: String, file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
        let csInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
        return TestMatchers(it: self, callSite: csInfo).toContain(el)
    }

    public func shouldNotContain(_ el: String, file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
        let csInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
        return TestMatchers(it: self, callSite: csInfo).toNotContain(el)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Free `should*` functions

public func shouldThrow<E: Error, T>(expected: E.Type, file: StaticString = #file, line: UInt = #line, column: UInt = #column, _ block: () throws -> T) throws {
    let callSiteInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
    let error = try shouldThrow(file: file, line: line, column: column, block)

    guard error is E else {
        let error = callSiteInfo.error("Expected block to throw [\(expected)], but threw: [\(error)]")
        XCTFail("\(error)", file: callSiteInfo.file, line: callSiteInfo.line)
        throw error
    }
}

/// If this function throws, the wrapped block did NOT throw.
@discardableResult
public func shouldThrow<T>(file: StaticString = #file, line: UInt = #line, column: UInt = #column, _ block: () throws -> T) throws -> Error {
    let callSiteInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
    var it: T?
    do {
        it = try block()
    } catch {
        return error
    }

    let error = callSiteInfo.error("Expected block to throw, but returned: [\(it!)]")
    XCTFail("\(error)", file: callSiteInfo.file, line: callSiteInfo.line)
    throw error
}

/// Provides improved error logging in case of an unexpected throw.
/// XCTest output without wrapping in shouldNotThrow:
///
/// ```
///   <unknown>:0: error: -[DistributedActorsTests.ActorLifecycleTests test_beAbleToStop_immediately] :
///   failed: caught error: The operation couldn’t be completed. (DistributedActors.ActorPathError error 0.)
/// ```
///
/// Error report with shouldNotThrow includes more details about the thrown value:
///
/// ```
/// sact/Tests/DistributedActorsTests/ActorLifecycleTests.swift:55: error: -[DistributedActorsTests.ActorLifecycleTests test_beAbleToStop_immediately] : failed -
///    shouldNotThrow({
///    ^~~~~~~~~~~~~~~
/// error: Unexpected throw captured: illegalActorPathElement(name: "/user", illegal: "/", index: 0)
/// Fatal error: Failed: expectedErrorToBeThrown: file sact/Sources/DistributedActorsTestKit/ShouldMatchers.swift, line 79
/// ```
///
/// Mostly used for debugging what was thrown in a test in a more command line friendly way, e.g. on CI.
public func shouldNotThrow<T>(file: StaticString = #file, line: UInt = #line, column: UInt = #column, _ block: () throws -> T) throws -> T {
    let callSiteInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
    do {
        return try block()
    } catch {
        XCTFail("\(error)", file: callSiteInfo.file, line: callSiteInfo.line)
        throw callSiteInfo.error("Should not have thrown, but did:\n" + "\(error)")
    }
}

public func shouldNotHappen(_ message: String, file: StaticString = #file, line: UInt = #line, column: UInt = #column) -> Error {
    let callSiteInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
    return callSiteInfo.error("Should not happen: \(message)")
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Errors and metadata

public enum ShouldMatcherError: Error {
    case expectedErrorToBeThrown
    case unexpectedErrorWasThrown
}

public struct CallSiteInfo {
    let file: StaticString
    let line: UInt
    let column: UInt
    let appliedAssertionName: String

    init(file: StaticString = #file, line: UInt = #line, column: UInt = #column, function: String = #function) {
        self.file = file
        self.line = line
        self.column = column
        self.appliedAssertionName = String(function[function.startIndex ... function.firstIndex(of: "(")!])
    }
}

extension CallSiteInfo {
    /// Prepares a detailed error, specialized for two values being equal
    ///
    /// - Warning: Performs file IO in order to read source location line where failure happened
    func notEqualError(got it: Any, expected: Any, failTest: Bool = true) -> CallSiteError {
        self.error("[\(it)] does not equal expected: [\(expected)]\n", failTest: failTest)
    }

    /// - Warning: Performs file IO in order to read source location line where failure happened
    func equalError(got it: Any, unexpectedEqual: Any, failTest: Bool = true) -> CallSiteError {
        self.error("[\(it)] does equal: [\(unexpectedEqual)]\n", failTest: failTest)
    }

    /// Returns an Error that should be thrown by the called.
    /// The failure contains the passed in message as well as source location of the call site, for easier locating of the issue.
    public func error(_ message: String, failTest: Bool = true) -> CallSiteError {
        if failTest, !ActorTestKit.isInRepeatableContext() {
            XCTFail(message, file: self.file, line: self.line)
        }

        return CallSiteError(callSite: self, explained: message)
    }
}

public struct CallSiteError: Error, CustomStringConvertible {
    let callSite: CallSiteInfo
    let explained: String

    public init(callSite: CallSiteInfo, explained: String) {
        self.callSite = callSite

        self.explained = explained
    }

    /// Prepares a detailed error information
    ///
    /// - Warning: Performs file IO in order to read source location line where failure happened
    public var description: String {
        guard isTty else {
            return self.explained
        }

        var s = ""
        let lines = try! String(contentsOfFile: "\(self.callSite.file)")
            .components(separatedBy: .newlines)
        let failingLine = lines
            .dropFirst(Int(self.callSite.line - 1))
            .first!

        s += "\n"
        s += "\(failingLine)\n"
        s += "\(String(repeating: " ", count: Int(self.callSite.column) - 1 - self.callSite.appliedAssertionName.count))"
        if isTty {
            s += ANSIColors.red.rawValue
        }
        s += "^\(String(repeating: "~", count: self.callSite.appliedAssertionName.count - 1))\n"
        s += "error: "
        s += self.explained
        s += ANSIColors.reset.rawValue

        return s
    }
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
