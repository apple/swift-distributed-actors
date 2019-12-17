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

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)

import DistributedActors
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

    public override init() {
        super.init()
    }

    override public var `protocol`: String {
        "xpc"
    }

    override public func onActorSystemStart(system: ActorSystem) {
        _ = try! system._spawnSystemActor("xpc", XPCMaster().behavior, perpetual: true)
    }

    override public func _resolve<Message>(context: ResolveContext<Message>) -> ActorRef<Message> {
        assert(context.address.node?.node.protocol == "xpc", "\(XPCActorTransport.self) was requested to resolve a non 'xpc' address, was: \(context.address)")

        do {
            return try ActorRef<Message>(
                .delegate(XPCServiceCellDelegate(system: context.system, address: context.address))
            )
        } catch {
            return context.personalDeadLetters
        }
    }

    override public func makeCellDelegate<Message>(system: ActorSystem, address: ActorAddress) throws -> CellDelegate<Message> {
        try XPCServiceCellDelegate(system: system, address: address)
    }

    /// Obtain `DispatchQueue` to be used to drive the xpc connection with this service.
    public func makeServiceQueue(serviceName: String) -> DispatchQueue {
        // similar to NSXPCConnection
        DispatchQueue.init(label: "com.apple.sakkana.xpc.\(serviceName)", target: DispatchQueue.global(qos: .default))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: XPCDeathWatcher

extension ActorSystem {
    internal var _xpcMaster: ActorRef<XPCMaster.Message> {
        let context: ResolveContext<XPCMaster.Message> =
            try! .init(address: .init(path: ActorPath._system.appending("xpc"), incarnation: .perpetual), system: self)
        return self._resolve(context: context)
    }
}

/// Responsible for managing watches of xpc services exposed as actors, such that watching them works the same as watching
/// any other actor. An XPC `INVALID`, after all, equivalent to a `Terminated` signal.
///
/// This corresponds to the `NodeDeathWatcher` for clustered actors.
final class XPCMaster {

    // TODO: key it by XPC ID
    private var watchers: [AddressableActorRef: Set<AddressableActorRef>] = [:]

    // private var serviceTombstones: [xpc_connection_t] = [] // TODO: Think if we need tombstones, or can rely on XPC doing the right thing

    enum Message {
        case xpcRegisterService(xpc_connection_t, AddressableActorRef)
        case xpcConnectionInvalidated(AddressableActorRef)
        case xpcConnectionInterrupted(AddressableActorRef)
        case xpcActorWatched(watchee: AddressableActorRef, watcher: AddressableActorRef)
        case xpcActorUnwatched(watchee: AddressableActorRef, watcher: AddressableActorRef)
        case watcherTerminated(AddressableActorRef)
    }

    var behavior: Behavior<Message> {
        return .setup { context in
            context.log.info("XPC transport initialized.")

            return .receiveMessage { message in
                switch message {
                case .xpcRegisterService(let connection, let ref):
                    // self.services[.init(connection: connection)] = ref
                    context.log.info("Registered: \(ref)")

                case .xpcConnectionInterrupted(let serviceRef):
                    // Unlike `Invalidated`/`Terminated` an `Interrupted` connection means that the service may be restarted
                    // (by launchd) and still remain valid. Thus we do NOT remove the watchers from the dictionary.
                    guard let watchers: Set<AddressableActorRef> = self.watchers[serviceRef] else {
                        return .same
                    }

                    let interrupted = _SystemMessage.carrySignal(Signals.XPC.XPCConnectionInterrupted(address: serviceRef.address, description: "Connection Interrupted"))
                    watchers.forEach { (watcher: AddressableActorRef) in
                        watcher._sendSystemMessage(interrupted) // TODO: carry description from transport
                    }

                case .xpcConnectionInvalidated(let serviceRef):
                    // FIXME: send the proper lifecycle signals -- the XPCSignals
                    guard let watchers: Set<AddressableActorRef> = self.watchers.removeValue(forKey: serviceRef) else {
                        return .same
                    }

                    let invalidated = _SystemMessage.carrySignal(Signals.XPC.XPCConnectionInvalidated(address: serviceRef.address, description: "Connection Interrupted"))
                    watchers.forEach { (watcher: AddressableActorRef) in
                        watcher._sendSystemMessage(invalidated)
                    }

                case .xpcActorWatched(let watchee, let watcher):
//                    guard !self.nodeTombstones.contains(remoteNode) else {
//                        watcher.sendSystemMessage(.nodeTerminated(remoteNode))
//                        return
//                    }

                    var existingWatchers = self.watchers[watchee] ?? []
                    existingWatchers.insert(watcher) // FIXME: we have to remove it once it terminates...

                    self.watchers[watchee] = existingWatchers

                    // TODO: Test for the racy case when we watch, unwatch, cause a failure; in the ActorCell we guarantee that we will not see such Interrupted then
                    // but without the cell we lost this guarantee. This would have to be implemented in the XPCServiceCellDelegate
                case .xpcActorUnwatched(let watchee, let watcher):
                    guard let watchers: Set<AddressableActorRef> = self.watchers[watchee] else {
                        // seems that watchee has no watchers, thus no need to remove this one.
                        // Realistically this should not happen in normal operations, but nothing is stopping people from issuing many `unwatch()`
                        // calls on the same reference after all, thus we only silently ignore them here.
                        return .same
                    }

                case .watcherTerminated(let watcher):
                    // FIXME: remove watcher
                    ()
                }

                return .same
            }

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

#else
/// XPC is only available on Apple platforms
#endif

