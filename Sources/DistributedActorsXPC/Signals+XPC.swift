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

import DistributedActors
import XPC
import Dispatch

extension Signals {

    /// Namespace for Signals specific to XPC services.
    public enum XPC {

        /// (XPC Message Documentation)
        ///
        /// Will be delivered to the connection's event handler if the remote service
        /// exited. The connection is still live even in this case, and resending a
        /// message will cause the service to be launched on-demand. This error serves
        /// as a client's indication that it should resynchronize any state that it had
        /// given the service.
        ///
        /// Any messages in the queue to be sent will be unwound and canceled when this
        /// error occurs. In the case where a message waiting to be sent has a reply
        /// handler, that handler will be invoked with this error. In the context of the
        /// reply handler, this error indicates that a reply to the message will never
        /// arrive.
        ///
        /// Messages that do not have reply handlers associated with them will be
        /// silently disposed of. This error will only be given to peer connections.
        ///
        /// - SeeAlso: `XPC_ERROR_CONNECTION_INTERRUPTED` (`connection.h`)
        public struct Interrupted: Signal, CustomStringConvertible {
            public let address: ActorAddress
            public let _description: String

            public init(address: ActorAddress, description: String) {
                self.address = address
                self._description = description
            }

            public var description: String {
                "Signals.XPC.Interrupted(\(self.address), description: \"\(self._description)\")"
            }
        }

        /// (XPC Message Documentation)
        ///
        /// IS-A `Signals.Terminated` as it is semantically equivalent to it.
        /// Once an XPC service has signalled `XPCConnectionInvalidated` the same
        /// connection/service will never yield any more messages.
        ///
        /// Will be delivered to the connection's event handler if the named service
        /// provided to xpc_connection_create() could not be found in the XPC service
        /// namespace. The connection is useless and should be disposed of.
        ///
        /// Any messages in the queue to be sent will be unwound and canceled when this
        /// error occurs, similarly to the behavior when XPC_ERROR_CONNECTION_INTERRUPTED
        /// occurs. The only difference is that the XPC_ERROR_CONNECTION_INVALID will be
        /// given to outstanding reply handlers and the connection's event handler.
        ///
        /// This error may be given to any type of connection.
        ///
        /// - SeeAlso: `XPC_ERROR_CONNECTION_INVALID` (`connection.h`)
        public final class Invalidated: Signals.Terminated {
            let _description: String

            public init(address: ActorAddress, description: String) {
                self._description = description
                let existenceConfirmed = true // TODO: we could know this
                let nodeTerminated = true // TODO: a bit weird for XPC
                // TODO: the true on nodeTerminated reads a bit weird, we could drop it or rename it
                super.init(address: address, existenceConfirmed: existenceConfirmed, nodeTerminated: nodeTerminated)
            }

            public override var description: String {
                "Signals.XPC.Invalidated(\(self.address), description: \"\(self._description)\")"
            }
        }

    }

}

