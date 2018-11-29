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

import NIOConcurrencyHelpers

internal protocol ActorRefProvider {

    func spawn<Message>(
        system: ActorSystem,
        behavior: Behavior<Message>, path: ActorPath,
        dispatcher: MessageDispatcher, props: Props
    ) -> ActorRef<Message>
}

// FIXME sadly this is the wrong way to model "oh yeah, that one as process"

internal struct LocalActorRefProvider: ActorRefProvider {
    func spawn<Message>(
        system: ActorSystem,
        behavior: Behavior<Message>, path: ActorPath,
        dispatcher: MessageDispatcher, props: Props
    ) -> ActorRef<Message> {

        // TODO attach to parent here

        // the "real" actor, the cell that holds the actual "actor"
        let cell: ActorCell<Message> = ActorCell(
            behavior: behavior,
            system: system,
            dispatcher: dispatcher
        ) // TODO pass the Props

        // the mailbox of the actor
        let mailbox = Mailbox(cell: cell, capacity: props.mailbox.capacity)
        // mailbox.set(cell) // TODO: remind myself why it had to be a setter back in Akka

        let refWithCell = ActorRefWithCell(
            path: path,
            cell: cell,
            mailbox: mailbox
        )

        cell.set(ref: refWithCell)
        refWithCell.sendSystemMessage(.start)

        return refWithCell
    }
}

internal struct ProcessFaultDomainActorRefProvider: ActorRefProvider {
    func spawn<Message>(
        system: ActorSystem,
        behavior: Behavior<Message>, path: ActorPath,
        dispatcher: MessageDispatcher, props: Props
    ) -> ActorRef<Message> {

        // TODO attach to parent here

        // the "real" actor, the cell that holds the actual "actor"
        let cell: ActorCell<Message> = ActorCell(
            behavior: behavior,
            system: system,
            dispatcher: dispatcher
        ) // TODO pass the Props

        // the mailbox of the actor
        let mailbox = Mailbox(cell: cell, capacity: props.mailbox.capacity)
        // mailbox.set(cell) // TODO: remind myself why it had to be a setter back in Akka

        let refWithCell = ActorRefWithCell(
            path: path,
            cell: cell,
            mailbox: mailbox
        )

        cell.set(ref: refWithCell)
        refWithCell.sendSystemMessage(.start)

        return refWithCell
    }
}
