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
    let recipient: UniqueActorPath?

    // TODO: sender and other metadata

    // TODO could be under a flag if we do carry the file/line or not?
    init(_ message: Any, recipient: UniqueActorPath?) {
        self.message = message
        self.recipient = recipient
    }
}

extension ActorRef where ActorRef.Message == DeadLetter {
    /// Redirects message, preserving its original `recipient` (this ref), to dead letters.
    func sendDeadLetter(_ message: Any) {
        self.tell(DeadLetter(message, recipient: self.path))
    }
}

/// Special actor reference, which logs any "dead letters".
/// Dead letters are messages or signals which were unable to be delivered to recipient, e.g. because the recipient
/// actor had terminated before the message could reach it, or the recipient never existed in the first place (although
/// this could only happen in ad-hoc actor path resolve situations, which should not happen in user-land).
///
/// Note: Does _not_ point to a "real" actor, however for all intents and purposes can be treated as-if it did.
///
/// Obtaining an instance is best done by referring to the `system.deadLetters` instance.
///
/// # Watch semantics
/// Watching the dead letters reference is always going to immediately reply with a `Terminated` signal.
///
/// This is not only to uphold the semantics of deadLetters itself, but also for general watch correctness:
/// watching an actor which is terminated, may result in the `watch` system message be delivered to dead letters,
/// in which case this property of dead letters will notify the watching actor that the "watchee" had already terminated.
/// In these situations Terminated would be marked as `existenceConfirmed: false`.
@usableFromInline
internal class DeadLetters {
    let _path: UniqueActorPath
    let log: Logger

    init(_ log: Logger, path: UniqueActorPath) {
        self.log = log
        self._path = path
    }

    @usableFromInline
    var path: UniqueActorPath {
        return _path
    }

    var ref: ActorRef<DeadLetter> {
        return .init(.deadLetters(self))
    }

    func drop(_ message: Any, file: String = #file, line: UInt = #line) {
        if let alreadyDeadLetter = message as? DeadLetter {
            self.sendDeadLetter(alreadyDeadLetter)
        } else {
            self.sendDeadLetter(DeadLetter(message, recipient: self.path))
        }
    }
    
    func sendDeadLetter(_ deadLetter: DeadLetter) {
        let recipient = "to \(deadLetter.recipient, orElse: "no-recipient")"

        if let systemMessage = deadLetter.message as? SystemMessage {
            let handled = specialHandle(systemMessage)
            if !handled {
                log.warning("Dead letter encountered. Sent \(recipient); System message [\(deadLetter.message)]:\(String(reflecting: type(of: deadLetter.message))) was not delivered.")
            }
        } else {
            // TODO more metadata (from Envelope)
            log.warning("Dead letter encountered. Sent \(recipient); Message [\(deadLetter.message)]:\(String(reflecting: type(of: deadLetter.message))) was not delivered. ")
        }
    }

    private func specialHandle(_ message: SystemMessage) -> Bool {
        switch message {
        case .tombstone:
            // FIXME: this should never happen; tombstone must always be taken in by the actor as last message
            traceLog_Mailbox(self._path, "Tombstone arrived in dead letters. TODO: make sure these dont happen")
            return true // TODO would be better to avoid them ending up here at all, this means that likely a double dead letter was sent
        case .watch(let watchee, let watcher):
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
