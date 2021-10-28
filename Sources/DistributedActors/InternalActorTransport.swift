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

import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: _InternalActorTransport

/// INTERNAL API
/// Internal protocol allowing for introduction of additional transports.
open class _InternalActorTransport {
    public init() {
        // nothing
    }

    open var protocolName: String {
        fatalError("Not implemented: \(#function) in \(self) transport!")
    }

    open func onActorSystemStart(system: ActorSystem) {
        // do nothing by default
    }

    open func onActorSystemPark() {
        // do nothing by default
    }

    open func onActorSystemShutdown() {
        // do nothing by default
    }

    /// May return `nil` if this transport is NOT able to resolve this ref.
    open func _resolve<Message>(context: ResolveContext<Message>) -> _ActorRef<Message>? {
        fatalError("Not implemented: \(#function) in \(self) transport! Attempted to resolve: \(context)")
    }

    /// May return `nil` if this transport is NOT able to resolve this ref.
    open func _resolveUntyped(context: ResolveContext<Never>) -> AddressableActorRef? {
        fatalError("Not implemented: \(#function) in \(self) transport! Attempted to resolve: \(context)")
    }

    open func makeCellDelegate<Message>(system: ActorSystem, address: ActorAddress) throws -> _CellDelegate<Message> {
        fatalError("Not implemented: \(#function) in \(self) transport!")
    }
}
