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

import NIO

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Protocol version

/// Wire Protocol version of this Swift Distributed Actors build.
public let DistributedActorsProtocolVersion: Swift Distributed ActorsActor.Version = Version(reserved: 0, major: 0, minor: 0, patch: 1)


// FIXME: !!!! all the Wire.Version and Wire.Handshake... do not really talk about wire; just Protocol so we should move them somehow -- ktoso
//        This is also important to keep the machine clean of any "network stuff", and just have "protocol stuff"

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Constants for Cluster

/// Magic 2 byte value for use as initial bytes in connections (before handshake).
/// Reads as: `5AC7 == SACT == S Act == Swift/Swift Distributed Actors Act == Swift/Swift Distributed Actors Actors`
internal let HandshakeMagicBytes: UInt16 = 0x5AC7


// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Handshake State Machine
// "All Handshakes want to become Associations when they grow up." -- unknown

internal struct HandshakeStateMachine {
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Directives

     enum StateWithDirective {
     }

    /// Directives are what instructs the state machine driver about what should be performed next.
    internal enum Directive {
        /// The handshake has completed successfully, and shall be "upgraded" to an association.
        /// The handshake has fulfilled its purpose and may be dropped.
        case acceptAndAssociate(CompletedState)

        /// The handshake has failed for some reason and the connection should be immediately closed.
        case rejectHandshake(RejectedState)
    }

    /// Directives controlling attempting to schedule retries for shaking hands with remote node.
    internal enum RetryDirective {
        /// Retry sending the returned handshake offer after the given `delay`
        /// Returned in reaction to timeouts or other recoverable failures during handshake negotiation.
        case scheduleRetryHandshake(delay: TimeAmount)

        /// Give up shaking hands with the remote peer.
        /// Any state the handshake was keeping on the initiating node should be cleared in response to this directive.
        case giveUpOnHandshake
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handshake Initiated

    internal struct InitiatedState {
        internal var backoff: BackoffStrategy
        let settings: ClusterSettings

        internal var protocolVersion: Swift Distributed ActorsActor.Version {
            return self.settings.protocolVersion
        }

        internal let remoteAddress: NodeAddress
        internal let localAddress: UniqueNodeAddress

        // TODO counter for how many times to retry associating (timeouts)

        init(settings: ClusterSettings, localAddress: UniqueNodeAddress, connectTo remoteAddress: NodeAddress) {
            precondition(localAddress.address != remoteAddress, "MUST NOT attempt connecting to own bind address. Address: \(remoteAddress)")
            self.settings = settings
            self.backoff = settings.handshakeBackoffStrategy
            self.localAddress = localAddress
            self.remoteAddress = remoteAddress
        }

        func makeOffer() -> Wire.HandshakeOffer {
            // TODO maybe store also at what time we sent the handshake, so we can diagnose if we should reject replies for being late etc
            return Wire.HandshakeOffer(version: self.protocolVersion, from: self.localAddress, to: self.remoteAddress)
        }

        mutating func onHandshakeTimeout() -> HandshakeStateMachine.RetryDirective {
            if let interval = self.backoff.next() {
                return .scheduleRetryHandshake(delay: interval)
            } else {
                return .giveUpOnHandshake
            }
        }

        mutating func onHandshakeError(_ error: Error) -> HandshakeStateMachine.RetryDirective {
            switch self.backoff.next() {
            case .some(let amount):
                return .scheduleRetryHandshake(delay: amount)
            case .none:
                return .giveUpOnHandshake
            }
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handshake Received

    /// Initial state for server side of handshake.
    internal struct HandshakeReceivedState {
        private let state: ReadOnlyClusterState

        public let offer: Wire.HandshakeOffer
        internal var boundAddress: UniqueNodeAddress {
            return self.state.localAddress
        }
        internal var protocolVersion: Swift Distributed ActorsActor.Version {
            return state.settings.protocolVersion
        }

        // do not call directly, rather obtain the completed state via negotiate()
        internal func _makeCompletedState() -> CompletedState {
            return CompletedState(fromReceived: self, remoteAddress: offer.from)
        }

        internal init(state: ReadOnlyClusterState, offer: Wire.HandshakeOffer) {
            self.state = state
            self.offer = offer
        }

        func negotiate() -> HandshakeStateMachine.Directive {
            guard self.boundAddress.address == self.offer.to else {
                let error = HandshakeError.targetHandshakeAddressMismatch(self.offer, selfAddress: self.boundAddress)
                return .rejectHandshake(RejectedState(fromReceived: self, remoteAddress: self.offer.from, error: error))
            }

            // negotiate version
            if let rejectionBecauseOfVersion = self.negotiateVersion(local: self.protocolVersion, remote: self.offer.version) {
                return rejectionBecauseOfVersion
            }

            // negotiate capabilities
            // self.negotiateCapabilities(...) // TODO: We may want to negotiate other options

            return .acceptAndAssociate(self._makeCompletedState())
        }

        // TODO determine the actual logic we'd want here, for now we accept anything except major changes; use semver?
        /// - Returns `rejectHandshake` or `nil`
        func negotiateVersion(local: Swift Distributed ActorsActor.Version, remote: Swift Distributed ActorsActor.Version) -> HandshakeStateMachine.Directive? {
            let accept: HandshakeStateMachine.Directive? = nil

            guard local.major == remote.major else {
                let error = HandshakeError.incompatibleProtocolVersion(
                    local: self.protocolVersion, remote: self.offer.version,
                    reason: "Major version mismatch!")
                return .rejectHandshake(RejectedState(fromReceived: self, remoteAddress: self.offer.from, error: error))
            }

            return accept
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handshake Completed

    /// State reached once we have received a `HandshakeAccepted` and are ready to create an association.
    /// This state is used to unlock creating an Association.
    internal struct CompletedState {
        internal let protocolVersion: Version
        internal var remoteAddress: UniqueNodeAddress
        internal var localAddress: UniqueNodeAddress
        // let unique association ID?

        // State Transition used by Client Side of initial Handshake.
        //
        // Since the client is the one who initiates the handshake, once it receives an Accept containing the remote unique address
        // it may immediately transition to the completed state.
        init(fromInitiated state: InitiatedState, remoteAddress: UniqueNodeAddress) {
            precondition(state.localAddress != remoteAddress, "Node [\(state.localAddress)] attempted to create association with itself.")
            self.protocolVersion = state.protocolVersion
            self.remoteAddress = remoteAddress
            self.localAddress = state.localAddress
        }

        // State Transition used by Client Side of initial Handshake.
        init(fromReceived state: HandshakeReceivedState, remoteAddress: UniqueNodeAddress) {
            precondition(state.boundAddress != remoteAddress, "Node [\(state.boundAddress)] attempted to create association with itself.")
            self.protocolVersion = state.protocolVersion
            self.remoteAddress = remoteAddress
            self.localAddress = state.boundAddress
        }

        func makeAccept() -> Wire.HandshakeAccept {
            return .init(version: self.protocolVersion, from: self.localAddress, origin: self.remoteAddress)
        }
    }

    internal struct RejectedState {
        internal let protocolVersion: Version
        internal let localAddress: NodeAddress
        internal let remoteAddress: UniqueNodeAddress
        internal let error: HandshakeError

        init(fromReceived state: HandshakeReceivedState, remoteAddress: UniqueNodeAddress, error: HandshakeError) {
            self.protocolVersion = state.protocolVersion
            self.localAddress = state.boundAddress.address
            self.remoteAddress = remoteAddress
            self.error = error
        }

        func makeReject() -> Wire.HandshakeReject {
            return .init(version: self.protocolVersion, from: self.localAddress, origin: remoteAddress, reason: "\(self.error)")
        }
    }

    internal enum State {
        case initiated(InitiatedState)
        case wasOfferedHandshake(HandshakeReceivedState)
        case completed(CompletedState)
    }

}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Handshake error types

enum HandshakeError: Error {
    /// The first handshake bytes did not match the expected "magic bytes";
    /// It is very likely the other side attempting to connect to our port is NOT a Swift Distributed Actors system,
    /// thus we should reject it immediately. This can happen due to misconfiguration, e.g. mixing
    /// up ports and attempting to send HTTP or other data to a Swift Distributed Actors networking port.
    case illegalHandshakeMagic(was: UInt16, expected: UInt16)

    /// Attempted accepting handshake which was not in progress.
    /// Could mean that the sending side sent the accept twice?
    case acceptAttemptForNotInProgressHandshake(Wire.HandshakeAccept)

    /// The node at which the handshake arrived does not recognize the "to" address of the handshake.
    /// This may be a configuration issue (due to bind address and NAT mixups), or a routing issue
    /// where the handshake was received at "the wrong node".
    ///
    /// The UID part of the `NodeAddress` does not matter for this check, but is included here for debugging purposes.
    case targetHandshakeAddressMismatch(Wire.HandshakeOffer, selfAddress: UniqueNodeAddress)

    /// Returned when an incoming handshake protocol version does not match what this node can understand.
    case incompatibleProtocolVersion(local: Swift Distributed ActorsActor.Version, remote: Swift Distributed ActorsActor.Version, reason: String?)

}
