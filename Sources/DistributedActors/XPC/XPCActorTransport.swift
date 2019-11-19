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

extension ActorTransport {

    public static var xpc: XPCActorTransport {
        .default
    }
}

public class XPCActorTransport: ActorTransport {

    public static var `default`: XPCActorTransport {
        .init()
    }

    override public var `protocol`: String {
        "xpc"
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
