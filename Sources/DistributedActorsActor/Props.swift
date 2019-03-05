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

import NIO

/// `Props` configure an Actors' properties such as mailbox, dispatcher as well as supervision semantics.
///
/// `Props` can easily changed in-line using the fluent APIs provided.
/// Functions starting with `add...` are additive, i.e. they add another setting of the same kind to the props (possibly
/// overriding a previously existing one), while functions starting with `with...` are replacement functions, always
/// replacing the entire inner props with the new one
///
/// Naming mnemonic: "Props" are what an theater actor may use during a performance.
/// For example, a skull would be a classic example of a "prop" used while performing the William Shakespeare's
/// Hamlet Act III, scene 1, saying "To be, or not to be, that is the question: [...]." In the same sense,
/// props for Swift Distributed Actors actors are accompanying objects/settings, which help the actor perform its duties.
public struct Props {

    public var mailbox: MailboxProps
    public var dispatcher: DispatcherProps

    public var supervision: SupervisionProps

    public init(mailbox: MailboxProps, dispatcher: DispatcherProps, supervision: SupervisionProps) {
        self.mailbox = mailbox
        self.dispatcher = dispatcher
        self.supervision = supervision
    }

    public init() {
        self.init(mailbox: .default(), dispatcher: .default, supervision: .init())
    }

}

// MARK: Dispatcher Props

// TODO: likely better as class hierarchy, by we'll see...

public extension Props {
    /// Creates a new `Props` with default values, and overrides the `dispatcher` with the provided one.
    public static func withDispatcher(_ dispatcher: DispatcherProps) -> Props {
        var props = Props()
        props.dispatcher = dispatcher
        return props
    }
    /// Creates copy of this `Props` changing the dispatcher props, useful for setting a few options in-line when spawning actors.
    public func withDispatcher(_ dispatcher: DispatcherProps) -> Props {
        var props = self
        props.dispatcher = dispatcher
        return props
    }
}

/// Configuring dispatchers should only be associated with actual research if the change is indeed beneficial.
/// In the vast majority of cases the default thread pool backed implementation should perform the best for typical workloads.
// TODO Eventually: probably also best as not enum but a bunch of factories?
public enum DispatcherProps {

    /// Lets runtime determine the default dispatcher
    case `default`

    //    /// Use the Dispatch library as underlying executor.
    //    case dispatch(qosClass: Dispatch.DispatchQoS.QoSClass) // TODO: we want diff actors to be able to run on diff priorities, thus this setting

    // TODO: definitely good, though likely not as first thing We can base it on Akka's recent "Affinity" one,
    // though in Akka we had a hard time really proving that it outperforms the FJP since here we have no FJP readily available, and the Affinity one is much simpler,
    // I'd rather implement such style, as it actually is build "for" actors, and not accidentally running them well...
    // case OurOwnFancyActorSpecificDispatcher

    /// WARNING: Use with Caution!
    ///
    /// This dispatcher will keep a real dedicated Thread for this actor. This is very rarely something you want,
    // unless designing an actor that is intended to spin without others interrupting it on some resource and may block on it etc.
    case pinnedThread // TODO implement pinned thread dispatcher

    /// WARNING: Use with Caution!
    ///
    /// Allows binding an actor to an `EventLoopGroup` or a specific `EventLoop` itself.
    /// For most actors this should not matter, however it may show some benefit if interacting with many Futures
    /// fired on a specific `EventLoop`, for reasons of "locality" to where the events are fired (when on the same exact event loop).
    // TODO not extensively tested but should just-work™ since we treat NIO as plain thread pool basically here.
    // TODO not sure if we'd need this or not in reality, we'll see... executing futures safely would be more interesting perhaps
    case nio(NIO.EventLoopGroup)

    // TODO or hide it completely somehow; too dangerous
    /// WARNING: Use with Caution!
    ///
    /// Dispatcher which hijacks the calling thread to schedule execution.
    case callingThread
}

// MARK: Mailbox Props

extension Props {
    /// Creates a new `Props` with default values, and overrides the `mailbox` with the provided one.
    public static func withMailbox(_ mailbox: MailboxProps) -> Props {
        var props = Props()
        props.mailbox = mailbox
        return props
    }
    /// Creates copy of this `Props` changing the `mailbox` props.
    public func withMailbox(_ mailbox: MailboxProps) -> Props {
        var props = self
        props.mailbox = mailbox
        return props
    }
}

public enum MailboxProps {
    /// Default mailbox.
    case `default`(capacity: UInt32, onOverflow: MailboxOverflowStrategy)

    static func `default`(capacity: UInt32 = UInt32.max) -> MailboxProps {
        return .default(capacity: capacity, onOverflow: .crash)
    }
    
    var capacity: UInt32 {
        switch self {
        case let .default(cap, _): return cap
        }
    }
}

// TODO: those only apply when bounded mailboxes
public enum MailboxOverflowStrategy {
    case crash
    case dropIncoming
    case dropMailbox
}
