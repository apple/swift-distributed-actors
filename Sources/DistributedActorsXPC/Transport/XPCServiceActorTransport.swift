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
import Files

fileprivate let _file = try! Folder(path: "/tmp").file(named: "xpc.txt")


public final class XPCServiceActorTransport: ActorTransport {

    private let lock = _Mutex()
    internal var system: ActorSystem!

    public override init() {
        super.init()
    }

    public static let protocolName: String = "xpcService"
    override public var protocolName: String {
        Self.protocolName
    }

    override public func onActorSystemStart(system: ActorSystem) {
        self.lock.synchronized {
            self.system = system
        }
    }

    override public func onActorSystemShutdown() {
        self.lock.synchronized {
            self.system = nil
        }
    }

    // FIXME: This is a bit hacky...
    // We are in an XPC Service and want to deserialize all actor refs as pointing to the application process.
    override public func _resolve<Message>(context: ResolveContext<Message>) -> ActorRef<Message>? {
        try! _file.append("\(#function) @ \(#file):\(#line) trying to resolve: \(context.address): \(context.userInfo.xpcConnection)\n")

        guard let xpcConnection = context.userInfo.xpcConnection else {
            return nil
        }

        let delegate = ActorRef<Message>(.delegate(XPCProxiedRefDelegate(system: context.system, origin: xpcConnection, address: context.address)))
        try! _file.append("\(#file):\(#line) DELEGATE: \(delegate)\n")
        return delegate
    }

    override public func _resolveUntyped(context: ResolveContext<Any>) -> AddressableActorRef? {
        guard let xpcConnection = context.userInfo.xpcConnection else {
            return nil
        }

        let delegate = ActorRef<Any>(
            .delegate(XPCProxiedRefDelegate(system: context.system, origin: xpcConnection, address: context.address))
        ).asAddressable()
        try! _file.append("\(#file):\(#line) DELEGATE: \(delegate)\n")
        return delegate
    }


    override public func makeCellDelegate<Message>(system: ActorSystem, address: ActorAddress) throws -> CellDelegate<Message> {
        try XPCServiceCellDelegate(system: system, address: address)
    }

    /// Obtain `DispatchQueue` to be used to drive the xpc connection with this service.
    internal func makeServiceQueue(serviceName: String) -> DispatchQueue {
        // similar to NSXPCConnection
        DispatchQueue.init(label: "com.apple.sakkana.xpc.\(serviceName)", target: DispatchQueue.global(qos: .default))
    }
}

extension ActorTransport {
    public static var xpcService: XPCServiceActorTransport {
        XPCServiceActorTransport()
    }
}

extension Dictionary where Key == ActorSystemSettings.ProtocolName, Value == ActorTransport {
    public static var xpcService: Self {
        let transport = XPCServiceActorTransport()
        return [transport.protocolName: transport]
    }
}

#else
/// XPC is only available on Apple platforms
#endif

