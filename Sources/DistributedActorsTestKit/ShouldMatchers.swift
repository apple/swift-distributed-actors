//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import Testing

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
}

extension TestMatchers where T: Equatable {
    public func toEqual(_ expected: T) {
        if self.it != expected {
            let error = self.callSite.notEqualError(got: self.it, expected: expected)
            Issue.record("\(error)", sourceLocation: self.callSite.sourceLocation)
        }
    }

    public func toNotEqual(_ unexpectedEqual: T) {
        if self.it == unexpectedEqual {
            let error = self.callSite.equalError(got: self.it, unexpectedEqual: unexpectedEqual)
            Issue.record("\(error)", sourceLocation: self.callSite.sourceLocation)
        }
    }

    public func toBe<Other>(_ expected: Other.Type) {
        if !(self.it is Other) {
            let error = self.callSite.notEqualError(got: self.it, expected: expected)
            Issue.record("\(error)", sourceLocation: self.callSite.sourceLocation)
        }
    }
}

extension TestMatchers where T: Collection, T.Element: Equatable {
    /// Asserts that `it` starts with the passed in `prefix`.
    ///
    /// If `it` does not completely start with the passed in `prefix`, the error message will also include the a matching
    /// sub-prefix (if any), so one can easier spot at which position the sequences differ.
    public func toStartWith<PossiblePrefix>(prefix: PossiblePrefix) where PossiblePrefix: Collection, T.Element == PossiblePrefix.Element {
        if !self.it.starts(with: prefix) {
            let partialMatch = self.it.commonPrefix(with: prefix)

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
            Issue.record("\(error)", sourceLocation: self.callSite.sourceLocation)
        }
    }

    /// Asserts that `it` ends with the passed in `suffix`.
    public func toEndWith<PossibleSuffix>(suffix: PossibleSuffix) where PossibleSuffix: Collection, T.Element == PossibleSuffix.Element {
        if !self.it.reversed().starts(with: suffix.reversed()) {
            let prefix = self.it.prefix(self.it.count - suffix.count)
            // fancy printout:
            var m = "Expected "
            if isTty { m += "[" }
            m += "\(prefix)"
            m += "\(ANSIColors.bold.rawValue)"
            let itSuffix = self.it.reversed().prefix(suffix.count).reversed().reduce(into: "") { $0 += "\($1)" }
            m += "\(itSuffix)"
            if isTty { m += "\(ANSIColors.reset.rawValue)\(ANSIColors.red.rawValue)" }
            m += "] to end with suffix: "
            if isTty { m += "\(ANSIColors.reset.rawValue)\(ANSIColors.red.rawValue)" }
            m += "\(ANSIColors.bold.rawValue)"
            m += "\(suffix)\n"
            m += "\(ANSIColors.reset.rawValue)\(ANSIColors.red.rawValue)"
            if isTty { m += String(repeating: " ", count: "[error] Expected".count) } // align with the error message prefix
            m += "[\(String(repeating: ".", count: prefix.count))"
            m += "\(ANSIColors.red.rawValue)\(ANSIColors.bold.rawValue)"
            m += "\(suffix)"
            m += "\(ANSIColors.reset.rawValue)\(ANSIColors.red.rawValue)"
            m += "]"
            m += "\(ANSIColors.reset.rawValue)"

            let error = self.callSite.error(m)
            Issue.record("\(error)", sourceLocation: self.callSite.sourceLocation)
        }
    }

    /// Asserts that `it` contains the `el` element.
    public func toContain(_ el: T.Element) {
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
            Issue.record("\(error)", sourceLocation: self.callSite.sourceLocation)
        }
    }

    public func toNotContain(_ el: T.Element) {
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
            Issue.record("\(error)", sourceLocation: self.callSite.sourceLocation)
        }
    }

    /// Asserts that `it` contains at least one element matching the predicate.
    public func toContain(where predicate: (T.Element) -> Bool) {
        if !self.it.contains(where: { el in predicate(el) }) {
            // fancy printout:
            let m = "Expected [\(it)] to contain element matching predicate"

            let error = self.callSite.error(m)
            Issue.record("\(error)", sourceLocation: self.callSite.sourceLocation)
        }
    }
}

extension TestMatchers where T == String {
    /// Asserts that `it` contains the `subString`.
    public func toContain(_ subString: String, negate: Bool = false) {
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
            Issue.record("\(error)", sourceLocation: self.callSite.sourceLocation)
        }
    }

    /// Asserts that `it` does NOT contain the `subString`.
    public func toNotContain(_ subString: String) {
        self.toContain(subString, negate: true)
    }
}

extension TestMatchers where T: Comparable {
    public func toBeLessThan(_ expected: T) {
        if !(self.it < expected) {
            let error = self.callSite.error("\(self.it) is not less than \(expected)")
            #expect(self.it < expected, "\(error)", sourceLocation: self.callSite.sourceLocation)
        }
    }

    public func toBeLessThanOrEqual(_ expected: T) {
        if !(self.it <= expected) {
            let error = self.callSite.error("\(self.it) is not less than or equal \(expected)")
            #expect(self.it <= expected, "\(error)", sourceLocation: self.callSite.sourceLocation)
        }
    }

    public func toBeGreaterThan(_ expected: T) {
        if !(self.it > expected) {
            let error = self.callSite.error("\(self.it) is not greater than \(expected)")
            #expect(self.it > expected, "\(error)", sourceLocation: self.callSite.sourceLocation)
        }
    }

    public func toBeGreaterThanOrEqual(_ expected: T) {
        if !(self.it >= expected) {
            let error = self.callSite.error("\(self.it) is not greater than or equal \(expected)")
            #expect(self.it >= expected, "\(error)", sourceLocation: self.callSite.sourceLocation)
        }
    }
}

extension TestMatchers where T: Collection {
    /// Asserts that `it` is empty
    public func toBeEmpty() {
        if !self.it.isEmpty {
            let m = "Expected [\(it)] to be empty"

            let error = self.callSite.error(m)
            Issue.record("\(error)", sourceLocation: self.callSite.sourceLocation)
        }
    }

    /// Asserts that `it` is not empty
    public func toBeNotEmpty() {
        if self.it.isEmpty {
            let m = "Expected [\(it)] to to be non-empty"

            let error = self.callSite.error(m)
            Issue.record("\(error)", sourceLocation: self.callSite.sourceLocation)
        }
    }
}

extension Collection where Element: Equatable {
    fileprivate func commonPrefix<OtherSequence>(with other: OtherSequence) -> SubSequence where OtherSequence: Collection, Element == OtherSequence.Element {
        var otherIterator = other.makeIterator()
        return self.prefix(while: { el in el == otherIterator.next() })
    }
}

// MARK: assertion extensions on specific types

extension Optional {
    public func shouldBeNil(sourceLocation: SourceLocation = #_sourceLocation) {
        if self != nil {
            let callSite = CallSiteInfo(sourceLocation: sourceLocation, function: #function)
            let error = callSite.error("Expected nil, got [\(String(describing: self))]")
            #expect(self == nil, "\(error)", sourceLocation: callSite.sourceLocation)
        }
    }

    public func shouldNotBeNil(sourceLocation: SourceLocation = #_sourceLocation) {
        if self == nil {
            let callSite = CallSiteInfo(sourceLocation: sourceLocation, function: #function)
            let error = callSite.error("Expected not nil, got [\(String(describing: self))]")
            #expect(self != nil, "\(error)", sourceLocation: callSite.sourceLocation)
        }
    }
}

extension Set {
    public func shouldEqual(_ other: @autoclosure () -> Self, sourceLocation: SourceLocation = #_sourceLocation) {
        let callSiteInfo = CallSiteInfo(sourceLocation: sourceLocation, function: #function)
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

            #expect(
                self == rhs,
                "\(callSiteInfo.error(message))",
                sourceLocation: sourceLocation
            )
        }
    }
}

extension Equatable {
    /// Asserts that the value is equal to the `other` value
    public func shouldEqual(_ other: @autoclosure () -> Self, sourceLocation: SourceLocation = #_sourceLocation) {
        let callSiteInfo = CallSiteInfo(sourceLocation: sourceLocation, function: #function)
        return TestMatchers(it: self, callSite: callSiteInfo).toEqual(other())
    }

    /// Asserts that the value is of the expected Type `T`
    public func shouldBe<T>(_ expectedType: T.Type, sourceLocation: SourceLocation = #_sourceLocation) {
        let callSiteInfo = CallSiteInfo(sourceLocation: sourceLocation, function: #function)
        return TestMatchers(it: self, callSite: callSiteInfo).toBe(expectedType)
    }

    public func shouldNotEqual(_ other: @autoclosure () -> Self, sourceLocation: SourceLocation = #_sourceLocation) {
        let callSiteInfo = CallSiteInfo(sourceLocation: sourceLocation, function: #function)
        return TestMatchers(it: self, callSite: callSiteInfo).toNotEqual(other())
    }
}

extension Hashable {
    /// Asserts that the value is an element in the given set
    public func shouldBeIn(_ set: Set<Self>, sourceLocation: SourceLocation = #_sourceLocation) {
        if set.contains(self) {
            ()
        } else {
            let callSite = CallSiteInfo(sourceLocation: sourceLocation, function: #function)
            let error = callSite.error("Expected \(self) to be an item in \(set)")
            Issue.record("\(error)", sourceLocation: callSite.sourceLocation)
        }
    }
}

extension Bool {
    public func shouldBe(_ expected: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
        let csInfo = CallSiteInfo(sourceLocation: sourceLocation, function: #function)
        return TestMatchers(it: self, callSite: csInfo).toEqual(expected)
    }

    public func shouldBeFalse(sourceLocation: SourceLocation = #_sourceLocation) {
        self.shouldBe(false, sourceLocation: sourceLocation)
    }

    public func shouldBeTrue(sourceLocation: SourceLocation = #_sourceLocation) {
        self.shouldBe(true, sourceLocation: sourceLocation)
    }
}

extension Comparable {
    public func shouldBeLessThan(_ expected: Self, sourceLocation: SourceLocation = #_sourceLocation) {
        let csInfo = CallSiteInfo(sourceLocation: sourceLocation, function: #function)
        return TestMatchers(it: self, callSite: csInfo).toBeLessThan(expected)
    }

    public func shouldBeLessThanOrEqual(_ expected: Self, sourceLocation: SourceLocation = #_sourceLocation) {
        let csInfo = CallSiteInfo(sourceLocation: sourceLocation, function: #function)
        return TestMatchers(it: self, callSite: csInfo).toBeLessThanOrEqual(expected)
    }

    public func shouldBeGreaterThan(_ expected: Self, sourceLocation: SourceLocation = #_sourceLocation) {
        let csInfo = CallSiteInfo(sourceLocation: sourceLocation, function: #function)
        return TestMatchers(it: self, callSite: csInfo).toBeGreaterThan(expected)
    }

    public func shouldBeGreaterThanOrEqual(_ expected: Self, sourceLocation: SourceLocation = #_sourceLocation) {
        let csInfo = CallSiteInfo(sourceLocation: sourceLocation, function: #function)
        return TestMatchers(it: self, callSite: csInfo).toBeGreaterThanOrEqual(expected)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Collection `should*` matchers

extension Collection {
    public func shouldBeEmpty(sourceLocation: SourceLocation = #_sourceLocation) {
        let callSiteInfo = CallSiteInfo(sourceLocation: sourceLocation, function: #function)
        return TestMatchers(it: self, callSite: callSiteInfo).toBeEmpty() // TODO: lazy impl, should get "expected empty" messages etc
    }

    public func shouldBeNotEmpty(sourceLocation: SourceLocation = #_sourceLocation) {
        let callSiteInfo = CallSiteInfo(sourceLocation: sourceLocation, function: #function)
        return TestMatchers(it: self, callSite: callSiteInfo).toBeNotEmpty() // TODO: lazy impl, should get "expected non-empty" messages etc
    }
}

extension Collection where Element: Equatable {
    public func shouldStartWith<PossiblePrefix>(prefix: PossiblePrefix, sourceLocation: SourceLocation = #_sourceLocation)
        where PossiblePrefix: Collection, Element == PossiblePrefix.Element
    {
        let csInfo = CallSiteInfo(sourceLocation: sourceLocation, function: #function)
        return TestMatchers(it: self, callSite: csInfo).toStartWith(prefix: prefix)
    }

    public func shouldEndWith<PossibleSuffix>(suffix: PossibleSuffix, sourceLocation: SourceLocation = #_sourceLocation)
        where PossibleSuffix: Collection, Element == PossibleSuffix.Element
    {
        let csInfo = CallSiteInfo(sourceLocation: sourceLocation, function: #function)
        return TestMatchers(it: self, callSite: csInfo).toEndWith(suffix: suffix)
    }

    public func shouldContain(_ el: Element, sourceLocation: SourceLocation = #_sourceLocation) {
        let csInfo = CallSiteInfo(sourceLocation: sourceLocation, function: #function)
        return TestMatchers(it: self, callSite: csInfo).toContain(el)
    }

    public func shouldNotContain(_ el: Element, sourceLocation: SourceLocation = #_sourceLocation) {
        let csInfo = CallSiteInfo(sourceLocation: sourceLocation, function: #function)
        return TestMatchers(it: self, callSite: csInfo).toNotContain(el)
    }

    /// Applies the `where` predicate while trying to locate at least one element in the collection.
    public func shouldContain(where predicate: (Element) -> Bool, sourceLocation: SourceLocation = #_sourceLocation) {
        let csInfo = CallSiteInfo(sourceLocation: sourceLocation, function: #function)
        return TestMatchers(it: self, callSite: csInfo).toContain(where: { predicate($0) })
    }
}

extension String {
    public func shouldContain(_ el: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let csInfo = CallSiteInfo(sourceLocation: sourceLocation, function: #function)
        return TestMatchers(it: self, callSite: csInfo).toContain(el)
    }

    public func shouldNotContain(_ el: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let csInfo = CallSiteInfo(sourceLocation: sourceLocation, function: #function)
        return TestMatchers(it: self, callSite: csInfo).toNotContain(el)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Free `should*` functions

public func shouldThrow<E: Error, T>(expected: E.Type, sourceLocation: SourceLocation = #_sourceLocation, _ block: () throws -> T) throws {
    let callSiteInfo = CallSiteInfo(sourceLocation: sourceLocation, function: #function)
    let error = try shouldThrow(sourceLocation: sourceLocation, block)

    guard error is E else {
        let error = callSiteInfo.error("Expected block to throw [\(expected)], but threw: [\(error)]")
        Issue.record("\(error)", sourceLocation: callSiteInfo.sourceLocation)
        throw error
    }
}

/// If this function throws, the wrapped block did NOT throw.
@discardableResult
public func shouldThrow<T>(sourceLocation: SourceLocation = #_sourceLocation, _ block: () throws -> T) throws -> Error {
    let callSiteInfo = CallSiteInfo(sourceLocation: sourceLocation, function: #function)
    var it: T?
    do {
        it = try block()
    } catch {
        return error
    }

    let error = callSiteInfo.error("Expected block to throw, but returned: [\(it!)]")
    Issue.record("\(error)", sourceLocation: callSiteInfo.sourceLocation)
    throw error
}

/// If this function throws, the wrapped block did NOT throw.
@discardableResult
public func shouldThrow<T>(sourceLocation: SourceLocation = #_sourceLocation, _ block: () async throws -> T) async throws -> Error {
    let callSiteInfo = CallSiteInfo(sourceLocation: sourceLocation, function: #function)
    var it: T?
    do {
        it = try await block()
    } catch {
        return error
    }

    let error = callSiteInfo.error("Expected block to throw, but returned: [\(it!)]")
    Issue.record("\(error)", sourceLocation: callSiteInfo.sourceLocation)
    throw error
}

/// Provides improved error logging in case of an unexpected throw.
/// XCTest output without wrapping in shouldNotThrow:
///
/// ```
///   <unknown>:0: error: -[DistributedActorsTests.ActorLifecycleTests test_beAbleToStop_immediately] :
///   failed: caught error: The operation couldn’t be completed. (DistributedCluster.ActorPathError error 0.)
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
public func shouldNotThrow<T>(sourceLocation: SourceLocation = #_sourceLocation, _ block: () async throws -> T) async throws -> T {
    let callSiteInfo = CallSiteInfo(sourceLocation: sourceLocation, function: #function)
    do {
        return try await block()
    } catch {
        Issue.record("\(error)", sourceLocation: callSiteInfo.sourceLocation)
        throw callSiteInfo.error("Should not have thrown, but did:\n" + "\(error)")
    }
}

public func shouldNotThrow<T>(sourceLocation: SourceLocation = #_sourceLocation, _ block: () throws -> T) throws -> T {
    let callSiteInfo = CallSiteInfo(sourceLocation: sourceLocation, function: #function)
    do {
        return try block()
    } catch {
        Issue.record("\(error)", sourceLocation: callSiteInfo.sourceLocation)
        throw callSiteInfo.error("Should not have thrown, but did:\n" + "\(error)")
    }
}

public func shouldNotHappen(_ message: String, sourceLocation: SourceLocation = #_sourceLocation) -> Error {
    let callSiteInfo = CallSiteInfo(sourceLocation: sourceLocation, function: #function)
    return callSiteInfo.error("Should not happen: \(message)")
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Errors and metadata

public enum ShouldMatcherError: Error {
    case expectedErrorToBeThrown
    case unexpectedErrorWasThrown
}

public struct CallSiteInfo: Sendable {
    public let sourceLocation: Testing.SourceLocation
    public let appliedAssertionName: String

    init(sourceLocation: SourceLocation = #_sourceLocation, function: String = #function) {
        self.sourceLocation = sourceLocation
        self.appliedAssertionName = String(function[function.startIndex ... function.firstIndex(of: "(")!])
    }
}

extension CallSiteInfo {
    /// Prepares a detailed error, specialized for two values being equal
    ///
    /// - Warning: Performs file IO in order to read source location line where failure happened
    func notEqualError(got it: Any, expected: Any, failTest: Bool = true) -> CallSiteError {
        let padding = String(repeating: " ", count: "[error]".count)
        return self.error("""
        [\(it)] 
        does not equal expected:
        \(padding)[\(expected)]\n
        """, failTest: failTest)
    }

    /// - Warning: Performs file IO in order to read source location line where failure happened
    func equalError(got it: Any, unexpectedEqual: Any, failTest: Bool = true) -> CallSiteError {
        self.error("[\(it)] does equal: [\(unexpectedEqual)]\n", failTest: failTest)
    }

    /// Returns an Error that should be thrown by the called.
    /// The failure contains the passed in message as well as source location of the call site, for easier locating of the issue.
    public func error(_ message: String, failTest: Bool = true) -> CallSiteError {
        if failTest, !ActorTestKit.isInRepeatableContext() {
            Issue.record(.init(rawValue: message), sourceLocation: self.sourceLocation)
        }

        return CallSiteError(callSite: self, explained: message)
    }

    /// Prepares a detailed error, specialized for a prefix mismatch of a string
    ///
    /// - Warning: Performs file IO in order to read source location line where failure happened
    func notMatchingPrefixError(got it: any StringProtocol, expected: any StringProtocol, failTest: Bool = true) -> CallSiteError {
        let padding = String(repeating: " ", count: "[error]".count)
        return self.error("""
        [\(it)]
        does start with expected prefix:
        \(padding)[\(expected)]\n
        """, failTest: failTest)
    }
}

/// An error type with additional ``CallSiteInfo`` which is able to pretty print failures.
/// It is useful for printing complex failures on the command line and is usually thrown by `should` matchers.
public struct CallSiteError: Error, CustomStringConvertible {
    public let callSite: CallSiteInfo
    public let explained: String

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
        let lines = try! String(contentsOfFile: "\(self.callSite.sourceLocation.fileID)")
            .components(separatedBy: .newlines)
        let failingLine = lines
            .dropFirst(Int(self.callSite.sourceLocation.line - 1))
            .first!

        s += "\n"
        s += "\(failingLine)\n"
        s += "\(String(repeating: " ", count: Int(self.callSite.sourceLocation.column) - 1 - self.callSite.appliedAssertionName.count))"
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
