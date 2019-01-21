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

import XCTest
import Swift Distributed ActorsActor
import SwiftDistributedActorsActorTestKit


/// Internal testing extensions allowing inspecting behavior internals
internal extension Behavior {

    /// Similar to canonicalize but counts the nesting depth, be it in setup calls or interceptors.
    ///
    /// TODO: Implemented recursively and may stack overflow on insanely deep structures.
    /// TODO: not all cases are covered, only enough to implement specific tests currently is.
    func nestingDepth(context: ActorContext<Message>) throws -> Int {
        func nestingDepth0(_ b: Behavior<Message>) throws -> Int {
            switch b {
            case .setup(let onStart):
                return try 1 + nestingDepth0(onStart(context))
            case .intercept(let inner, let interceptor):
                return try 1 + nestingDepth0(inner)
            case .receive, .receiveMessage, .stopped, .unhandled, .ignore, .custom:
                return 1
            }
        }

        return try nestingDepth0(self)
    }

    /// Pretty prints current behavior, unwrapping and executing any deferred wrappers such as `.setup`.
    /// The output is multi line "pretty" string representation of all the nested behaviors, e.g.:
    ///
    ///      intercept(interceptor:Swift Distributed ActorsActor.StoppingSupervisor<Swift.String>
    //         receiveMessage((Function))
    //       )
    /// TODO: Implemented recursively and may stack overflow on insanely deep structures.
    /// TODO: not all cases are covered, only enough to implement specific tests currently is.
    func prettyFormat(context: ActorContext<Message>, padWith padding: String = "  ") throws -> String {
        func prettyFormat0(_ b: Behavior<Message>, depth: Int) throws -> String {
            let pad = String(repeating: padding, count: depth)

            switch b {
            case .setup(let onStart):
                return "\(pad)setup(\n" +
                    (try prettyFormat0(onStart(context), depth: depth + 1)) +
                    "\(pad))\n"

            case .intercept(let inner, let interceptor):
                return "\(pad)intercept(interceptor:\(interceptor)\n" +
                    (try prettyFormat0(inner, depth: depth + 1)) +
                    "\(pad))\n"

            case .receive, .receiveMessage, .stopped, .unhandled, .ignore, .custom:
                return "\(pad)\(b)\n"
            }
        }

        return try prettyFormat0(self, depth: 0)
    }
}
