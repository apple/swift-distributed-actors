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
    static let subsystem: StaticString = "com.apple.actors"

    static let categoryLifecycle: StaticString = "Lifecycle"
    static let categoryMessages: StaticString = "Messages"

    static let logLifecycle = OSLog(subsystem: "\(Self.subsystem)", category: "\(Self.categoryLifecycle)")
    static let logMessages = OSLog(subsystem: "\(Self.subsystem)", category: "\(Self.categoryMessages)")

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
    static let actorSpawnedStartFormat: StaticString =
        """
        spawned;\
        node:%{public}s;\
        path:%{public}s
        """
    static let actorSpawnedEndFormat: StaticString =
        """
        stopped;\
        reason:%{public}s
        """

    public func actorSpawned() {
        guard OSSignpostActorInstrumentation.logLifecycle.signpostsEnabled else {
            return
        }

        guard !self.address.name.hasPrefix("$ask") else {
            // don't track ask actor's int spawned etc, since they should eventually go away
            // ask timings are to be found in the Asks instrument
            return
        }

        os_signpost(
            .event,
            log: OSSignpostActorInstrumentation.logLifecycle,
            name: "Actor Lifecycle",
            signpostID: self.signpostID,
            Self.actorSpawnedStartFormat,
            "\(self.address.node?.description ?? "")", "\(self.address.path)"
        )

        os_signpost(
            .begin,
            log: OSSignpostActorInstrumentation.logLifecycle,
            name: "Actor Lifecycle",
            signpostID: self.signpostID,
            Self.actorSpawnedStartFormat,
            "\(self.address.node?.description ?? "")", "\(self.address.path)"
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
            Self.actorSpawnedEndFormat,
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
            Self.actorSpawnedEndFormat,
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
    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Mailbox

    public func actorMailboxRunStarted(mailboxCount: Int) {}

    public func actorMailboxRunCompleted(processed: Int) {}

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Actor Messages: Tell

    static let actorToldEventPattern: StaticString =
        """
        actor-message-told;\
        recipient-node:%{public}s;\
        recipient-path:%{public}s;\
        sender-node:%{public}s;\
        sender-path:%{public}s;\
        message:%{public}s;\
        message-type:%{public}s
        """

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
            Self.actorToldEventPattern,
            "\(self.address.node?.description ?? "")", "\(self.address.path)",
            "\(from?.node?.description ?? "")", "\(from?.path.description ?? "")",
            "\(message)", String(reflecting: type(of: message))
        )
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Actor Messages: Ask

    static let signpostNameActorAsk: StaticString =
        "Actor Message (Ask)"

    static let actorAskedEventPattern: StaticString =
        """
        actor-message-asked;\
        recipient-node:%{public}s;\
        recipient-path:%{public}s;\
        sender-node:%{public}s;\
        sender-path:%{public}s;\
        question:%{public}s;\
        question-type:%{public}s
        """

    static let actorAskRepliedEventPattern: StaticString =
        """
        actor-message-ask-answered;\
        answer:%{public}s;\
        answer-type:%{public}s;\
        error:%{public}s;\
        error-type:%{public}s
        """

    public func actorAsked(message: Any, from: ActorAddress?) {
        guard OSSignpostActorInstrumentation.logMessages.signpostsEnabled else {
            return
        }

        os_signpost(
            .begin,
            log: OSSignpostActorInstrumentation.logMessages,
            name: "Actor Message (Ask)",
            signpostID: self.signpostID,
            Self.actorAskedEventPattern,
            "\(self.address.node?.description ?? "")", "\(self.address.path)",
            "\(from?.node?.description ?? "")", "\(from?.path.description ?? "")",
            "\(message)", String(reflecting: type(of: message))
        )
    }

    public func actorAskReplied(reply: Any?, error: Error?) {
        guard OSSignpostActorInstrumentation.logMessages.signpostsEnabled else {
            return
        }

        if let error = error {
            os_signpost(
                .end,
                log: OSSignpostActorInstrumentation.logMessages,
                name: Self.signpostNameActorAsk,
                signpostID: self.signpostID,
                Self.actorAskRepliedEventPattern,
                "", "", "\(error)", String(reflecting: type(of: error))
            )
            return
        }

        guard let message = reply else {
            os_signpost(
                .end,
                log: OSSignpostActorInstrumentation.logMessages,
                name: Self.signpostNameActorAsk,
                signpostID: self.signpostID,
                Self.actorAskRepliedEventPattern,
                "", "", "", ""
            )
            return
        }

        os_signpost(
            .end,
            log: OSSignpostActorInstrumentation.logMessages,
            name: Self.signpostNameActorAsk,
            signpostID: self.signpostID,
            Self.actorAskRepliedEventPattern,
            "\(message)", String(reflecting: type(of: message)), "", ""
        )
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Actor Messages: Receive

    public static let actorReceivedEventPattern: StaticString =
        """
        actor-message-received;\
        recipient-node:%{public}s;\
        recipient-path:%{public}s;\
        sender-node:%{public}s;\
        sender-path:%{public}s;\
        message:%{public}s;\
        message-type:%{public}s
        """

    public func actorReceivedStart(message: Any, from: ActorAddress?) {
        guard OSSignpostActorInstrumentation.logMessages.signpostsEnabled else {
            return
        }

        os_signpost(
            .event,
            log: OSSignpostActorInstrumentation.logMessages,
            name: "Actor Message (Received)",
            signpostID: self.signpostID,
            Self.actorReceivedEventPattern,
            "\(self.address.node?.description ?? "")",
            "\(self.address.path)",
            "\(from?.node?.description ?? "")",
            "\(from?.path.description ?? "")",
            "\(message)",
            String(reflecting: type(of: message))
        )
    }

    public func actorReceivedEnd(error: Error?) {
        // TODO: make interval so we know the length of how long an actor processes a message
    }
}

#endif
