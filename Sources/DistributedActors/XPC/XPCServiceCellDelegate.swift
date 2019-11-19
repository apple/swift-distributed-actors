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
import Dispatch

#if os(macOS)

/// Keys used in xpc dictionaries sent as messages.
public enum ActorableXPCMessageField: String {
    case message = "M"
    case messageLength = "L"
    case serializerId = "S"
}

/// Delegates message handling to an XPC Service.
///
/// Messages are serialized as `xpc_dictionary` using the `XPCMessageField` keys, and may be received
/// by a service implemented in C using `libxpc` or `XPCActorable`.
// TODO: Support NSXPC?
internal final class XPCServiceCellDelegate<Message>: CellDelegate<Message> {

    private let _system: ActorSystem
    override var system: ActorSystem {
        self._system
    }
    private let _address: ActorAddress
    override var address: ActorAddress {
        self._address
    }
    /// XPC Connection to the service named `serviceName`
    let c: xpc_connection_t

    convenience init(system: ActorSystem, serviceName: String) {
        try! self.init(system: system, address: .init(
            node: UniqueNode(protocol: "xpc", systemName: "", host: "localhost", port: 1, nid: NodeID(1)),
            path: try! ActorPath(root: "xpc").appending(serviceName), incarnation: .perpetual)
        )
    }

    init(system: ActorSystem, address: ActorAddress) throws {
        self._system = system

        guard address.node?.node.protocol == "xpc" else {
            throw XPCServiceDelegateError(reason: "Address [\(address)] is NOT an xpc:// address!")
        }
        guard address.segments.first?.value == "xpc" else {
            throw XPCServiceDelegateError(reason: "Expected XPC ActorAddress's path to be nested under /xpc, yet was: \(address.path)")
        }
        guard address.segments.count == 2 else {
            throw XPCServiceDelegateError(reason: "Expected XPC ActorAddress to contain exactly 2 segments, yet was: \(address.segments)")
        }
        self._address = address

        // initialize connection
        let serviceName = address.path.segments.dropFirst().first!.value

        let queue = system.settings.xpc.makeServiceQueue(serviceName: serviceName)
        self.c = xpc_connection_create(serviceName, queue)
        xpc_connection_set_event_handler(c, { (event: xpc_object_t) in
            print("REPLY [FROM:\(address)]: \(event)")
        })
        xpc_connection_set_target_queue(c, queue)
        xpc_connection_resume(c)
    }

    override func sendMessage(_ message: Message, file: String = #file, line: UInt = #line) {

        // TODO offload async the serialization work?
        let xdict: xpc_object_t
        do {
            xdict = try XPCSerialization.serializeActorMessage(system, message: message)
        } catch {
            system.log.warning("Failed to serialize [\(String(reflecting: type(of: message)))] message, sent to XPC service actor \(self.address). Error: \(error)")
            return
        }

        xpc_connection_send_message(c, xdict)

//        // TODO serialization where exactly
//        xpc_dictionary_set_string(xdict, ActorableXPCMessageField.message.rawValue, "\(message)")
//        xpc_connection_send_message(c, xdict)

        self.system.log.info("[CLIENT pid:\(getpid()),t:\(_hackyPThreadThreadId())] sending: \(ActorableXPCMessageField.message.rawValue)=\(xdict)")

        // xpc_release(message)
//        /Users/ktoso/code/actors/Sources/DistributedActors/XPC/XPCCellDelegate.swift:48:9: error: 'xpc_release' is unavailable in Swift
//        xpc_release(message)
//            ^~~~~~~~~~~
//            XPC.xpc_release:3:13: note: 'xpc_release' has been explicitly marked unavailable here
//        public func xpc_release(_ object: xpc_object_t)
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
}

#else
/// XPC is only available on Apple platforms
#endif

public struct XPCServiceDelegateError: Error {
    let reason: String
}
