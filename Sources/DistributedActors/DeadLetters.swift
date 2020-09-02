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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Dead letter

/// A "dead letter" is a message ("letter") that is impossible to deliver to its designated recipient.
///
/// Often the reason for this is that the message was sent to given actor while it was still alive,
/// yet once it arrived the destination node (or mailbox) the actor had already terminated, leaving the message to be dropped.
/// Since such races can happen and point to problems in an actor based algorithm, such messages are not silently dropped,
/// but rather logged, with as much information as available (e.g. about the sender or source location of the initiating tell),
/// such that when operating the system, bugs regarding undelivered messages can be spotted and fixed.
///
/// ## Not all dead letters are problems
/// No, some dead letters may happen in a perfectly healthy system and if one knows that a message could arrive
/// "too late" or be dropped for some other reason, one may mark it using the TODO: "dont log me as dead letter" protocol.
///
/// ### Trivia
/// The term dead letters, or rather "dead letter office" originates from the postal system, where undeliverable
/// mail would be called such, and shipped to one specific place to deal with these letters.
/// See also [Dead letter office](https://en.wikipedia.org/wiki/Dead_letter_office) on Wikipedia.
public struct DeadLetter: NonTransportableActorMessage { // TODO: make it also remote
    let message: Any
    let recipient: ActorAddress?

    // TODO: sender and other metadata

    #if DEBUG
    let sentAtFile: String?
    let sentAtLine: UInt?

    public init(_ message: Any, recipient: ActorAddress?, sentAtFile: String? = #file, sentAtLine: UInt? = #line) {
        self.message = message
        self.recipient = recipient
        self.sentAtFile = sentAtFile
        self.sentAtLine = sentAtLine
    }

    #else
    public init(_ message: Any, recipient: ActorAddress?, sentAtFile: String? = nil, sentAtLine: UInt? = nil) {
        self.message = message
        self.recipient = recipient
        self.sentAtFile = sentAtFile
        self.sentAtLine = sentAtLine
    }
    #endif
}

/// // Marker protocol used as `Message` type when a resolve fails to locate an actor given an address.
/// // This type is used by serialization to notice that a message shall be delivered as dead letter
/// // (rather than attempting to cast the deserialized payload to the "found type" (which would be `Never` or `MessageForDeadRecipient`).
// @usableFromInline
// internal protocol MessageForDeadRecipient: NonTransportableActorMessage {}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorSystem.deadLetters

extension ActorSystem {
    /// Dead letters reference dedicated to a specific address.
    public func personalDeadLetters<Message: ActorMessage>(type: Message.Type = Message.self, recipient: ActorAddress) -> ActorRef<Message> {
        // TODO: rather could we send messages to self._deadLetters with enough info so it handles properly?

        guard recipient.node == self.settings.cluster.uniqueBindNode else {
            /// While it should not realistically happen that a dead letter is obtained for a remote reference,
            /// we do allow for construction of such ref. It can be used to signify a ref is known to resolve to
            /// a known to be down cluster node.
            ///
            /// We don't apply the special /dead path, as to not complicate diagnosing who actually terminated or if we were accidentally sent
            /// a remote actor ref that was dead(!)
            return ActorRef(.deadLetters(.init(self.log, address: recipient, system: self))).adapt(from: Message.self)
        }

        let localRecipient: ActorAddress
        if recipient.path.segments.first == ActorPath._dead.segments.first {
            // drop the node from the address; and we know the pointed at ref is already dead; do not prefix it again
            localRecipient = ActorAddress(local: self.settings.cluster.uniqueBindNode, path: recipient.path, incarnation: recipient.incarnation)
        } else {
            // drop the node from the address; and prepend it as known-to-be-dead
            localRecipient = ActorAddress(local: self.settings.cluster.uniqueBindNode, path: ActorPath._dead.appending(segments: recipient.segments), incarnation: recipient.incarnation)
        }
        return ActorRef(.deadLetters(.init(self.log, address: localRecipient, system: self))).adapt(from: Message.self)
    }

    /// Anonymous `/dead/letters` reference, which may be used for messages which have no logical recipient.
    public var deadLetters: ActorRef<DeadLetter> {
        self._deadLetters
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Dead letter office

/// :nodoc: INTERNAL API: May change without any prior notice.
///
/// Special actor ref personality, which can handle `DeadLetter`s.
///
/// Dead letters are messages or signals which were unable to be delivered to recipient, e.g. because the recipient
/// actor had terminated before the message could reach it, or the recipient never existed in the first place (although
/// this could only happen in ad-hoc actor path resolve situations, which should not happen in user-land).
///
/// Note: Does _not_ point to a "real" actor, however for all intents and purposes can be treated as-if it did.
///
/// Obtaining an instance of dead letters is best done by using the `system.deadLetters` or `personalDeadLetters` methods;
/// however, it should be stressed, that directly interacting with dead letters is not something that should be needed at
/// any point in time in normal user applications, as messages become dead letters automatically when messages are
/// delivered at terminated or non-existing recipients.
///
/// # Watch semantics
/// Watching the dead letters reference is always going to immediately reply with a `Terminated` signal.
///
/// This is not only to uphold the semantics of deadLetters itself, but also for general watch correctness:
/// watching an actor which is terminated, may result in the `watch` system message be delivered to dead letters,
/// in which case this property of dead letters will notify the watching actor that the "watchee" had already terminated.
/// In these situations Terminated would be marked as `existenceConfirmed: false`.

/// ## Dead References
///
/// An `ActorAddress` pointing to a local actor, yet obtained via clustered communication MAY be resolved as so called "dead reference".
///
/// A dead actor reference is defined by its inherent inability to *ever* have a chance to deliver messages to its target actor.
/// While rare, such references may occur when a reference to a _local_ actor is obtained from remote communication, and thus
/// the actor address resolution will perform a lookup, to relate the incoming address with a live actor; during this process
/// if any of the following situations happens, the reference will be considered "dead" (like a "dead link" on an HTML page):
///
/// - the address points to a local actor which does not exist, and thus no messages *ever* sent to the such-obtained reference will have a chance of being delivered,
/// - address resolution locates a live actor matching the path, but with a different `ActorIncarnation`;
///   meaning that the "previous incarnation" of the actor, which the address refers to, does no longer exist, and thus no attempts to send messages
///   to the such obtained ref will ever succeed
/// - address resolution locates a live actor matching the address, however the expected type does not match the actual type of the running actor (!);
///   to protect the system from performing unsafe casts, the a dead ref will be yielded instead of the wrongly-typed ref of the alive actor.
///   - this can happen when somehow message types are mixed up and signify an actor has another type than it has in the real running system
///
/// Dead references are NOT used to signify that an actor that an `ActorRef` points to has terminated and any _further_ messages sent to it will
/// result in dead letters. The difference here is that in this case the actor _existed_ and the `ActorRef` _was valid_ at some point in time.
/// Dead references on the other hand have never, and will never be valid, meaning it is useful to distinguish them for debugging and logging purposes,
/// but not for anything more -- users shall assume that their communication is correct and only debug why a dead reference appeared if it indeed does happen.
public final class DeadLetterOffice {
    let _address: ActorAddress
    let log: Logger
    weak var system: ActorSystem?

    init(_ log: Logger, address: ActorAddress, system: ActorSystem?) {
        self.log = log
        self._address = address
        self.system = system
    }

    @usableFromInline
    var address: ActorAddress {
        self._address
    }

    @usableFromInline
    var path: ActorPath {
        self._address.path
    }

    @usableFromInline
    var ref: ActorRef<DeadLetter> {
        .init(.deadLetters(self))
    }

    func deliver(_ message: Any, file: String = #file, line: UInt = #line) {
        if let alreadyDeadLetter = message as? DeadLetter {
            self.onDeadLetter(alreadyDeadLetter, file: alreadyDeadLetter.sentAtFile ?? file, line: alreadyDeadLetter.sentAtLine ?? line)
        } else {
            self.onDeadLetter(DeadLetter(message, recipient: self.address, sentAtFile: file, sentAtLine: line), file: file, line: line)
        }
    }

    private func onDeadLetter(_ deadLetter: DeadLetter, file: String, line: UInt) {
        // Implementation notes:
        // We do want to change information in the logger; but we do NOT want to create a new logger
        // as that may then change ordering; if multiple onDeadLetter executions are ongoing, we want
        // all of them to be piped to the exact same logging handler, do not create a new Logging.Logger() here (!)

        var metadata: Logger.Metadata = [:]

        let recipientString: String
        if let recipient = deadLetter.recipient {
            let deadAddress: ActorAddress = .init(remote: recipient.node, path: recipient.path, incarnation: recipient.incarnation)

            // should not really happen, as the only way to get a remote ref is to resolve it, and a remote resolve always yields a remote ref
            // thus, it is impossible to resolve a remote address into a dead ref; however keeping this path in case we manually make such mistake
            // somewhere in internals, and can spot it then easily
            if recipient.path.starts(with: ._system), self.system?.isShuttingDown ?? false {
                return // do not log dead letters to /system actors while shutting down
            }

            metadata["actor/path"] = Logger.MetadataValue.stringConvertible(deadAddress.path)
            recipientString = "to [\(String(reflecting: recipient.detailedDescription))]"
        } else {
            recipientString = ""
        }

        if let systemMessage = deadLetter.message as? _SystemMessage, self.specialHandled(systemMessage, recipient: deadLetter.recipient) {
            return // system message was special handled; no need to log it anymore
        }

        // in all other cases, we want to log the dead letter:
        self.log.info(
            "Dead letter was not delivered \(recipientString)",
            metadata: { () -> Logger.Metadata in
                // TODO: more metadata (from Envelope) (e.g. sender)
                if !recipientString.isEmpty {
                    metadata["deadLetter/recipient"] = "\(recipientString)"
                }
                metadata["deadLetter/location"] = "\(file):\(line)"
                metadata["deadLetter/message"] = "\(deadLetter.message)"
                metadata["deadLetter/message/type"] = "\(String(reflecting: type(of: deadLetter.message)))"
                return metadata
            }()
        )
    }

    private func specialHandled(_ message: _SystemMessage, recipient: ActorAddress?) -> Bool {
        // TODO: special handle $ask- replies; those mean we got a reply to an ask which timed out already

        switch message {
        case .tombstone:
            // FIXME: this should never happen; tombstone must always be taken in by the actor as last message
            traceLog_Mailbox(self.address.path, "Tombstone arrived in dead letters. TODO: make sure these dont happen")
            return true // TODO: would be better to avoid them ending up here at all, this means that likely a double dead letter was sent
        case .watch(let watchee, let watcher):
            // if a watch message arrived here it either:
            //   - was sent to an actor which has terminated and arrived after the .tombstone, thus was drained to deadLetters
            //   - was indeed sent to deadLetters directly, which immediately shall notify terminated; deadLetters is "undead"
            watcher._sendSystemMessage(.terminated(ref: watchee, existenceConfirmed: false))
            return true
        case .stop:
            // we special handle some not delivered stop messages, based on the fact that those
            // are inherently racy in the during actor system shutdown:
            let ignored = recipient?.path == ._clusterShell
            return ignored
        default:
            if let system = self.system {
                // ignore other messages if we are shutting down, there will be many dead letters now
                return system.isShuttingDown
            } else {
                return false
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Silent Dead Letter marker

protocol SilentDeadLetter {}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Paths

extension ActorPath {
    internal static let _dead: ActorPath = try! ActorPath(root: "dead")
    internal static let _deadLetters: ActorPath = try! ActorPath._dead.appending("letters")
}
