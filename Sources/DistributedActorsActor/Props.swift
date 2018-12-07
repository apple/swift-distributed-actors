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

import Dispatch // TODO: I suppose we'll end up supporting it anyway, only modeling it for now tho

/// Props configure an Actors' properties such as mailbox and dispatcher semantics.
///
/// Mnemonic: "props" are what an actor in real life uses when acting on stage,
///           e.g. a skull that would be used for "to be, or, not to be?
public struct Props {

    let mailbox: MailboxProps
    let dispatcher: DispatcherProps

    let faultDomain: FaultDomainProps

    public init(mailbox: MailboxProps, dispatcher: DispatcherProps, faultDomain: FaultDomainProps) {
        self.mailbox = mailbox
        self.dispatcher = dispatcher
        self.faultDomain = faultDomain
    }

    public init() {
        self.init(mailbox: .default(), dispatcher: .default, faultDomain: .default)
    }
    
    public func withFaultDomain(_ domain: FaultDomainProps) -> Props {
        return self.copy(faultDomain: domain)
    }
    public func withDispatcher(_ dispatcher: DispatcherProps) -> Props {
        return self.copy(dispatcher: dispatcher)
    }
    public func withMailbox(_ mailbox: MailboxProps) -> Props {
        return self.copy(mailbox: mailbox)
    }

    private func copy(
        mailbox: MailboxProps? = nil,
        dispatcher: DispatcherProps? = nil,
        faultDomain: FaultDomainProps? = nil
    ) -> Props {
        return .init(
            mailbox: mailbox ?? self.mailbox,
            dispatcher: dispatcher ?? self.dispatcher,
            faultDomain: faultDomain ?? self.faultDomain
        )
    }
}

// TODO: likely better as class hierarchy, by we'll see...

public enum DispatcherProps {
//  /// Picks default dispatched for user actors for your current runtime
//  #if os(OSX)
//  let `default`: DispatcherProps = DispatcherProps.dispatch(qosClass: .default)
//  #elseif os(Linux)
//  let `default`: DispatcherProps = DispatcherProps.dispatch(qosClass: .default)
//  #else
//  let `default`: DispatcherProps = DispatcherProps.dispatch(qosClass: .default)
//  #endif

    /// Lets runtime determine the default dispatcher
    case `default`

    /// Use the Dispatch library as underlying executor.
    case dispatch(qosClass: Dispatch.DispatchQoS.QoSClass) // TODO: we want diff actors to be able to run on diff priorities, thus this setting

    // TODO: not entirely sure about how to best pull it off, but pretty sure we want a dispatcher that can use NIO's EventLoop
    //       we'd need to pass EventLoop into the system, but I think this would be nice at the worst we'd "blow up if you want to use NIO event loops but it's not passed in"
    case NIO

    // TODO: definitely good, though likely not as first thing We can base it on Akka's recent "Affinity" one,
    // though in Akka we had a hard time really proving that it outperforms the FJP since here we have no FJP readily available, and the Affinity one is much simpler,
    // I'd rather implement such style, as it actually is build "for" actors, and not accidentally running them well...
    // case OurOwnFancyActorSpecificDispatcher

    /// Use with Caution!
    ///
    /// This dispatcher will keep a real dedicated Thread for this actor. This is very rarely something you want,
    // unless designing an actor that is intended to spin without others interrupting it on some resource and may block on it etc.
    case PinnedThread
}

public enum MailboxProps {
    case `default`(capacity: Int, onOverflow: MailboxOverflowStrategy)

    static func `default`(capacity: Int = Int.max) -> MailboxProps {
        return .default(capacity: capacity, onOverflow: .crash)
    }
    
    var capacity: Int {
        switch self {
        case let .default(cap, _): return cap
        }
    }
}

// TODO: Highly experimental and only for PoC of spawning in other process
// TODO: currently not used, decide if we need them at all – will we do the process ones or not?
public enum FaultDomainProps {
    case `default` // perhaps this is "inherit"?

    /// Isolate this actor and all of its children in its own process
    case isolate
}

// TODO: those only apply when bounded mailboxes
public enum MailboxOverflowStrategy {
    case crash
    case dropIncoming
    case dropMailbox
}
