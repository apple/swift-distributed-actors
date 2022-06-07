//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
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
public let DistributedActorsProtocolVersion: ClusterSystem.Version = .init(reserved: 0, major: 1, minor: 0, patch: 0)

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

    internal struct InitiatedState: Swift.CustomStringConvertible {
        let settings: ClusterSystemSettings

        var protocolVersion: ClusterSystem.Version {
            self.settings.protocolVersion
        }

        let remoteNode: Node
        let localNode: UniqueNode

        var handshakeReconnectBackoff: BackoffStrategy

        /// Channel which was established when we initiated the handshake (outgoing connection),
        /// which may want to be closed when we `abortHandshake` and want to kill the related outgoing connection as we do so.
        ///
        /// This is ALWAYS set once the initial clientBootstrap has completed.
        var channel: Channel?

        init(
            settings: ClusterSystemSettings, localNode: UniqueNode, connectTo remoteNode: Node
        ) {
            precondition(localNode.node != remoteNode, "MUST NOT attempt connecting to own bind address. Address: \(remoteNode)")
            self.settings = settings
            self.localNode = localNode
            self.remoteNode = remoteNode
            self.handshakeReconnectBackoff = settings.handshakeReconnectBackoff // copy since we want to mutate it as the handshakes attempt retries
        }

        func makeOffer() -> Wire.HandshakeOffer {
            // TODO: maybe store also at what time we sent the handshake, so we can diagnose if we should reject replies for being late etc
            Wire.HandshakeOffer(version: self.protocolVersion, originNode: self.localNode, targetNode: self.remoteNode)
        }

        mutating func onConnectionEstablished(channel: Channel) {
            self.channel = channel
        }

        // TODO: call into an connection error?
        // TODO: the remote REJECTING must not trigger backoffs
        mutating func onHandshakeTimeout() -> RetryDirective {
            self.onConnectionError(HandshakeConnectionError(node: self.remoteNode, message: "Handshake timed out")) // TODO: improve msgs
        }

        mutating func onConnectionError(_: Error) -> RetryDirective {
            if let nextConnectionAttemptDelay = self.handshakeReconnectBackoff.next() {
                return .scheduleRetryHandshake(delay: nextConnectionAttemptDelay)
            } else {
                return .giveUpOnHandshake
            }
        }

        var description: Swift.String {
            """
            InitiatedState(\
            remoteNode: \(self.remoteNode), \
            localNode: \(self.localNode), \
            channel: \(optional: self.channel)\
            )
            """
        }
    }

    struct HandshakeConnectionError: Error, Equatable {
        let node: Node // TODO: allow carrying UniqueNode
        let message: String
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handshake In-Flight, and should attach to existing negotiation

    internal struct InFlightState {
        private let state: ReadOnlyClusterState

        init(state: ReadOnlyClusterState) {
            self.state = state
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handshake Received

    /// Initial state for server side of handshake.
    internal struct HandshakeOfferReceivedState {
        private let state: ReadOnlyClusterState

        let offer: Wire.HandshakeOffer
        var boundAddress: UniqueNode {
            self.state.selfNode
        }

        var protocolVersion: ClusterSystem.Version {
            self.state.settings.protocolVersion
        }

        init(state: ReadOnlyClusterState, offer: Wire.HandshakeOffer) {
            self.state = state
            self.offer = offer
        }

        func negotiate() -> HandshakeStateMachine.NegotiateDirective {
            guard self.boundAddress.node == self.offer.targetNode else {
                let error = HandshakeError.targetHandshakeAddressMismatch(self.offer, selfNode: self.boundAddress)

                let rejectedState = RejectedState(fromReceived: self, remoteNode: self.offer.originNode, error: error)
//                self.whenCompleted.succeed(.reject(rejectedState.makeReject(whenHandshakeReplySent: { () in
//                    self.state.log.trace("Done rejecting handshake.") // TODO: something more, terminate the association?
//                })))
                return .rejectHandshake(rejectedState)
            }

            // negotiate version
            if let rejectedState = self.negotiateVersion(local: self.protocolVersion, remote: self.offer.version) {
//                self.whenCompleted.succeed(.reject(rejectedState.makeReject(whenHandshakeReplySent: { () in
//                    self.state.log.trace("Done rejecting handshake.") // TODO: something more, terminate the association?
//                })))
                return .rejectHandshake(rejectedState)
            }

            // negotiate capabilities
            // self.negotiateCapabilities(...) // TODO: We may want to negotiate other options

            let completed = CompletedState(fromReceived: self, remoteNode: offer.originNode)
            return .acceptAndAssociate(completed)
        }

        func negotiateVersion(local: ClusterSystem.Version, remote: ClusterSystem.Version) -> RejectedState? {
            guard local.major == remote.major else {
                let error = HandshakeError.incompatibleProtocolVersion(
                    local: self.protocolVersion, remote: self.offer.version
                )
                return RejectedState(fromReceived: self, remoteNode: self.offer.originNode, error: error)
            }

            return nil
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handshake Completed

    /// State reached once we have received a `HandshakeAccepted` and are ready to create an association.
    /// This state is used to unlock creating a completed Association.
    internal struct CompletedState {
        let protocolVersion: ClusterSystem.Version
        var remoteNode: UniqueNode
        var localNode: UniqueNode
//        let whenCompleted: EventLoopPromise<Wire.HandshakeResponse>
        // let unique association ID?

        // State Transition used by Client Side of initial Handshake.
        //
        // Since the client is the one who initiates the handshake, once it receives an Accept containing the remote unique node
        // it may immediately transition to the completed state.
        init(fromInitiated initiated: InitiatedState, remoteNode: UniqueNode) {
            precondition(initiated.localNode != remoteNode, "Node [\(initiated.localNode)] attempted to create association with itself.")
            self.protocolVersion = initiated.protocolVersion
            self.remoteNode = remoteNode
            self.localNode = initiated.localNode
//            self.whenCompleted = initiated.whenCompleted
        }

        // State Transition used by Server Side on accepting a received Handshake.
        init(fromReceived received: HandshakeOfferReceivedState, remoteNode: UniqueNode) {
            precondition(received.boundAddress != remoteNode, "Node [\(received.boundAddress)] attempted to create association with itself.")
            self.protocolVersion = received.protocolVersion
            self.remoteNode = remoteNode
            self.localNode = received.boundAddress
//            self.whenCompleted = received.whenCompleted
        }

        func makeAccept(whenHandshakeReplySent: (() -> Void)?) -> Wire.HandshakeAccept {
            Wire.HandshakeAccept(
                version: self.protocolVersion,
                targetNode: self.localNode,
                originNode: self.remoteNode,
                whenHandshakeReplySent: whenHandshakeReplySent
            )
        }
    }

    internal struct RejectedState {
        let protocolVersion: ClusterSystem.Version
        let localNode: UniqueNode
        let remoteNode: UniqueNode
        let error: HandshakeError

        init(fromReceived state: HandshakeOfferReceivedState, remoteNode: UniqueNode, error: HandshakeError) {
            self.protocolVersion = state.protocolVersion
            self.localNode = state.boundAddress
            self.remoteNode = remoteNode
            self.error = error
        }

        func makeReject(whenHandshakeReplySent: @escaping () -> Void) -> Wire.HandshakeReject {
            Wire.HandshakeReject(
                version: self.protocolVersion,
                targetNode: self.localNode,
                originNode: self.remoteNode,
                reason: "\(self.error)",
                whenHandshakeReplySent: whenHandshakeReplySent
            )
        }
    }

    internal enum State {
        /// Stored the moment a handshake is initiated; may not yet have an underlying connection yet.
        case initiated(InitiatedState)
        /// A handshake is already in-flight and was initiated by someone else previously.
        /// rather than creating another handshake dance, we will be notified along with the already initiated
        /// by someone else handshake completes.
        case inFlight(InFlightState)
        case wasOfferedHandshake(HandshakeOfferReceivedState)
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
    case incompatibleProtocolVersion(local: ClusterSystem.Version, remote: ClusterSystem.Version)

    case targetRejectedHandshake(selfNode: UniqueNode, remoteNode: UniqueNode, message: String)

    case targetAlreadyTombstone(selfNode: UniqueNode, remoteNode: UniqueNode)
}
