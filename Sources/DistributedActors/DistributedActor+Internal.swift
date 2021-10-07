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

import _Distributed

extension AnyActorIdentity {
    var _unwrapActorAddress: ActorAddress? {
        self.underlying as? ActorAddress
    }

    var _forceUnwrapActorAddress: ActorAddress {
        guard let address = self._unwrapActorAddress else {
            fatalError("""
                       Cannot unwrap \(ActorAddress.self) from \(Self.self). 
                       Cluster currently does not support any other ActorIdentity types.
                       Underlying type was: \(type(of: self.underlying))
                       """)
        }

        return address
    }
}

extension ActorTransport {
    var _unwrapActorSystem: ActorSystem? {
        self as? ActorSystem
    }

    var _forceUnwrapActorSystem: ActorSystem {
        guard let system = self._unwrapActorSystem else {
            fatalError("""
                       Cannot unwrap \(ActorSystem.self) from \(Self.self). 
                       Cluster does not support mixing transports. Instance was: \(self) 
                       """)
        }

        return system
    }
}