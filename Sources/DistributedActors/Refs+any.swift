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

        var isLocal: Bool {
            return self == .local
        }

        var isRemote: Bool {
            return self == .remote
        }
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
    var address: ActorAddress {
        return self.ref.address
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
    func sendSystemMessage(_ message: SystemMessage, file: String = #file, line: UInt = #line) {
        self.ref.sendSystemMessage(message, file: file, line: line)
    }
}

extension AddressableActorRef: CustomStringConvertible {
    public var description: String {
        return "AddressableActorRef(\(self.ref.address))"
    }
}

extension AddressableActorRef {
    // Prints short name like `ActorRef<Thing>` (so not Module.Thing),
    // useful for simple sanity checking of ref type in printouts of the actor tree,
    // but should not be used to deduct the real type of the accepted messages, 
    // for that purpose use the `messageTypeId` instead.
    public var _typeString: String {
        "\(type(of: self.ref))"
    }
}

extension AddressableActorRef {
    public func hash(into hasher: inout Hasher) {
        self.address.hash(into: &hasher)
    }

    public static func == (lhs: AddressableActorRef, rhs: AddressableActorRef) -> Bool {
        return lhs.address == rhs.address
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Internal unsafe methods

extension AddressableActorRef: ReceivesSystemMessages {
    @usableFromInline
    internal func _tellOrDeadLetter(_ message: Any, file: String = #file, line: UInt = #line) {
        return self.ref._tellOrDeadLetter(message, file: file, line: line)
    }

    @usableFromInline
    internal func _unsafeGetRemotePersonality() -> RemotePersonality<Any> {
        return self.ref._unsafeGetRemotePersonality()
    }
}

internal extension RemotePersonality {
    @usableFromInline
    func _tellUnsafe(_ message: Any, file: String = #file, line: UInt = #line) {
        guard let _message = message as? Message else {
            traceLog_Remote("\(self.address)._tellUnsafe [\(message)] failed because of invalid type; self: \(self); Sent at \(file):\(line)")
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
