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
import Logging

@usableFromInline
final class ThreadLocalActorContext {
    @usableFromInline
    static let _current = ThreadSpecificVariable<AnyActorContext>()

    @usableFromInline
    static var current: AnyActorContext? {
        get {
            Self._current.currentValue
        }
        set {
            Self._current.currentValue = newValue
        }
    }
}
