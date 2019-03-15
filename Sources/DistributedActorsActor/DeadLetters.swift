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

import Logging

public struct DeadLetter {
    let message: Any
    // TODO: from, to, other metadata

    init(_ message: Any) {
        self.message = message
    }
}

// FIXME this is just a quick workaround, will need to be a bit smarter than that
internal final class DeadLettersActorRef: ActorRef<DeadLetter> {
    let _path: UniqueActorPath
    let log: Logger

    init(_ log: Logger, path: UniqueActorPath) {
        self.log = log
        self._path = path
        super.init()
    }

    override var path: UniqueActorPath {
        return _path
    }

    var addressableRef: AnyAddressableActorRef {
        return DeadLettersAnyAddressableActorRef(path: self._path)
    }

    override func tell(_ deadLetter: DeadLetter) {
        if let systemMessage = deadLetter.message as? SystemMessage {
            let handled = specialHandle(systemMessage)
            if !handled {
                // TODO maybe dont log them...?
                log.warning("[deadLetters] Dead letter encountered. System message [\(deadLetter.message)]:\(type(of: deadLetter.message)) was not delivered.")
            }
        } else {
            // TODO more metadata (from Envelope)
            log.warning("[deadLetters] Dead letter encountered. Message [\(deadLetter.message)]:\(type(of: deadLetter.message)) was not delivered. ")
        }
    }

    private func specialHandle(_ message: SystemMessage) -> Bool {
        switch message {
        case .tombstone:
            // FIXME: this should never happen; tombstone must always be taken in by the actor as last message
            traceLog_Mailbox(self._path, "Tombstone arrived in dead letters. TODO: make sure these dont happen")
            return true // TODO would be better to avoid them ending up here at all, this means that likely a double dead letter was sent
        case let .watch(watchee, watcher):
            // if a watch message arrived here it either:
            //   - was sent to an actor which has terminated and arrived after the .tombstone, thus was drained to deadLetters
            //   - was indeed sent to deadLetters directly, which immediately shall notify terminated; deadLetters is "undead"
            watcher.sendSystemMessage(.terminated(ref: watchee, existenceConfirmed: false))
            return true
        default:
            // ignore other messages, no special handling needed
            return false
        }
    }

}

// TODO this is a hack, I think... would be nicer for deadLetters to be real
internal struct DeadLettersAnyAddressableActorRef: AnyAddressableActorRef {
    let path: UniqueActorPath

    init(path: UniqueActorPath) {
        self.path = path
    }

    func asHashable() -> AnyHashable {
        fatalError("asHashable() has not been implemented")
    }
}
