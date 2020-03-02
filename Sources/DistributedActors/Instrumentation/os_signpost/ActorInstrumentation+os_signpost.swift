//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if os(macOS) || os(tvOS) || os(iOS) || os(watchOS)
import Foundation
import os.log
import os.signpost

@available(OSX 10.14, *)
@available(iOS 10.0, *)
@available(tvOS 10.0, *)
@available(watchOS 3.0, *)
public struct OSSignpostActorInstrumentation: ActorInstrumentation {
    static let logLifecycle = OSLog(subsystem: "com.apple.actors", category: "Lifecycle")
    static let logMessages = OSLog(subsystem: "com.apple.actors", category: "Messages")

    let address: ActorAddress
    let signpostID: OSSignpostID

    public init(id: AnyObject, address: ActorAddress) {
        self.address = address
        self.signpostID = OSSignpostID(
            log: OSSignpostActorInstrumentation.logMessages,
            object: id
        )
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Instrumentation: Actor Lifecycle

@available(OSX 10.14, *)
@available(iOS 10.0, *)
@available(tvOS 10.0, *)
@available(watchOS 3.0, *)
extension OSSignpostActorInstrumentation {
    public func actorSpawned() {
        guard OSSignpostActorInstrumentation.logLifecycle.signpostsEnabled else {
            return
        }

        guard !self.address.name.hasPrefix("$ask") else {
            // don't track ask actor's int spawned etc, since they should eventually go away
            // ask timings are to be found in the Asks instrument
            return
        }

        let format: StaticString = "spawned,address:%{public}s"

        os_signpost(
            .event,
            log: OSSignpostActorInstrumentation.logLifecycle,
            name: "Actor Lifecycle",
            signpostID: self.signpostID,
            format,
            "\(self.address)"
        )

        os_signpost(
            .begin,
            log: OSSignpostActorInstrumentation.logLifecycle,
            name: "Actor Lifecycle",
            signpostID: self.signpostID,
            format,
            "\(self.address)"
        )
    }

    public func actorStopped() {
        guard OSSignpostActorInstrumentation.logLifecycle.signpostsEnabled else {
            return
        }

        guard !self.address.name.hasPrefix("$ask") else {
            // don't track ask actor's int spawned etc, since they should eventually go away
            // ask timings are to be found in the Asks instrument
            return
        }

        os_signpost(
            .end,
            log: OSSignpostActorInstrumentation.logLifecycle,
            name: "Actor Lifecycle",
            signpostID: self.signpostID,
            "stopped,reason:%{public}s",
            "stop"
        )
    }

    public func actorFailed(failure: Supervision.Failure) {
        guard OSSignpostActorInstrumentation.logLifecycle.signpostsEnabled else {
            return
        }

        guard !self.address.name.hasPrefix("$ask") else {
            // don't track ask actor's int spawned etc, since they should eventually go away
            // ask timings are to be found in the Asks instrument
            return
        }

        os_signpost(
            .end,
            log: OSSignpostActorInstrumentation.logLifecycle,
            name: "Actor Lifecycle",
            signpostID: self.signpostID,
            "stopped,reason:%{public}s",
            "\(failure)"
        )
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Instrumentation: Actor Messages

@available(OSX 10.14, *)
@available(iOS 10.0, *)
@available(tvOS 10.0, *)
@available(watchOS 3.0, *)
extension OSSignpostActorInstrumentation {
    public func actorMailboxRunStarted(mailboxCount: Int) {}

    public func actorMailboxRunCompleted(processed: Int) {}

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Actor Messages: Tell

    // FIXME: we need the sender() to attach properly
    public func actorTold(message: Any, from: ActorAddress?) {
        guard OSSignpostActorInstrumentation.logMessages.signpostsEnabled else {
            return
        }

        os_signpost(
            .event,
            log: OSSignpostActorInstrumentation.logMessages,
            name: "Actor Message (Tell)",
            signpostID: self.signpostID,
            "actor-message-told,recipient:%{public}s,sender:%{public}s,type:%{public}s,message:%{public}s",
            "\(self.address)", "\(from.map { "\($0)" } ?? "<no-sender>")", String(reflecting: type(of: message)), "\(message)"
        )
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Actor Messages: Ask

    public func actorAsked(message: Any, from: ActorAddress?) {
        guard OSSignpostActorInstrumentation.logMessages.signpostsEnabled else {
            return
        }

        os_signpost(
            .begin,
            log: OSSignpostActorInstrumentation.logMessages,
            name: "Actor Message (Ask)",
            signpostID: self.signpostID,
            "actor-message-asked,recipient:%{public}s,sender:%{public}s,question:%{public}s,type:%{public}s",
            "\(self.address)", "\(from.map { "\($0)" } ?? "<no-sender>")", "\(message)", String(reflecting: type(of: message))
        )
    }

    public func actorAskReplied(reply: Any?, error: Error?) {
        guard OSSignpostActorInstrumentation.logMessages.signpostsEnabled else {
            return
        }

        let format: StaticString = "actor-message-ask-answered,answer:%{public}s,type:%{public}s,error:%{public}s,type:%{public}s"

        if let error = error {
            os_signpost(
                .end,
                log: OSSignpostActorInstrumentation.logMessages,
                name: "Actor Message (Ask)",
                signpostID: self.signpostID,
                format,
                "", "", "\(error)", String(reflecting: type(of: error))
            )
            return
        }

        guard let message = reply else {
            os_signpost(
                .end,
                log: OSSignpostActorInstrumentation.logMessages,
                name: "Actor Message (Ask)",
                signpostID: self.signpostID,
                format,
                "", "", "", ""
            )
            return
        }

        os_signpost(
            .end,
            log: OSSignpostActorInstrumentation.logMessages,
            name: "Actor Message (Ask)",
            signpostID: self.signpostID,
            format,
            "\(message)", String(reflecting: type(of: message)), "", ""
        )
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Actor Messages: Receive

    public func actorReceivedStart(message: Any, from: ActorAddress?) {
        guard OSSignpostActorInstrumentation.logMessages.signpostsEnabled else {
            return
        }

        os_signpost(
            .event,
            log: OSSignpostActorInstrumentation.logMessages,
            name: "Actor Message (Received)",
            signpostID: self.signpostID,
            "actor-message-received,recipient:%{public}s,sender:%{public}s,message:%{public}s,type:%{public}s",
            "\(self.address)", "\(from.map { "\($0)" } ?? "<no-sender>")", "\(message)", String(reflecting: type(of: message))
        )
    }

    public func actorReceivedEnd(error: Error?) {
        // TODO: make interval so we know the length of how long an actor processes a message
    }
}

#endif
