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

import Baggage

extension BaggageContext {
    /// Gets the  to thread-local storage to retrieve
    internal static let _current = ThreadSpecificVariable<Box<BaggageContext>>()

    static var current: BaggageContext? {
        get {
            Self._current.currentValue?.value
        } set {
            if let value = newValue {
                Self._current.currentValue = Box(value)
            } else {
                Self._current.currentValue = nil
            }
        }
    }

    static var currentOrEmpty: BaggageContext {
        Self._current.currentValue?.value ?? .init()
    }
}

///// Allows to "box" another value.
// final class Box<T> {
//    let value: T
//    init(_ value: T) { self.value = value }
// }
