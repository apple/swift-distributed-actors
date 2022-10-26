//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed
import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Dead letter

/// A "dead letter" is a message ("letter") that is impossible to deliver to its designated recipient.
///
/// Often the reason for this is that the message was sent to given actor while it was still alive,
/// yet once it arrived the destination node the actor had already terminated, leaving the message to be dropped.
///
/// Since such races can happen when a distributed remote actor is e.g. passivated before it receives a remote call,
/// and can be tricky to diagnose otherwise, such messages are  such messages are not silently dropped,
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
///
/// - SeeAlso: [Dead letter office](https://en.wikipedia.org/wiki/Dead_letter_office) on Wikipedia.
public struct DeadLetter: _NotActuallyCodableMessage {
    let message: Any
    let recipient: ActorID?

    // TODO: sender and other metadata

    let sentAtFile: String?
    let sentAtLine: UInt?

    public init(_ message: Any, recipient: ActorID?, sentAtFile: String? = #filePath, sentAtLine: UInt? = #line) {
        self.message = message
        self.recipient = recipient
        self.sentAtFile = sentAtFile
        self.sentAtLine = sentAtLine
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ClusterSystem.deadLetters

extension ClusterSystem {
    /// Dead letters reference dedicated to a specific address.
    public func personalDeadLetters<Message: Codable>(type: Message.Type = Message.self, recipient: ActorID) -> _ActorRef<Message> {
        // TODO: rather could we send messages to self._deadLetters with enough info so it handles properly?

        guard recipient.node == self.settings.bindNode else {
            /// While it should not realistically happen that a dead letter is obtained for a remote reference,
            /// we do allow for construction of such ref. It can be used to signify a ref is known to resolve to
            /// a known to be down cluster node.
            ///
            /// We don't apply the special /dead path, as to not complicate diagnosing who actually terminated or if we were accidentally sent
            /// a remote actor ref that was dead(!)
            return _ActorRef(.deadLetters(.init(self.log, id: recipient, system: self))).adapt(from: Message.self)
        }

        let localRecipient: ActorID
        if recipient.path.segments.first == ActorPath._dead.segments.first {
            // drop the node from the address; and we know the pointed at ref is already dead; do not prefix it again
            localRecipient = ActorID(local: self.settings.bindNode, path: recipient.path, incarnation: recipient.incarnation)
        } else {
            // drop the node from the address; and prepend it as known-to-be-dead
            localRecipient = ActorID(local: self.settings.bindNode, path: ActorPath._dead.appending(segments: recipient.segments), incarnation: recipient.incarnation)
        }
        return _ActorRef(.deadLetters(.init(self.log, id: localRecipient, system: self))).adapt(from: Message.self)
    }

    /// Anonymous `/dead/letters` reference, which may be used for messages which have no logical recipient.
    public var deadLetters: _ActorRef<DeadLetter> {
        self._deadLetters
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Dead letter office

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
///
/// ## Dead References
///
/// An `ActorID` pointing to a local actor, yet obtained via clustered communication MAY be resolved as so called "dead reference".
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
/// Dead references are NOT used to signify that an actor that an `_ActorRef` points to has terminated and any _further_ messages sent to it will
/// result in dead letters. The difference here is that in this case the actor _existed_ and the `_ActorRef` _was valid_ at some point in time.
/// Dead references on the other hand have never, and will never be valid, meaning it is useful to distinguish them for debugging and logging purposes,
/// but not for anything more -- users shall assume that their communication is correct and only debug why a dead reference appeared if it indeed does happen.
///
/// - SeeAlso: [Dead letter office](https://en.wikipedia.org/wiki/Dead_letter_office) on Wikipedia.
public final class DeadLetterOffice {
    let _id: ActorID
    let log: Logger
    weak var system: ClusterSystem?
    let isShuttingDown: () -> Bool

    init(_ log: Logger, id: ActorID, system: ClusterSystem?) {
        self.log = log
        self._id = id
        self.system = system
        self.isShuttingDown = { [weak system] in
            system?.isShuttingDown ?? false
        }
    }

    @usableFromInline
    var id: ActorID {
        self._id
    }

    @usableFromInline
    var path: ActorPath {
        self._id.path
    }

    @usableFromInline
    var ref: _ActorRef<DeadLetter> {
        .init(.deadLetters(self))
    }

    func deliver(_ message: Any, file: String = #filePath, line: UInt = #line) {
        if let alreadyDeadLetter = message as? DeadLetter {
            self.onDeadLetter(alreadyDeadLetter, file: alreadyDeadLetter.sentAtFile ?? file, line: alreadyDeadLetter.sentAtLine ?? line)
        } else {
            self.onDeadLetter(DeadLetter(message, recipient: self.id, sentAtFile: file, sentAtLine: line), file: file, line: line)
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
            let deadID: ActorID = .init(remote: recipient.node, path: recipient.path, incarnation: recipient.incarnation)

            // should not really happen, as the only way to get a remote ref is to resolve it, and a remote resolve always yields a remote ref
            // thus, it is impossible to resolve a remote address into a dead ref; however keeping this path in case we manually make such mistake
            // somewhere in internals, and can spot it then easily
            if recipient.path.starts(with: ._system), self.isShuttingDown() {
                return // do not log dead letters to /system actors while shutting down
            }

            metadata["actor/path"] = Logger.MetadataValue.stringConvertible(deadID.path)
            recipientString = "to [\(recipient.detailedDescription)]"
        } else {
            recipientString = ""
        }

        if let systemMessage = deadLetter.message as? _SystemMessage, self.specialHandled(systemMessage, recipient: deadLetter.recipient) {
            return // system message was special handled; no need to log it anymore
        }

        // in all other cases, we want to log the dead letter:
        self.log.notice(
            "Dead letter was not delivered \(recipientString)",
            metadata: { () -> Logger.Metadata in
                // TODO: more metadata (from Envelope) (e.g. sender)
                if let recipient = deadLetter.recipient?.detailedDescription {
                    metadata["deadLetter/recipient"] = "\(recipient)"
                }
                if let invocation = deadLetter.message as? InvocationMessage {
                    metadata["deadLetter/invocation/target"] = "\(invocation.target.description)"
                }
                metadata["deadLetter/location"] = "\(file):\(line)"
                metadata["deadLetter/message"] = "\(deadLetter.message)"
                metadata["deadLetter/message/type"] = "\(String(reflecting: type(of: deadLetter.message)))"
                return metadata
            }()
        )
    }

    private func specialHandled(_ message: _SystemMessage, recipient: ActorID?) -> Bool {
        // TODO: special handle $ask- replies; those mean we got a reply to an ask which timed out already

        switch message {
        case .tombstone:
            // FIXME: this should never happen; tombstone must always be taken in by the actor as last message
            traceLog_Mailbox(self.id.path, "Tombstone arrived in dead letters. TODO: make sure these dont happen")
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
            return self.isShuttingDown()
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Silent Dead Letter marker

protocol SilentDeadLetter {}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Paths

extension ActorPath {
    static let _dead: ActorPath = try! ActorPath(root: "dead")
    static let _deadLetters: ActorPath = try! ActorPath._dead.appending("letters")
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Errors

/// Dead letter errors may be transported back to remote callers, to indicate the recipient they tried to contact is no longer alive.
public struct DeadLetterError: DistributedActorSystemError, CustomStringConvertible, Hashable, Codable {
    public let recipient: ClusterSystem.ActorID

    internal let file: String?
    internal let line: UInt

    init(recipient: ClusterSystem.ActorID, file: String = #fileID, line: UInt = #line) {
        self.recipient = recipient
        self.file = file
        self.line = line
    }

    public func hash(into hasher: inout Hasher) {
        self.recipient.hash(into: &hasher)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.recipient == rhs.recipient
    }

    enum CodingKeys: CodingKey {
        case recipient
        case file
        case line
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.recipient = try container.decode(ClusterSystem.ActorID.self, forKey: .recipient)
        self.file = nil
        self.line = 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.recipient, forKey: .recipient)
        // We do NOT serialize source location, on purpose.
    }

    public var description: String {
        if let file {
            return "\(Self.self)(recipient: \(self.recipient), location: \(file):\(self.line))"
        }

        return "\(Self.self)(\(self.recipient))"
    }
}
