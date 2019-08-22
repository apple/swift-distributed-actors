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
public let DistributedActorsProtocolVersion: DistributedActors.Version = Version(reserved: 0, major: 0, minor: 0, patch: 1)

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Constants for Cluster

/// Magic 2 byte value for use as initial bytes in connections (before handshake).
/// Reads as: `5AC7 == SACT == S Act == Swift/Swift Distributed Actors Act == Swift/Swift Distributed Actors`
internal let HandshakeMagicBytes: UInt16 = 0x5AC7

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Handshake State Machine

// "All Handshakes want to become Associations when they grow up." -- unknown

internal struct HandshakeStateMachine {
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Directives

    /// Directives are what instructs the state machine driver about what should be performed next.
    internal enum NegotiateDirective {
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
        var backoff: BackoffStrategy
        let settings: ClusterSettings

        var protocolVersion: DistributedActors.Version {
            return self.settings.protocolVersion
        }

        let remoteNode: Node
        let localNode: UniqueNode
        let whenCompleted: EventLoopPromise<Wire.HandshakeResponse>?

        /// Channel which was established when we initiated the handshake (outgoing connection),
        /// which may want to be closed when we `abortHandshake` and want to kill the related outgoing connection as we do so.
        ///
        /// This is ALWAYS set once the initial clientBootstrap has completed.
        var channel: Channel?

        // TODO: counter for how many times to retry associating (timeouts)

        init(settings: ClusterSettings, localNode: UniqueNode, connectTo remoteNode: Node,
             whenCompleted: EventLoopPromise<Wire.HandshakeResponse>?) {
            precondition(localNode.node != remoteNode, "MUST NOT attempt connecting to own bind address. Address: \(remoteNode)")
            self.settings = settings
            self.backoff = settings.handshakeBackoffStrategy
            self.localNode = localNode
            self.remoteNode = remoteNode
            self.whenCompleted = whenCompleted
        }

        func makeOffer() -> Wire.HandshakeOffer {
            // TODO: maybe store also at what time we sent the handshake, so we can diagnose if we should reject replies for being late etc
            return Wire.HandshakeOffer(version: self.protocolVersion, from: self.localNode, to: self.remoteNode)
        }

        mutating func onHandshakeTimeout() -> HandshakeStateMachine.RetryDirective {
            if let interval = self.backoff.next() {
                return .scheduleRetryHandshake(delay: interval)
            } else {
                return .giveUpOnHandshake
            }
        }

        mutating func onChannelConnected(channel: Channel) {
            self.channel = channel
        }

        mutating func onHandshakeError(_: Error) -> HandshakeStateMachine.RetryDirective {
            switch self.backoff.next() {
            case .some(let amount):
                return .scheduleRetryHandshake(delay: amount)
            case .none:
                return .giveUpOnHandshake
            }
        }
    }

//    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handshake In-Flight, and should attach to existing negotiation

    internal struct InFlightState {
        private let state: ReadOnlyClusterState

        let whenCompleted: EventLoopPromise<Wire.HandshakeResponse>

        init(state: ReadOnlyClusterState, whenCompleted: EventLoopPromise<Wire.HandshakeResponse>) {
            self.state = state
            self.whenCompleted = whenCompleted
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handshake Received

    /// Initial state for server side of handshake.
    internal struct HandshakeReceivedState {
        private let state: ReadOnlyClusterState

        let offer: Wire.HandshakeOffer
        var boundAddress: UniqueNode {
            return self.state.selfNode
        }

        var protocolVersion: DistributedActors.Version {
            return self.state.settings.protocolVersion
        }

        let whenCompleted: EventLoopPromise<Wire.HandshakeResponse>?

        init(state: ReadOnlyClusterState, offer: Wire.HandshakeOffer, whenCompleted: EventLoopPromise<Wire.HandshakeResponse>?) {
            self.state = state
            self.offer = offer
            self.whenCompleted = whenCompleted
        }

        // do not call directly, rather obtain the completed state via negotiate()
        func _acceptAndMakeCompletedState() -> CompletedState {
            let completed = CompletedState(fromReceived: self, remoteNode: offer.from)
            self.whenCompleted?.succeed(.accept(completed.makeAccept()))
            return completed
        }

        func negotiate() -> HandshakeStateMachine.NegotiateDirective {
            guard self.boundAddress.node == self.offer.to else {
                let error = HandshakeError.targetHandshakeAddressMismatch(self.offer, selfNode: self.boundAddress)

                let rejectedState = RejectedState(fromReceived: self, remoteNode: self.offer.from, error: error)
                self.whenCompleted?.succeed(.reject(rejectedState.makeReject()))
                return .rejectHandshake(rejectedState)
            }

            // negotiate version
            if let negotiatedVersion = self.negotiateVersion(local: self.protocolVersion, remote: self.offer.version) {
                switch negotiatedVersion {
                case .rejectHandshake(let rejectedState):
                    self.whenCompleted?.succeed(.reject(rejectedState.makeReject()))
                    return negotiatedVersion
                case .acceptAndAssociate:
                    fatalError("Should not happen, only rejections or nothing should be yielded from negotiateVersion") // TODO: more typesafety would be nice
                }
            }

            // negotiate capabilities
            // self.negotiateCapabilities(...) // TODO: We may want to negotiate other options

            return .acceptAndAssociate(self._acceptAndMakeCompletedState())
        }

        // TODO: determine the actual logic we'd want here, for now we accept anything except major changes; use semver?
        /// - Returns `rejectHandshake` or `nil`
        func negotiateVersion(local: DistributedActors.Version, remote: DistributedActors.Version) -> HandshakeStateMachine.NegotiateDirective? {
            let accept: HandshakeStateMachine.NegotiateDirective? = nil

            guard local.major == remote.major else {
                let error = HandshakeError.incompatibleProtocolVersion(
                    local: self.protocolVersion, remote: self.offer.version
                )
                return .rejectHandshake(RejectedState(fromReceived: self, remoteNode: self.offer.from, error: error))
            }

            return accept
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handshake Completed

    /// State reached once we have received a `HandshakeAccepted` and are ready to create an association.
    /// This state is used to unlock creating an Association.
    internal struct CompletedState {
        let protocolVersion: Version
        var remoteNode: UniqueNode
        var localNode: UniqueNode
        let whenCompleted: EventLoopPromise<Wire.HandshakeResponse>?
        // let unique association ID?

        // State Transition used by Client Side of initial Handshake.
        //
        // Since the client is the one who initiates the handshake, once it receives an Accept containing the remote unique node
        // it may immediately transition to the completed state.
        init(fromInitiated state: InitiatedState, remoteNode: UniqueNode) {
            precondition(state.localNode != remoteNode, "Node [\(state.localNode)] attempted to create association with itself.")
            self.protocolVersion = state.protocolVersion
            self.remoteNode = remoteNode
            self.localNode = state.localNode
            self.whenCompleted = state.whenCompleted
        }

        // State Transition used by Server Side on accepting a received Handshake.
        init(fromReceived state: HandshakeReceivedState, remoteNode: UniqueNode) {
            precondition(state.boundAddress != remoteNode, "Node [\(state.boundAddress)] attempted to create association with itself.")
            self.protocolVersion = state.protocolVersion
            self.remoteNode = remoteNode
            self.localNode = state.boundAddress
            self.whenCompleted = state.whenCompleted
        }

        func makeAccept() -> Wire.HandshakeAccept {
            return .init(version: self.protocolVersion, from: self.localNode, origin: self.remoteNode)
        }
    }

    internal struct RejectedState {
        let protocolVersion: Version
        let localNode: Node
        let remoteNode: UniqueNode
        let error: HandshakeError

        init(fromReceived state: HandshakeReceivedState, remoteNode: UniqueNode, error: HandshakeError) {
            self.protocolVersion = state.protocolVersion
            self.localNode = state.boundAddress.node
            self.remoteNode = remoteNode
            self.error = error
        }

        func makeReject() -> Wire.HandshakeReject {
            return .init(version: self.protocolVersion, from: self.localNode, origin: self.remoteNode, reason: "\(self.error)")
        }
    }

    internal enum State {
        case initiated(InitiatedState)
        /// A handshake is already in-flight and was initiated by someone else previously.
        /// rather than creating another handshake dance, we will be notified along with the already initiated
        /// by someone else handshake completes.
        case inFlight(InFlightState)
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
    case acceptAttemptForNotInProgressHandshake(HandshakeStateMachine.CompletedState)

    /// The node at which the handshake arrived does not recognize the "to" node of the handshake.
    /// This may be a configuration issue (due to bind address and NAT mixups), or a routing issue
    /// where the handshake was received at "the wrong node".
    ///
    /// The UID part of the `Node` does not matter for this check, but is included here for debugging purposes.
    case targetHandshakeAddressMismatch(Wire.HandshakeOffer, selfNode: UniqueNode)

    /// Returned when an incoming handshake protocol version does not match what this node can understand.
    case incompatibleProtocolVersion(local: DistributedActors.Version, remote: DistributedActors.Version)
}
