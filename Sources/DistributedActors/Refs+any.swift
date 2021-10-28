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

import _Distributed
import struct NIO.ByteBuffer
import protocol NIO.EventLoop

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Addressable (but not tell-able) _ActorRef

/// Represents an actor which we know existed at some point in time and this represents its type-erased reference.
///
/// An `AddressableActorRef` can be used as type-eraser for specific actor references (be it `Actor` or `_ActorRef` based),
/// as they may still be compared with the `AddressableActorRef` by comparing their respective addressable.
///
/// This enables an `AddressableActorRef` to be useful for watching, storing and comparing actor references of various types with another.
/// Note that unlike a plain `ActorAddress` an `AddressableActorRef` still DOES hold an actual reference to the pointed to actor,
/// even though it is not able to send messages to it (due to the lack of type-safety when doing so).
public struct AddressableActorRef: _DeathWatchable, Hashable {
    @usableFromInline
    enum RefType {
        case remote
        case local

        var isLocal: Bool {
            self == .local
        }

        var isRemote: Bool {
            self == .remote
        }
    }

    @usableFromInline
    let ref: _ReceivesSystemMessages

    @usableFromInline
    let messageTypeId: ObjectIdentifier
    @usableFromInline
    let refType: RefType

    public init<M>(_ ref: _ActorRef<M>) {
        self.ref = ref
        self.messageTypeId = ObjectIdentifier(M.self)
        switch ref.personality {
        case .remote:
            self.refType = .remote
        default:
            self.refType = .local
        }
    }

    public var address: ActorAddress {
        self.ref.address
    }

    public var asAnyActorIdentity: AnyActorIdentity {
        self.address.asAnyActorIdentity
    }

    public var asAddressable: AddressableActorRef {
        self
    }

    func asReceivesSystemMessages() -> _ReceivesSystemMessages {
        self.ref
    }

    func isRemote() -> Bool {
        switch self.refType {
        case .remote: return true
        case .local: return false
        }
    }

    public func _sendSystemMessage(_ message: _SystemMessage, file: String = #file, line: UInt = #line) {
        self.ref._sendSystemMessage(message, file: file, line: line)
    }
}

extension AddressableActorRef: CustomStringConvertible {
    public var description: String {
        "AddressableActorRef(\(self.ref.address))"
    }
}

extension AddressableActorRef {
    public func hash(into hasher: inout Hasher) {
        self.address.hash(into: &hasher)
    }

    public static func == (lhs: AddressableActorRef, rhs: AddressableActorRef) -> Bool {
        lhs.address == rhs.address
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Internal or unsafe methods

extension AddressableActorRef: _ReceivesSystemMessages {
    public func _tellOrDeadLetter(_ message: Any, file: String = #file, line: UInt = #line) {
        self.ref._tellOrDeadLetter(message, file: file, line: line)
    }

    public func _dropAsDeadLetter(_ message: Any, file: String = #file, line: UInt = #line) {
        self.ref._dropAsDeadLetter(message, file: file, line: line)
    }

    public func _deserializeDeliver(
        _ messageBytes: Serialization.Buffer, using manifest: Serialization.Manifest,
        on pool: _SerializationPool,
        file: String = #file, line: UInt = #line
    ) {
        self.ref._deserializeDeliver(messageBytes, using: manifest, on: pool, file: file, line: line)
    }

    public func _unsafeGetRemotePersonality<M: ActorMessage>(_ type: M.Type = M.self) -> _RemoteClusterActorPersonality<M> {
        self.ref._unsafeGetRemotePersonality(M.self)
    }
}

internal extension _RemoteClusterActorPersonality {
    @usableFromInline
    func _tellUnsafe(_ message: Any, file: String = #file, line: UInt = #line) {
        guard let _message = message as? Message else {
            traceLog_Remote(self.system.cluster.uniqueNode, "\(self.address)._tellUnsafe [\(message)] failed because of invalid type; self: \(self); Sent at \(file):\(line)")
            return // TODO: drop the message
        }

        self.sendUserMessage(_message, file: file, line: line)
    }
}

internal extension _ActorRef {
    /// UNSAFE API, DO NOT TOUCH.
    /// This may only be used when certain that a given ref points to a local actor, and thus contains a cell.
    /// May be used by internals when things are to be attached to "myself's cell".
    @usableFromInline
    var _unsafeUnwrapCell: _ActorCell<Message> {
        switch self.personality {
        case .cell(let cell): return cell
        default: fatalError("Illegal downcast attempt from \(String(reflecting: self)) to _ActorRefWithCell. This is a Swift Distributed Actors bug, please report this on the issue tracker.")
        }
    }

    @usableFromInline
    var _unwrapActorMetrics: ActiveActorMetrics {
        switch self.personality {
        case .cell(let cell):
            return cell.actor?.metrics ?? ActiveActorMetrics.noop
        default:
            return ActiveActorMetrics.noop
        }
    }

    @usableFromInline
    var _unsafeUnwrapRemote: _RemoteClusterActorPersonality<Message> {
        switch self.personality {
        case .remote(let remote): return remote
        default: fatalError("Illegal downcast attempt from \(String(reflecting: self)) to _ActorRefWithCell. This is a Swift Distributed Actors bug, please report this on the issue tracker.")
        }
    }
}
