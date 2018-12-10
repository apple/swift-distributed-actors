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

    /// Path of the root guardian actor for this pare of the actor tree.
    var rootPath: UniqueActorPath { get }

    /// Spawn an actor with the passed in [Behavior] and return its [ActorRef].
    ///
    /// The returned actor ref is immediately valid and may have messages sent to.
    func spawn<Message>(
        system: ActorSystem,
        behavior: Behavior<Message>, path: UniqueActorPath,
        dispatcher: MessageDispatcher, props: Props
    ) -> ActorRef<Message>
}

// FIXME sadly this is the wrong way to model "oh yeah, that one as process"

internal struct LocalActorRefProvider: ActorRefProvider {

    let root: ReceivesSystemMessages

    var rootPath: UniqueActorPath {
        return root.path
    }

    init(root: ReceivesSystemMessages) {
        self.root = root
    }

    func spawn<Message>(
        system: ActorSystem,
        behavior: Behavior<Message>, path: UniqueActorPath,
        dispatcher: MessageDispatcher, props: Props
    ) -> ActorRef<Message> {

        // the cell that holds the actual "actor", though one could say the cell *is* the actor...
        let cell: ActorCell<Message> = ActorCell(
            system: system,
            parent: root,
            behavior: behavior,
            path: path,
            props: props,
            dispatcher: dispatcher
        )

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
