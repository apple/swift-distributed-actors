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

import Dispatch
import XPC

extension ActorTransport {

    public static var xpc: XPCActorTransport {
        XPCActorTransport()
    }

}

extension Array where Element == ActorTransport {
    public static var xpc: [XPCActorTransport] {
        [XPCActorTransport()]
    }
}

public final class XPCActorTransport: ActorTransport {

    override public var `protocol`: String {
        "xpc"
    }

    override func onActorSystemStart(system: ActorSystem) {
        _ = try! system._spawnSystemActor("xpc", XPCMaster().behavior)
    }

    override func makeCellDelegate<Message>(system: ActorSystem, address: ActorAddress) throws -> CellDelegate<Message> {
        try XPCServiceCellDelegate(system: system, address: address)
    }

    /// Obtain `DispatchQueue` to be used to drive the xpc connection with this service.
    public func makeServiceQueue(serviceName: String) -> DispatchQueue {
        // similar to NSXPCConnection
        DispatchQueue.init(label: "com.apple.distributedactors.xpc.\(serviceName)", target: DispatchQueue.global(qos: .default))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: XPCDeathWatcher

extension ActorSystem {
    internal var _xpcMaster: ActorRef<XPCDeathWatcher.Message> {
        let context: ResolveContext<XPCDeathWatcher.Message> =
            try! .init(address: .init(path: ActorPath._system.appending("xpc"), incarnation: .perpetual), system: self)
        return self._resolve(context: context)
    }
}

/// The XPC equivalent of monitoring nodes for crashes.
typealias XPCDeathWatcher = XPCMaster

/// Responsible for managing watches of xpc services exposed as actors, such that watching them works the same as watching
/// any other actor. An XPC `INVALID`, after all, equivalent to a `Terminated` signal.
///
/// This corresponds to the `NodeDeathWatcher` for clustered actors.
final class XPCMaster {

    var watchers: [AddressableActorRef: Set<AddressableActorRef>] = [:]
    var services: [XPCConnectionBox: AddressableActorRef] = [:]
    var serviceTombstones: [xpc_connection_t] = []

    enum Message {
        case xpcRegisterService(xpc_connection_t, AddressableActorRef)
        case xpcConnectionInvalidated(xpc_connection_t)
        case xpcConnectionInterrupted(xpc_connection_t)
        case watcherTerminated(AddressableActorRef)
    }

    var behavior: Behavior<Message> {
        .receive { context, message in
            switch message {
            case .xpcRegisterService(let connection, let ref):
                self.services[.init(connection: connection)] = ref

            case .xpcConnectionInterrupted(let connection):
                let key = XPCConnectionBox(connection: connection)
                guard let serviceRef = self.services.removeValue(forKey: key) else {
                    // TODO: check the tombstones
                    return .same
                }

                // FIXME: send the proper lifecycle signals -- the XPCSignals
                if let watchers: Set<AddressableActorRef> = self.watchers.removeValue(forKey: serviceRef) {
                    watchers.forEach { (watcher: AddressableActorRef) in
                        watcher.sendSystemMessage(.terminated(ref: serviceRef, existenceConfirmed: true, addressTerminated: true))
                    }
                }

            case .xpcConnectionInvalidated(let connection):
                let key = XPCConnectionBox(connection: connection)
                guard let serviceRef = self.services.removeValue(forKey: key) else {
                    // TODO: check the tombstones
                    return .same
                }

                // FIXME: send the proper lifecycle signals -- the XPCSignals
                if let watchers: Set<AddressableActorRef> = self.watchers.removeValue(forKey: serviceRef) {
                    watchers.forEach { (watcher: AddressableActorRef) in
                        watcher.sendSystemMessage(.terminated(ref: serviceRef, existenceConfirmed: true, addressTerminated: true))
                    }
                }

            case .watcherTerminated(let watcher):
                // FIXME: remove watcher
                ()
            }

            return .same
        }
    }
}

// TODO what is the proper way to key a connection
struct XPCConnectionBox: Hashable {
    let connection: xpc_connection_t

    init(connection: xpc_connection_t) {
        self.connection = connection
    }

    func hash(into hasher: inout Hasher) {
        // FIXME: this is likely wrong
        xpc_connection_get_pid(self.connection).hash(into: &hasher)
    }

    static func ==(lhs: XPCConnectionBox, rhs: XPCConnectionBox) -> Bool {
        // FIXME: this is likely wrong
        xpc_connection_get_pid(lhs.connection) == xpc_connection_get_pid(rhs.connection)
    }
}
