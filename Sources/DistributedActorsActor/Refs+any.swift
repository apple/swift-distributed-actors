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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Addressable (but not tell-able) ActorRef

/// Type erased form of `AddressableActorRef` in order to be used as existential type.
/// This form allows us to check for "is this the same actor?" yet not send messages to it.
// TODO: rename to AddressableRef -- actor ref implies we can send things to it, but we can not to this one
public struct AddressableActorRef: Hashable {
    @usableFromInline
    enum RefType {
        case remote
        case local
    }

    @usableFromInline
    let ref: ReceivesSystemMessages

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

    @inlinable
    var path: UniqueActorPath {
        return self.ref.path
    }

    func asReceivesSystemMessages() -> ReceivesSystemMessages {
        return self.ref
    }

    func isRemote() -> Bool {
        switch self.refType {
        case .remote: return true
        case .local: return false
        }
    }

    @usableFromInline
    func sendSystemMessage(_ message: SystemMessage) {
        self.ref.sendSystemMessage(message)
    }
}

extension AddressableActorRef: CustomStringConvertible {
    public var description: String {
        return "AddressableActorRef(\(ref.path))"
    }
}

extension AddressableActorRef {
    public func hash(into hasher: inout Hasher) {
        self.path.hash(into: &hasher)
    }

    public static func ==(lhs: AddressableActorRef, rhs: AddressableActorRef) -> Bool {
        return lhs.path == rhs.path
    }

}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Internal unsafe methods

extension AddressableActorRef: ReceivesSystemMessages {
    @usableFromInline
    internal func _unsafeTellOrDrop(_ message: Any) {
        return self.ref._unsafeTellOrDrop(message)
    }

    @usableFromInline
    internal func _unsafeGetRemotePersonality() -> RemotePersonality<Any> {
        return self.ref._unsafeGetRemotePersonality()
    }
}

internal extension RemotePersonality {
    @usableFromInline
    func _tellUnsafe(_ message: Any) {
        guard let _message = message as? Message else {
            traceLog_Remote("\(self.path)._tellUnsafe [\(message)] failed because of invalid type; self: \(self);")
            return // TODO: drop the message
        }

        self.sendUserMessage(_message)
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

