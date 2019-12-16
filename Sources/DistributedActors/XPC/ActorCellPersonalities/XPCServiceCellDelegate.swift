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

/// Delegates message handling to an XPC Service.
///
/// Messages are serialized as `xpc_dictionary` using the `XPCMessageField` keys, and may be received
/// by a service implemented in C using `libxpc` or `XPCActorable`.
internal final class XPCServiceCellDelegate<Message>: CellDelegate<Message> {

    /// XPC Connection to the service named `serviceName`
    private let peer: xpc_connection_t

    private let _system: ActorSystem
    override var system: ActorSystem {
        self._system
    }
    private let _address: ActorAddress
    override var address: ActorAddress {
        self._address
    }

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
        self.peer = xpc_connection_create(serviceName, queue)

        super.init()

        // register connection with death-watcher (when it is Invalidated, we need to signal Terminated to all watchers)
        let myself = ActorRef<Message>(.delegate(self))
        // system._xpcMaster.tell(.xpcRegisterService(self.peer, myself.asAddressable())) // TODO: do we really need it?

        xpc_connection_set_event_handler(self.peer, { (xdict: xpc_object_t) in
            var log = ActorLogger.make(system: system, identifier: "\(myself.address.name)")
            log[metadataKey: "actorPath"] = .lazyStringConvertible { address }
            // TODO: connection id?

            switch xpc_get_type(xdict) {
//            // FIXME: Find a nice way to switch over it rather the string hack
//            case XPC_TYPE_ERROR where event == _xpc_error_connection_interrupted:
//                log.error("[xpc] Interrupted: \(event)")
//                system._xpcMaster.tell(.xpcConnectionInterrupted(self.peer))
//            case XPC_TYPE_ERROR where event == XPC_ERROR_CONNECTION_INVALID:
//                log.error("[xpc] Invalidated: \(event)")
//                system._xpcMaster.tell(.xpcConnectionInvalidated(self.peer))
            case XPC_TYPE_ERROR:
                if let errorDescription = xpc_dictionary_get_string(xdict, "XPCErrorDescription"), errorDescription.pointee != nil {
                    if String(cString: errorDescription).contains("Connection interrupted") {
                        log.error("XPC Interrupted Error: \(xdict)")
                        system._xpcMaster.tell(.xpcConnectionInterrupted(self.peer)) // TODO maybe rather pass the ref?
                    } else if String(cString: errorDescription).contains("Connection invalid") { // TODO: Verify this... (or rather, replace with switches)
                        log.error("XPC Invalid Error: \(xdict)")
                        system._xpcMaster.tell(.xpcConnectionInvalidated(self.peer)) // TODO maybe rather pass the ref?
                    } else {
                        log.error("XPC Error: \(xdict)")
                    }
                } else {
                    log.error("XPC Error: \(xdict)")
                }
            default:
                log.info("MESSAGE [FROM:\(address)]: \(xdict)")
                let message: Any
                do {
                    message = try XPCSerialization.deserializeActorMessage(system, peer: self.peer, xdict: xdict)
                } catch {
                    log.error("Dropping message, due to deserialization error: \(error)")
                    return
                }
                
                do {
                    let recipient = try XPCSerialization.deserializeRecipient(system, xdict: xdict)
                    recipient._tellOrDeadLetter(message)
                } catch {
                    self.system.log.error("no recipient, error: \(error)")
                    return
                }
            }
        })
        xpc_connection_set_target_queue(self.peer, queue)
        xpc_connection_resume(self.peer)
    }

    override func sendMessage(_ message: Message, file: String = #file, line: UInt = #line) {
        // TODO offload async the serialization work?
        let xdict: xpc_object_t
        do {
            // TODO: optimize serialization some more
            xdict = try XPCSerialization.serializeActorMessage(system, message: message)
        } catch {
            system.log.warning("Failed to serialize [\(String(reflecting: type(of: message)))] message, sent to XPC service actor \(self.address). Error: \(error)")
            return
        }

        xpc_connection_send_message(self.peer, xdict)

        self.system.log.info("Sending to \(self.address): \(message)")
        // self.system.log.info("Sending to \(self): \(ActorableXPCMessageField.message.rawValue)=\(xdict)")
    }

    override func sendSystemMessage(_ message: SystemMessage, file: String = #file, line: UInt = #line) {
        self.system.log.info("DROPPING system message \(message) sent at \(file):\(line)")
    }

    override func sendClosure(file: String = #file, line: UInt = #line, _ f: @escaping () throws -> ()) {
        fatalError("Attempted to send closure (defined at \(file):\(line)) to XPC Service \(self.address). This is not supported!")
    }

    override func sendSubMessage<SubMessage>(_ message: SubMessage, identifier: AnySubReceiveId, subReceiveAddress: ActorAddress, file: String = #file, line: UInt = #line) {
        self.system.log.warning("DROPPING sub-message \(message) sent at \(file):\(line)") // FIXME: Should be made to work
    }

    override func sendAdaptedMessage(_ message: Any, file: String = #file, line: UInt = #line) {
        self.system.log.warning("DROPPING adapted \(message) sent at \(file):\(line)") // FIXME: Should be made to work
    }
}


public struct XPCServiceDelegateError: Error {
    let reason: String
}

#else
/// XPC is only available on Apple platforms
#endif
