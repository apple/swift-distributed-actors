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

import XPC
import Files

#if os(macOS)

fileprivate let _file = try! Folder(path: "/tmp").file(named: "xpc.txt")

///// Keys used in xpc dictionaries sent as messages.
//public enum ActorableXPCMessageField: String {
//    case message = "M"
//    case messageLength = "L"
//    case serializerId = "S"
//    case recipientId = "R"
//}

/// When an XPC service was sent a "real" actor ref and replies to it, we want to capture this logic in this "proxy"
/// which will make the reply happen over XPC, in such way that the other side can deserialize the actual destination.
internal final class XPCProxiedRefDelegate<Message>: CellDelegate<Message>, CustomStringConvertible {

    /// The "origin" peer on which the actor we're proxying to lives.
    private let peer: xpc_connection_t

    private let _system: ActorSystem
    override var system: ActorSystem {
        self._system
    }

    private let _address: ActorAddress
    override var address: ActorAddress {
        self._address
    }

    init(system: ActorSystem, origin: xpc_connection_t, address: ActorAddress) {
        self._system = system
        self.peer = origin
        self._address = address
    }

    override func sendMessage(_ message: Message, file: String = #file, line: UInt = #line) {
        try! _file.append("Trying to reply to \(self)\n")

        let xdict: xpc_object_t
        do {
            // TODO: optimize serialization some more
            xdict = try XPCSerialization.serializeActorMessage(self.system, message: message)

            // TODO: Do this as serializeEnvelope
            try XPCSerialization.serializeRecipient(system, xdict: xdict, address: self.address)
        } catch {
            try! _file.append("error \(error)\n")
            system.log.warning("Failed to serialize [\(String(reflecting: type(of: message)))] message, sent to XPC service actor \(self.address). Error: \(error)")
            try! _file.append("Failed to serialize [\(String(reflecting: type(of: message)))] message, sent to XPC service actor \(self.address). Error: \(error)\n")
            return
        }

        try! _file.append("Reply message \(xdict)\n")

        self.system.log.info("Sending to \(self.address): \(message)")
        try! _file.append("Sending to \(self): \(message)\n")
        xpc_connection_send_message(self.peer, xdict)

    }

    override func sendSystemMessage(_ message: SystemMessage, file: String = #file, line: UInt = #line) {
        self.system.log.info("DROPPING system message \(message) sent at \(file):\(line)")
    }

    override func sendClosure(file: String = #file, line: UInt = #line, _ f: @escaping () throws -> ()) {
        self.system.log.info("DROPPING closure sent at \(file):\(line)")
    }

    override func sendSubMessage<SubMessage>(_ message: SubMessage, identifier: AnySubReceiveId, subReceiveAddress: ActorAddress, file: String = #file, line: UInt = #line) {
        self.system.log.info("DROPPING sub-message \(message) sent at \(file):\(line)")
    }

    override func sendAdaptedMessage(_ message: Any, file: String = #file, line: UInt = #line) {
        self.system.log.info("DROPPING adapted \(message) sent at \(file):\(line)")
    }

    var description: String {
        "XPCProxiedRefDelegate<\(String(reflecting: Message.self))>(\(_address), peer: \(peer))"
    }
}

#else
/// XPC is only available on Apple platforms
#endif
