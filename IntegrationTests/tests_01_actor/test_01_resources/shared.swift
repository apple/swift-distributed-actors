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
import DistributedActors

// Just consume the argument.
// It's important that this function is in another module than the tests
// which are using it.
@inline(never)
public func blackHole<T>(_ x: T) {
}

// Return the passed argument without letting the optimizer know that.
@inline(never)
public func identity<T>(_ x: T) -> T {
    return x
}

// Return the passed argument without letting the optimizer know that.
// It's important that this function is in another module than the tests
// which are using it.
@inline(never)
public func getInt(_ x: Int) -> Int { return x }

// The same for String.
@inline(never)
public func getString(_ s: String) -> String { return s }

// The same for Substring.
@inline(never)
public func getSubstring(_ s: Substring) -> Substring { return s }

func withAutoReleasePool<T>(_ execute: () throws -> T) rethrows -> T {
    #if os(Linux)
    return try execute()
    #else
    return try autoreleasepool {
        try execute()
    }
    #endif
}
