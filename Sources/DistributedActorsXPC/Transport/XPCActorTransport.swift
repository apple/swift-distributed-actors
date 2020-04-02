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

import Dispatch
import DistributedActors
import Files
import XPC

fileprivate let _file = try! Folder(path: "/tmp").file(named: "xpc.txt")

public final class XPCActorTransport: ActorTransport {
    private let lock = _Mutex()

    private var _master: ActorRef<XPCMaster.Message>?
    internal var master: ActorRef<XPCMaster.Message> {
        self.lock.synchronized {
            if let m = self._master {
                return m
            } else {
                fatalError("XPCMaster not initialized! This is potentially Actors bug.")
            }
        }
    }

    internal var system: ActorSystem!

    public override init() {
        super.init()
    }

    public static let protocolName: String = "xpc"
    public override var protocolName: String {
        Self.protocolName
    }

    public override func onActorSystemStart(system: ActorSystem) {
        self.lock.synchronized {
            self._master = try! system._spawnSystemActor("xpc", XPCMaster().behavior, props: ._wellKnown)
            self.system = system
        }
    }

    public override func onActorSystemShutdown() {
        self.lock.synchronized {
            self._master?.tell(.stop)
            self.system = nil
        }
    }

    public override func _resolve<Message>(context: ResolveContext<Message>) -> ActorRef<Message>? {
        guard context.address.starts(with: ._xpc) else {
            return nil
        }

        do {
            return try ActorRef<Message>(
                .delegate(XPCServiceCellDelegate(system: context.system, address: context.address))
            )
        } catch {
            context.system.log.error("Failed to \(#function) [\(context.address)] as \(ActorRef<Message>.self), error: \(error)")
            return context.personalDeadLetters
        }
    }

    public override func _resolveUntyped(context: ResolveContext<Never>) -> AddressableActorRef? {
        guard context.address.starts(with: ._xpc) else {
            return nil
        }

        do {
            return try ActorRef<Never>(
                .delegate(XPCServiceCellDelegate(system: context.system, address: context.address))
            ).asAddressable()
        } catch {
            context.system.log.error("Failed to \(#function) [\(context.address)], error: \(error)")
            return context.personalDeadLetters.asAddressable()
        }
    }

    public override func makeCellDelegate<Message>(system: ActorSystem, address: ActorAddress) throws -> CellDelegate<Message> {
        try XPCServiceCellDelegate(system: system, address: address)
    }

    /// BLOCKS THE CALLING THREAD.
    /// Invokes `Dispatch`'s `dispatchMain()` as it is needed to kick off XPC processing.
    public override func onActorSystemPark() {
        dispatchMain()
    }

    /// Obtain `DispatchQueue` to be used to drive the xpc connection with this service.
    internal func makeServiceQueue(serviceName: String) -> DispatchQueue {
        // similar to NSXPCConnection
        DispatchQueue(label: "com.apple.actors.xpc.\(serviceName)", target: DispatchQueue.global(qos: .default))
    }
}

extension ActorTransport {
    public static var xpc: XPCActorTransport {
        XPCActorTransport()
    }
}

extension Dictionary where Key == ActorSystemSettings.ProtocolName, Value == ActorTransport {
    public static var xpc: Self {
        let transport = XPCActorTransport()
        return [transport.protocolName: transport]
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: XPCControl

extension XPCActorTransport: XPCControl {
    /// Returns an `Actor` representing a reference to an XPC service with the passed in `serviceName`.
    ///
    /// No validation is performed about matching message type, nor the existence of the service synchronously.
    ///
    /// In order to use this API, the service should be implemented as an `Actorable`.
    public func actor<A: Actorable>(_ actorableType: A.Type, serviceName: String) throws -> Actor<A> {
        let reference = try self.ref(A.Message.self, serviceName: serviceName)
        return Actor(ref: reference)
    }

    /// Returns an `ActorRef` representing a reference to an XPC service with the passed in `serviceName`.
    ///
    /// No validation is performed about matching message type, nor the existence of the service synchronously.
    public func ref<Message>(_ type: Message.Type = Message.self, serviceName: String) throws -> ActorRef<Message> {
        // fake node; ensure that this does not get us in trouble; e.g. cluster trying to connect to this fake node etc
        let fakeNode = UniqueNode(protocol: "xpc", systemName: "", host: "localhost", port: 1, nid: .init(1)) // TODO: a bit ugly special "xpc://" would be nicer
        let targetAddress: ActorAddress = try ActorAddress(
            node: fakeNode,
            path: ActorPath([ActorPathSegment("xpc"), ActorPathSegment(serviceName)]),
            incarnation: .wellKnown
        )

        // TODO: passing such ref over the network would fail; where should we prevent this?
        let xpcDelegate = try XPCServiceCellDelegate<Message>(
            system: self.system,
            address: targetAddress
        )

        return ActorRef<Message>(.delegate(xpcDelegate))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorSystem + XPC

extension ActorSystem {
    /// Offers ways to control and perform lookups of `Actorable` XPC services.
    /// - Faults when: the xpc transport is not installed in the system this is called on.
    public var xpc: XPCControl {
        self.xpcTransport
    }

    internal var xpcTransport: XPCActorTransport {
        guard let transport = self.settings.transports.first(where: { $0.protocolName == XPCActorTransport.protocolName }) else {
            fatalError("XPC transport not installed in \(self), installed transports are: \(self.settings.transports). Ensure to `settings.transports += .some` any transport you intend to use.")
        }

        guard let xpcTransport = transport as? XPCActorTransport else {
            fatalError("Transport available for protocol [\(XPCActorTransport.protocolName)] but it is not the \(XPCActorTransport.self)! Was: \(transport)")
        }

        return xpcTransport
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

    enum Message: NotTransportableActorMessage {
        case xpcRegisterService(xpc_connection_t, AddressableActorRef)
        case xpcConnectionInvalidated(AddressableActorRef)
        case xpcConnectionInterrupted(AddressableActorRef)
        case xpcActorWatched(watchee: AddressableActorRef, watcher: AddressableActorRef)
        case xpcActorUnwatched(watchee: AddressableActorRef, watcher: AddressableActorRef)
        case watcherTerminated(AddressableActorRef)
        case stop
    }

    var behavior: Behavior<Message> {
        .setup { context in
            context.log.info("XPC transport initialized.")

            return .receiveMessage { message in
                switch message {
                case .xpcRegisterService(_, let ref):
                    // self.services[.init(connection: connection)] = ref
                    context.log.info("Registered: \(ref)")

                case .xpcConnectionInterrupted(let serviceRef):
                    // Unlike `Invalidated`/`Terminated` an `Interrupted` connection means that the service may be restarted
                    // (by launchd) and still remain valid. Thus we do NOT remove the watchers from the dictionary.
                    guard let watchers: Set<AddressableActorRef> = self.watchers[serviceRef] else {
                        return .same
                    }

                    let interrupted = _SystemMessage.carrySignal(Signals.XPC.Interrupted(address: serviceRef.address, description: "Connection Interrupted"))
                    watchers.forEach { (watcher: AddressableActorRef) in
                        watcher._sendSystemMessage(interrupted) // TODO: carry description from transport
                    }

                case .xpcConnectionInvalidated(let serviceRef):
                    // FIXME: send the proper lifecycle signals -- the XPCSignals
                    guard let watchers: Set<AddressableActorRef> = self.watchers.removeValue(forKey: serviceRef) else {
                        return .same
                    }

                    let invalidated = _SystemMessage.carrySignal(Signals.XPC.Invalidated(address: serviceRef.address, description: "Connection Interrupted"))
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
                case .xpcActorUnwatched:
                    // FIXME: this is incomplete, see https://github.com/apple/swift-distributed-actors/issues/372
//                    guard let watchers: Set<AddressableActorRef> = self.watchers[watchee] else {
//                        // seems that watchee has no watchers, thus no need to remove this one.
//                        // Realistically this should not happen in normal operations, but nothing is stopping people from issuing many `unwatch()`
//                        // calls on the same reference after all, thus we only silently ignore them here.
//                        return .same
//                    }
                    context.log.warning("Unwatch is not implemented yet for XPC transport, see https://github.com/apple/swift-distributed-actors/issues/372")

                case .watcherTerminated:
                    // FIXME: remove watcher; this is incomplete, see https://github.com/apple/swift-distributed-actors/issues/372
                    context.log.warning("NOT IMPLEMENTED; watcherTerminated should remove watcher from watcher lists, see https://github.com/apple/swift-distributed-actors/issues/372")

                case .stop:
                    // FIXME: send terminated to all watchers // TODO: Add tests
                    self.watchers.forEach { watchee, watchers in
                        let signal = Signals.XPC.Invalidated(address: watchee.address, description: "XPC transport is shutting down.")
                        watchers.forEach {
                            $0._sendSystemMessage(.carrySignal(signal))
                        }
                    }
                    return .stop
                }

                return .same
            }
        }
    }
}

// TODO: what is the proper way to key a connection
struct XPCConnectionBox: Hashable {
    let connection: xpc_connection_t

    init(connection: xpc_connection_t) {
        self.connection = connection
    }

    func hash(into hasher: inout Hasher) {
        // FIXME: this is likely wrong
        xpc_connection_get_pid(self.connection).hash(into: &hasher)
    }

    static func == (lhs: XPCConnectionBox, rhs: XPCConnectionBox) -> Bool {
        // FIXME: this is likely wrong
        xpc_connection_get_pid(lhs.connection) == xpc_connection_get_pid(rhs.connection)
    }
}

#else
/// XPC is only available on Apple platforms
#endif
