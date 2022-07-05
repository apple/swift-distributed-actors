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

#if os(Linux)
import Glibc
#else
import Darwin
#endif

extension BenchmarkCategory: CustomStringConvertible {
    public var description: String {
        self.rawValue
    }
}

extension BenchmarkCategory: Comparable {
    public static func < (lhs: BenchmarkCategory, rhs: BenchmarkCategory) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct BenchmarkPlatformSet: OptionSet {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let darwin = BenchmarkPlatformSet(rawValue: 1 << 0)
    public static let linux = BenchmarkPlatformSet(rawValue: 1 << 1)

    public static var currentPlatform: BenchmarkPlatformSet {
        #if os(Linux)
        return .linux
        #else
        return .darwin
        #endif
    }

    public static var allPlatforms: BenchmarkPlatformSet {
        [.darwin, .linux]
    }
}

public struct BenchmarkInfo {
    /// The name of the benchmark that should be displayed by the harness.
    public var name: String

    /// Shadow static variable for runFunction.
    private var _runFunction: (Int) -> Void

    /// A function that invokes the specific benchmark routine.
    public var runFunction: ((Int) -> Void)? {
        if !self.shouldRun {
            return nil
        }
        return self._runFunction
    }

    /// A set of category tags that describe this benchmark. This is used by the
    /// harness to allow for easy slicing of the set of benchmarks along tag
    /// boundaries, e.x.: run all string benchmarks or ref count benchmarks, etc.
    public var tags: Set<BenchmarkCategory>

    /// The platforms that this benchmark supports. This is an OptionSet.
    private var unsupportedPlatforms: BenchmarkPlatformSet

    /// Shadow variable for setUpFunction.
    private var _setUpFunction: (() async -> Void)?

    /// An optional function that if non-null is run before benchmark samples
    /// are timed.
    public var setUpFunction: (() async -> Void)? {
        if !self.shouldRun {
            return nil
        }
        return self._setUpFunction
    }

    /// Shadow static variable for computed property tearDownFunction.
    private var _tearDownFunction: (() -> Void)?

    /// An optional function that if non-null is run after samples are taken.
    public var tearDownFunction: (() -> Void)? {
        if !self.shouldRun {
            return nil
        }
        return self._tearDownFunction
    }

    public var legacyFactor: Int?

    public init(
        name: String, runFunction: @escaping (Int) -> Void, tags: [BenchmarkCategory],
        setUpFunction: (() async -> Void)? = nil,
        tearDownFunction: (() -> Void)? = nil,
        unsupportedPlatforms: BenchmarkPlatformSet = [],
        legacyFactor: Int? = nil
    ) {
        self.name = name
        self._runFunction = runFunction
        self.tags = Set(tags)
        self._setUpFunction = setUpFunction
        self._tearDownFunction = tearDownFunction
        self.unsupportedPlatforms = unsupportedPlatforms
        self.legacyFactor = legacyFactor
    }

    /// Returns true if this benchmark should be run on the current platform.
    var shouldRun: Bool {
        !self.unsupportedPlatforms.contains(.currentPlatform)
    }
}

extension BenchmarkInfo: Comparable {
    public static func < (lhs: BenchmarkInfo, rhs: BenchmarkInfo) -> Bool {
        lhs.name < rhs.name
    }

    public static func == (lhs: BenchmarkInfo, rhs: BenchmarkInfo) -> Bool {
        lhs.name == rhs.name
    }
}

extension BenchmarkInfo: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.name)
    }
}

// Linear function shift register.
//
// This is just to drive benchmarks. I don't make any claim about its
// strength. According to Wikipedia, it has the maximal period for a
// 32-bit register.
struct LFSR {
    // Set the register to some seed that I pulled out of a hat.
    var lfsr: UInt32 = 0xB789_78E7

    mutating func shift() {
        self.lfsr = (self.lfsr >> 1) ^ (UInt32(bitPattern: -Int32(self.lfsr & 1)) & 0xD000_0001)
    }

    mutating func randInt() -> Int64 {
        var result: UInt32 = 0
        for _ in 0 ..< 32 {
            result = (result << 1) | (self.lfsr & 1)
            self.shift()
        }
        return Int64(bitPattern: UInt64(result))
    }
}

var lfsrRandomGenerator = LFSR()

// Start the generator from the beginning
public func SRand() {
    lfsrRandomGenerator = LFSR()
}

public func Random() -> Int64 {
    lfsrRandomGenerator.randInt()
}

@inlinable // FIXME(inline-always)
@inline(__always)
public func CheckResults(
    _ resultsMatch: Bool,
    file: StaticString = #filePath,
    function: StaticString = #function,
    line: Int = #line
) {
    guard _fastPath(resultsMatch) else {
        print("Incorrect result in \(function), \(file):\(line)")
        abort()
    }
}

public func False() -> Bool { false }

/// This is a dummy protocol to test the speed of our protocol dispatch.
public protocol SomeProtocol { func getValue() -> Int }
struct MyStruct: SomeProtocol {
    init() {}
    func getValue() -> Int { 1 }
}

public func someProtocolFactory() -> SomeProtocol { MyStruct() }

// Just consume the argument.
// It's important that this function is in another module than the tests
// which are using it.
@inline(never)
public func blackHole<T>(_: T) {}

// Return the passed argument without letting the optimizer know that.
@inline(never)
public func identity<T>(_ x: T) -> T {
    x
}

// Return the passed argument without letting the optimizer know that.
// It's important that this function is in another module than the tests
// which are using it.
@inline(never)
public func getInt(_ x: Int) -> Int { x }

// The same for String.
@inline(never)
public func getString(_ s: String) -> String { s }

// The same for Substring.
@inline(never)
public func getSubstring(_ s: Substring) -> Substring { s }
