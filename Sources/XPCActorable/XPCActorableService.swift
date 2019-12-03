//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import DistributedActors
import CXPCActorable
import XPC
import NIO
import Logging
import Files

// ==== ------------------------------------------------------------------------------------------------------------
fileprivate let file = try! Folder(path: "/tmp").file(named: "xpc.txt")

fileprivate let _storageLock: Mutex = Mutex()
fileprivate var _storage: XPCStorage? = nil

struct XPCStorage {
    let myself: AddressableActorRef
    let system: ActorSystem

    let sendMessage: (Any) -> Void
    // let sendSystemMessage: (SystemMessage) -> Void
}


/// Allows handling XPC messages using an `Actorable`.
///
/// Once a handler actor is defined the `park()` function MUST be invoked to kick
public final class XPCActorableService<A: Actorable> {

    let file = try! Folder(path: "/tmp").file(named: "xpc.txt")
    let myself: ActorRef<A.Message>
    let system: ActorSystem

//    var onConnectionContext: XPCHandlerClosureContext!
//    let onConnectionCallback: SactXPCOnConnectionCallback
//    let onMessageCallback: SactXPCOnMessageCallback

    public init(_ system: ActorSystem, _ makeActorableHandler: @escaping (A.Myself.Context) -> A) throws {
        let actor = try system.spawn("\(system.name)", { makeActorableHandler($0) })
        self.myself = actor.ref
        self.system = system

        // TODO: use xpc_connection_set_context for state management rather than the global; we'll need this for many services in same process

//        // prepare for xpclib interop
//        self.onConnectionCallback = { ctxPtr, connection in
//            let f = try! Folder(path: "/tmp").file(named: "xpc.txt")
//            try! f.append("!!!! INVOKE !!!!")
//
//            guard let context = ctxPtr?.assumingMemoryBound(to: XPCHandlerClosureContext.self).pointee else {
//                return
//            }
//
//            try! f.append("INSIDE INVOKE\n")
//        }
//
//        self.onMessageCallback = { context, connection, object in
//
//        }
//
//        self.onConnectionContext = XPCHandlerClosureContext(
//            tell: { object in
//
//            }
//        )
    }

    /// Park the current thread and start handling messages using the provided actorable.
    ///
    /// Only one XPCService per process is allowed.
    ///
    /// Even if multiple instances of `ActorableXPCService` are created, only the first one to `park()` the main thread
    /// is going to begin accepting requests, other `park()` calls will fail and crash the process.
    ///
    /// **WARNING:** Parks the current thread and allows `xpc_main` to take it over.
    public func park(file: String = #file, line: UInt = #line) {
        _storageLock.lock()
        if let storage = _storage {
            preconditionFailure(
                """
                Unexpected park call at: \(file):\(line)! \
                Other ActorableXPCService has already been parked, it is: \(storage.myself). \
                Parking multiple services is NOT supported. Please make sure to only park one service.
                """
            )
        }

        // TODO: SHARE WITH SERIALIZER INFRA
        // TODO use set_context instead of the global thing perhaps?
        _storage = XPCStorage(
            myself: self.myself.asAddressable(),
            system: self.system,
            sendMessage: { message in
                // TODO THIS DUPLICATES LOGIC FROM _tellOrDeadLetter but that we'd like to keep internal...
                guard let _message = message as? A.Message else {
                    // traceLog_Mailbox(self.path, "_tellUnsafe: [\(message)] failed because of invalid message type, to: \(self); Sent at \(file):\(line)")
                    self.system.deadLetters.tell(DeadLetter(message, recipient: self.myself.address, sentAtFile: #file, sentAtLine: #line))
                    return // TODO: "drop" the message rather than dead letter it?
                }

                self.myself.tell(_message, file: file, line: line)
                // self.myself._tellOrDeadLetter(message)
            }
            // TODO; sendSystemMessage
        )
        _storageLock.unlock()

        // TODO use set_context instead of the global thing perhaps?
//        sact_xpc_main(&self.onConnectionContext, self.onConnectionCallback, self.onMessageCallback)
        xpc_main(xpc_connectionHandler)
    }

}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: XPC Callbacks

fileprivate func xpc_connectionHandler(peer: xpc_connection_t) {
    guard let storage = _storage else {
        return
    }

    let file = try! Folder(path: "/tmp").file(named: "xpc.txt")
    try! file.append("[actor service] CONNECT: \(peer)\n")

    xpc_connection_set_event_handler(peer, { (xdict: xpc_object_t) in
        xpc_eventHandler(storage, peer: peer, xdict: xdict)
    })

    xpc_connection_resume(peer)
}

fileprivate func xpc_eventHandler(_ storage: XPCStorage, peer: xpc_connection_t, xdict: xpc_object_t) {
    try! file.append("[actor service] [FROM: \(peer)]: \(xdict)\n")

    guard xpc_get_type(xdict) != XPC_TYPE_ERROR else {
        try! file.append("[actor service] ERROR [FROM: \(peer)]: \(xdict)\n")
        return
    }

    // TODO sanity check where to etc?

    // --- deserialize and deliver ---
    let message: Any
    do {
        let serializer = storage.system.serialization.serializer(for: 10001)!
        serializer.setUserInfo(key: .xpcConnection, value: peer)
        // defer { serializer.setUserInfo(key: .xpcConnection, value: nil as String?) }
        // try! file.append("Serializer: \(serializer)\n")

        message = try XPCSerialization.deserializeActorMessage(storage.system, peer: peer, xdict: xdict)
    } catch {
        try! file.append("Failed de-serializing xpc message [\(xdict)], error: \(error)\n")
        storage.system.log.warning("Failed de-serializing xpc message, error: \(error)")
        return
    }

    try! file.append("[actor service] Delivering \(message)\n")

    // TODO: what about replies etc
    // TODO: rather than always send to myself via this, we should resolve the envelopes recipient and deliver there
    storage.sendMessage(message)
}


//// Since we need to capture some context and pass this function to C.
//@usableFromInline
//internal struct XPCHandlerClosureContext {
//
//    @usableFromInline
//    let _tell: (xpc_connection_t) -> Void // TODO signature
//
//    @usableFromInline
//    init(tell: @escaping (xpc_connection_t) -> Void) {
//        self._tell = tell
//    }
//
//    func tell(_ message: Any) {
//        pprint("TELL: \(message)")
//    }
//}
