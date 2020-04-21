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

import struct NIO.ByteBuffer
import protocol NIO.EventLoop

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Addressable (but not tell-able) ActorRef

/// Type erased form of `AddressableActorRef` in order to be used as existential type.
/// This form allows us to check for "is this the same actor?" yet not send messages to it.
public struct AddressableActorRef: Hashable {
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

    public init<M>(_ ref: ActorRef<M>) {
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
        on pool: SerializationPool,
        file: String = #file, line: UInt = #line
    ) {
        self.ref._deserializeDeliver(messageBytes, using: manifest, on: pool, file: file, line: line)
    }

    public func _unsafeGetRemotePersonality<M: ActorMessage>(_ type: M.Type = M.self) -> RemotePersonality<M> {
        self.ref._unsafeGetRemotePersonality(M.self)
    }
}

internal extension RemotePersonality {
    @usableFromInline
    func _tellUnsafe(_ message: Any, file: String = #file, line: UInt = #line) {
        guard let _message = message as? Message else {
            traceLog_Remote(self.system.cluster.node, "\(self.address)._tellUnsafe [\(message)] failed because of invalid type; self: \(self); Sent at \(file):\(line)")
            return // TODO: drop the message
        }

        self.sendUserMessage(_message, file: file, line: line)
    }
}

internal extension ActorRef {
    /// UNSAFE API, DO NOT TOUCH.
    /// This may only be used when certain that a given ref points to a local actor, and thus contains a cell.
    /// May be used by internals when things are to be attached to "myself's cell".
    @usableFromInline
    var _unsafeUnwrapCell: ActorCell<Message> {
        switch self.personality {
        case .cell(let cell): return cell
        default: fatalError("Illegal downcast attempt from \(String(reflecting: self)) to ActorRefWithCell. This is a Swift Distributed Actors bug, please report this on the issue tracker.")
        }
    }

    @usableFromInline
    var _unsafeUnwrapRemote: RemotePersonality<Message> {
        switch self.personality {
        case .remote(let remote): return remote
        default: fatalError("Illegal downcast attempt from \(String(reflecting: self)) to ActorRefWithCell. This is a Swift Distributed Actors bug, please report this on the issue tracker.")
        }
    }
}
