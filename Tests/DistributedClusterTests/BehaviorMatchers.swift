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

@testable import DistributedCluster
import DistributedActorsTestKit
import XCTest

/// Internal testing extensions allowing inspecting behavior internals
extension _Behavior {
    /// Similar to canonicalize but counts the nesting depth, be it in setup calls or interceptors.
    ///
    // TODO: Implemented recursively and may stack overflow on insanely deep structures.
    // TODO: not all cases are covered, only enough to implement specific tests currently is.
    internal func nestingDepth(context: _ActorContext<Message>) throws -> Int {
        func nestingDepth0(_ b: _Behavior<Message>) throws -> Int {
            switch b.underlying {
            case .setup(let onStart):
                return try 1 + nestingDepth0(onStart(context))
            case .intercept(let inner, _):
                return try 1 + nestingDepth0(inner)
            case .signalHandling(let onMessage, _),
                 .signalHandlingAsync(let onMessage, _):
                return try 1 + nestingDepth0(onMessage)
            case .orElse(let first, let other):
                return 1 + max(try nestingDepth0(first), try nestingDepth0(other))
            case .suspended(let previousBehavior, _):
                return try 1 + nestingDepth0(previousBehavior)
            case .same,
                 .receive, .receiveAsync,
                 .receiveMessage, .receiveMessageAsync,
                 .stop, .failed, .unhandled, .ignore, .suspend:
                return 1
            }
        }

        return try nestingDepth0(self)
    }

    /// Pretty prints current behavior, unwrapping and executing any deferred wrappers such as `.setup`.
    /// The output is multi line "pretty" string representation of all the nested behaviors, e.g.:
    ///
    ///      intercept(interceptor:DistributedCluster.StoppingSupervisor<Swift.String>
    //         receiveMessage((Function))
    //       )
    // TODO: Implemented recursively and may stack overflow on insanely deep structures.
    // TODO: not all cases are covered, only enough to implement specific tests currently is.
    internal func prettyFormat(context: _ActorContext<Message>, padWith padding: String = "  ") throws -> String {
        func prettyFormat0(_ b: _Behavior<Message>, depth: Int) throws -> String {
            let pad = String(repeating: padding, count: depth)

            switch b.underlying {
            case .setup(let onStart):
                return "\(pad)setup(\n" +
                    (try prettyFormat0(onStart(context), depth: depth + 1)) +
                    "\(pad))\n"

            case .intercept(let inner, let interceptor):
                return "\(pad)intercept(interceptor:\(interceptor)\n" +
                    (try prettyFormat0(inner, depth: depth + 1)) +
                    "\(pad))\n"
            case .signalHandling(let handleMessage, let handleSignal):
                return "\(pad)signalHandling(handleSignal:\(String(describing: handleSignal))\n" +
                    (try prettyFormat0(handleMessage, depth: depth + 1)) +
                    "\(pad))\n"
            case .signalHandlingAsync(let handleMessage, let handleSignalAsync):
                return "\(pad)signalHandlingAsync(handleSignal:\(String(describing: handleSignalAsync))\n" +
                    (try prettyFormat0(handleMessage, depth: depth + 1)) +
                    "\(pad))\n"
            case .orElse(let first, let second):
                return "\(pad)orElse(\n" +
                    (try prettyFormat0(first, depth: depth + 1)) +
                    (try prettyFormat0(second, depth: depth + 1)) +
                    "\(pad))\n"
            case .suspended(let previousBehavior, _):
                return "\(pad)suspended(\n" +
                    (try prettyFormat0(previousBehavior, depth: depth + 1)) +
                    "\(pad))\n"
            case .same,
                 .receive, .receiveAsync,
                 .receiveMessage, .receiveMessageAsync,
                 .stop, .failed, .unhandled, .ignore, .suspend:
                return "\(pad)\(b)\n"
            }
        }

        return try prettyFormat0(self, depth: 0)
    }
}
