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

import DistributedActorsConcurrencyHelpers
import Logging
import NIO

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Shell State

internal protocol ReadOnlyClusterState {
    var log: Logger { get }
    var allocator: ByteBufferAllocator { get }
    var eventLoopGroup: EventLoopGroup { get }

    /// Base backoff strategy to use in handshake retries // TODO: move it around somewhere so only handshake cares?
    var handshakeBackoff: BackoffStrategy { get }

    /// Unique address of the current node.
    var selfNode: UniqueNode { get }
    var selfMember: Cluster.Member { get }

    var settings: ClusterSettings { get }
}

/// State of the `ClusterShell` state machine.
internal struct ClusterShellState: ReadOnlyClusterState {
    typealias Messages = ClusterShell.Message

    // TODO: maybe move log and settings outside of state into the shell?
    var log: Logger
    let settings: ClusterSettings

    let events: EventStream<Cluster.Event>

    let channel: Channel

    let selfNode: UniqueNode
    var selfMember: Cluster.Member {
        if let member = self.membership.uniqueMember(self.selfNode) {
            return member
        } else {
            fatalError("""
            ClusterShellState.localMember was nil! This should be impossible by construction, because a node ALWAYS knows about itself. 
            Please report a bug on the distributed-actors issue tracker. Details:
            Membership: \(self.membership)
            Settings: \(self.settings)
            """)
        }
    }

    let eventLoopGroup: EventLoopGroup

    var handshakeBackoff: BackoffStrategy {
        self.settings.handshakeReconnectBackoff
    }

    let allocator: ByteBufferAllocator

    var _handshakes: [Node: HandshakeStateMachine.State] = [:]

    let gossiperControl: GossiperControl<Cluster.MembershipGossip, Cluster.MembershipGossip>

    /// Updating the `latestGossip` causes the gossiper to be informed about it, such that the next time it does a gossip round
    /// it uses the latest gossip available.
    var _latestGossip: Cluster.MembershipGossip

    /// Any change to the gossip data, is propagated to the gossiper immediately.
    var latestGossip: Cluster.MembershipGossip {
        get {
            self._latestGossip
        }
        set {
            if self._latestGossip.membership == newValue.membership {
                self._latestGossip = newValue
            } else {
                let next: Cluster.MembershipGossip
                if self._latestGossip.version == newValue.version {
                    next = newValue.incrementingOwnerVersion()
                } else {
                    next = newValue
                }

                self._latestGossip = next
            }
            self.gossiperControl.update(payload: self._latestGossip)
        }
    }

    var membership: Cluster.Membership {
        get {
            self.latestGossip.membership
        }
        set {
            self.latestGossip.membership = newValue
        }
    }

    init(
        settings: ClusterSettings,
        channel: Channel,
        events: EventStream<Cluster.Event>,
        gossiperControl: GossiperControl<Cluster.MembershipGossip, Cluster.MembershipGossip>,
        log: Logger
    ) {
        self.log = log
        self.settings = settings
        self.allocator = settings.allocator
        self.eventLoopGroup = settings.eventLoopGroup ?? settings.makeDefaultEventLoopGroup()

        self.selfNode = settings.uniqueBindNode
        self._latestGossip = Cluster.MembershipGossip(ownerNode: settings.uniqueBindNode)

        self.events = events
        self.gossiperControl = gossiperControl
        self.channel = channel
    }

    func handshakes() -> [HandshakeStateMachine.State] {
        self._handshakes.values.map { hsm -> HandshakeStateMachine.State in
            hsm
        }
    }
}

extension ClusterShellState {
    /// This is the entry point for a client initiating a handshake with a remote node.
    ///
    /// This MAY return `inFlight`, in which case it means someone already initiated a handshake with given node,
    /// and we should _do nothing_ and trust that our `whenCompleted` will be notified when the already in-flight handshake completes.
    mutating func initHandshake(with remoteNode: Node) -> HandshakeStateMachine.State {
        if let handshakeState = self.handshakeInProgress(with: remoteNode) {
            switch handshakeState {
            case .initiated:
                return .inFlight(HandshakeStateMachine.InFlightState(state: self))
            case .completed:
                return .inFlight(HandshakeStateMachine.InFlightState(state: self))
            case .wasOfferedHandshake:
                return .inFlight(HandshakeStateMachine.InFlightState(state: self))
            case .inFlight:
                fatalError("An inFlight may never be stored, yet seemingly was! Offending state: \(self) for node \(remoteNode)")
            }
        }

        let initiated = HandshakeStateMachine.InitiatedState(
            settings: self.settings,
            localNode: self.selfNode,
            connectTo: remoteNode
        )
        let handshakeState = HandshakeStateMachine.State.initiated(initiated)
        self._handshakes[remoteNode] = handshakeState
        return handshakeState
    }

    mutating func onHandshakeChannelConnected(initiated: HandshakeStateMachine.InitiatedState, channel: Channel) -> ClusterShellState {
        #if DEBUG
        let handshakeInProgress: HandshakeStateMachine.State? = self.handshakeInProgress(with: initiated.remoteNode)

        if case .some(.initiated(let existingInitiated)) = handshakeInProgress {
            if existingInitiated.remoteNode != initiated.remoteNode {
                fatalError(
                    """
                    onHandshakeChannelConnected MUST be called with the existing ongoing initiated \
                    handshake! Existing: \(existingInitiated), passed in: \(initiated).
                    """)
            }
            if existingInitiated.channel != nil {
                fatalError("onHandshakeChannelConnected should only be invoked once on an initiated state; yet seems the state already has a channel! Was: \(String(reflecting: handshakeInProgress))")
            }
        }
        #endif

        var initiated = initiated
        initiated.onConnectionEstablished(channel: channel)

        self._handshakes[initiated.remoteNode] = .initiated(initiated)
        return self
    }

    func handshakeInProgress(with node: Node) -> HandshakeStateMachine.State? {
        self._handshakes[node]
    }

    /// Abort a handshake, clearing any of its state as well as closing the passed in channel
    /// (which should be the one which the handshake to abort was made on).
    ///
    /// - Faults: when called in wrong state of an ongoing handshake
    /// - Returns: if present, the (now removed) handshake state that was aborted, hil otherwise.
    mutating func closeOutboundHandshakeChannel(with node: Node) -> HandshakeStateMachine.State? {
        guard let state = self._handshakes.removeValue(forKey: node) else {
            return nil
        }
        switch state {
        case .initiated(let initiated):
            if let channel = initiated.channel {
                self.log.trace("Aborting OUTBOUND handshake channel: \(channel)")

                channel.close().whenFailure { [log = self.log] error in
                    log.debug("Failed to abortOutgoingHandshake (close) channel [\(channel)], error: \(error)")
                }
            } // else, no channel to close?
        case .wasOfferedHandshake:
            fatalError("abortOutgoingHandshake was called in a context where the handshake was not an outgoing one! Was: \(state)")
        case .completed:
            fatalError("Attempted to abort an already completed handshake; Completed should never remain stored; Was: \(state)")
        case .inFlight:
            fatalError("Stored state was .inFlight, which should never be stored: \(state)")
        }

        return state
    }

    /// Abort an incoming handshake channel;
    /// As there may be a concurrent negotiation ongoing on another (outgoing) connection, we do NOT remove the handshake
    /// by node from the _handshakes.
    ///
    /// - Returns: if present, the (now removed) handshake state that was aborted, hil otherwise.
    mutating func closeHandshakeChannel(offer: Wire.HandshakeOffer, channel: Channel) {
        self.log.trace("Aborting INBOUND handshake channel: \(channel)")

        channel.close().whenFailure { [log = self.log, metadata = self.metadata] error in
            switch error {
            case ChannelError.alreadyClosed:
                // this is less severe and we should not warn about it; most often it's just a race of closes when we're racing both sides connecting.
                log.debug("Channel already closed [\(channel)], error: \(error)", metadata: metadata)
            default:
                log.warning("Failed to close channel [\(channel)], error: \(error)", metadata: metadata)
            }
        }
    }

    /// This is the entry point for a server receiving a handshake with a remote node.
    /// Inspects and possibly allocates a `HandshakeStateMachine` in the `HandshakeReceivedState` state.
    ///
    /// Scenarios:
    ///   L - local node
    ///   R - remote node
    ///
    ///   L initiates connection to R; R initiates connection to L;
    ///   Both nodes store an `initiated` state for the handshake; both will receive the others offer;
    ///   We need to perform a tie-break to see which one should actually "drive" this connecting: we pick the "lower node".
    ///
    ///   Upon tie-break the nodes follow these two roles:
    ///     Winner: Keeps the outgoing connection, negotiates and replies accept/reject on the "incoming" connection from the remote node.
    ///     Loser: Drops the incoming connection and waits for Winner's decision.
    mutating func onIncomingHandshakeOffer(offer: Wire.HandshakeOffer, existingAssociation: Association?, incomingChannel: Channel) -> OnIncomingHandshakeOfferDirective {
        func prepareNegotiation0() -> OnIncomingHandshakeOfferDirective {
            let fsm = HandshakeStateMachine.HandshakeOfferReceivedState(state: self, offer: offer)
            self._handshakes[offer.originNode.node] = .wasOfferedHandshake(fsm)
            return .negotiateIncoming(fsm)
        }

        if let assoc = existingAssociation {
            switch assoc.state {
            case .associating:
                () // continue, we'll perform the tie-breaker logic below
            case .associated:
                let error = HandshakeStateMachine.HandshakeConnectionError(
                    node: offer.originNode.node,
                    message: "Terminating this connection, the node [\(offer.originNode)] is already associated. Possibly a delayed handshake retry message was delivered?"
                )
                return .abortIncomingHandshake(error)
            case .tombstone:
                let error = HandshakeStateMachine.HandshakeConnectionError(
                    node: offer.originNode.node,
                    message: "Terminating this connection, the node [\(offer.originNode)] is already tombstone-ed. Possibly a delayed handshake retry message was delivered?"
                )
                return .abortIncomingHandshake(error)
            }
        }

        guard let inProgress = self._handshakes[offer.originNode.node] else {
            // no other concurrent handshakes in progress; good, this is happy path, so we simply continue our negotiation
            return prepareNegotiation0()
        }

        switch inProgress {
        case .initiated(let initiated):

            /// Since we MAY have 2 connections open at this point in time -- one we opened, and another that was opened
            /// to us when the other node tried to associated, we'll perform a tie-breaker to ensure we predictably
            /// only use _one_ of them, and close the other.
            // let selectedChannel: Channel

            /// order on nodes is somewhat arbitrary, but that is fine, since we only need this for tiebreakers
            let tieBreakWinner = initiated.localNode < offer.originNode
            self.log.debug("""
            Concurrently initiated handshakes from nodes [\(initiated.localNode)](local) and [\(offer.originNode)](remote) \
            detected! Resolving race by address ordering; This node \(tieBreakWinner ? "WON (will negotiate and reply)" : "LOST (will await reply)") tie-break. 
            """, metadata: [
                "handshake/inProgress": "\(initiated)",
                "handshake/incoming/offer": "\(offer)",
                "handshake/incoming/channel": "\(incomingChannel)",
            ])

            if tieBreakWinner {
                if self.closeOutboundHandshakeChannel(with: offer.originNode.node) != nil {
                    self.log.debug(
                        "Aborted handshake, as concurrently negotiating another one with same node already",
                        metadata: [
                            "handshake/status": "abort-incoming,offer",
                            "handshake/from": "\(offer.originNode)",
                        ]
                    )
                }

                return prepareNegotiation0()

            } else {
                // we "lost", the other node will send the accept; when it does, the will complete the future.
                // concurrent handshake and we should abort
                let error = HandshakeStateMachine.HandshakeConnectionError(
                    node: offer.originNode.node,
                    message: """
                    Terminating this connection, as there is a concurrently established connection with same host [\(offer.originNode)] \
                    which will be used to complete the handshake.
                    """
                )
                return .abortIncomingHandshake(error)
            }
        case .wasOfferedHandshake:
            // suspicious but but not wrong, so we were offered before, and now are being offered again?
            // Situations:
            // - it could be that the remote re-sent their offer before it received our accept?
            // - maybe remote did not receive our accept/reject and is trying again?
            return prepareNegotiation0()

        // --- these are never stored ----
        case .inFlight(let inFlight):
            fatalError("inFlight state [\(inFlight)] should never have been stored as handshake state; This is likely a bug, please open an issue.")
        case .completed(let completed):
            fatalError("completed state [\(completed)] should never have been stored as handshake state; This is likely a bug, please open an issue.")
        }
    }

    enum OnIncomingHandshakeOfferDirective {
        case negotiateIncoming(HandshakeStateMachine.HandshakeOfferReceivedState)
        /// An existing handshake with given peer is already in progress,
        /// do not negotiate but rest assured that the association will be handled properly by the already ongoing process.
        case abortIncomingHandshake(HandshakeStateMachine.HandshakeConnectionError)
    }

    mutating func incomingHandshakeAccept(_ accept: Wire.HandshakeAccept) -> HandshakeStateMachine.CompletedState? {
        guard let inProgressHandshake = self._handshakes[accept.targetNode.node] else {
            self.log.warning("Attempted to accept incoming [\(accept)] for handshake which was not in progress!", metadata: [
                "clusterShell": "\(self)",
                "membership": "\(self.membership)",
            ])
            return nil
        }

        switch inProgressHandshake {
        case .initiated(let hsm):
            let completed = HandshakeStateMachine.CompletedState(fromInitiated: hsm, remoteNode: accept.targetNode)
            return completed
        case .wasOfferedHandshake:
            // TODO: model the states to express this can not happen // there is a client side state machine and a server side one
            self.log.warning("Received accept but state machine is in WAS OFFERED state. This should be impossible.")
            return nil
        case .completed:
            // TODO: validate if it is for the same UID or not, if not, we may be in trouble?
            self.log.warning("Received handshake Accept for already completed handshake. This should not happen.")
            return nil
        case .inFlight:
            fatalError("An in-flight marker state should never be stored, yet was encountered in \(#function)")
        }
    }

    /// "Upgrades" a connection with a remote node from handshaking state to associated.
    /// Stores an `Association` for the newly established association;
    ///
    /// Does NOT by itself move the member to joining, but via the directive asks the outer to do this.
    mutating func completeHandshakeAssociate(
        _ clusterShell: ClusterShell, _ handshake: HandshakeStateMachine.CompletedState, channel: Channel,
        file: String = #file, line: UInt = #line
    ) -> AssociatedDirective {
        guard self._handshakes.removeValue(forKey: handshake.remoteNode.node) != nil else {
            fatalError("Can not complete a handshake which was not in progress!")
            // TODO: perhaps we instead just warn and ignore this; since it should be harmless
        }

        let change: Cluster.MembershipChange?
        if let replacedMember = self.membership.member(handshake.remoteNode.node) {
            change = self.membership.applyMembershipChange(Cluster.MembershipChange(replaced: replacedMember, by: Cluster.Member(node: handshake.remoteNode, status: .joining)))
        } else {
            change = self.membership.applyMembershipChange(Cluster.MembershipChange(member: Cluster.Member(node: handshake.remoteNode, status: .joining)))
        }

        return AssociatedDirective(
            membershipChange: change,
            handshake: handshake,
            channel: channel
        )
    }

    struct AssociatedDirective {
        let membershipChange: Cluster.MembershipChange?
//        let membershipChange: Cluster.MembershipChange
        let handshake: HandshakeStateMachine.CompletedState
        let channel: Channel
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster.Membership

extension ClusterShellState {
    /// Generates and applies changes; generating actions to be taken by the `ClusterShell` if and only if it is the Leader,
    /// after this change has been applied.
    mutating func applyClusterEvent(_ event: Cluster.Event) -> AppliedClusterEventDirective {
        var changeWasApplied: Bool

        switch event {
        case .leadershipChange(let change):
            do {
                if let appliedChange = try self.membership.applyLeadershipChange(to: change.newLeader) {
                    self.log.debug("Leader change: \(appliedChange)", metadata: self.metadata)
                    changeWasApplied = true
                } else {
                    changeWasApplied = false
                }
            } catch {
                self.log.warning("Unable to apply leadership change: \(change), error: \(error)", metadata: self.metadata)
                changeWasApplied = false
            }
        case .membershipChange(let change):
            if let appliedChange = self.membership.applyMembershipChange(change) {
                self.log.trace("Applied change via cluster event: \(appliedChange)", metadata: self.metadata)
                changeWasApplied = true
            } else {
                changeWasApplied = false
            }
        case .reachabilityChange(let change):
            if self.membership.applyReachabilityChange(change) != nil {
                self.log.trace("Applied reachability change: \(change)", metadata: self.metadata)
                changeWasApplied = true
            } else {
                changeWasApplied = false
            }
        case .snapshot(let snapshot):
            /// Realistically we are a SOURCE of snapshots, not a destination of them, however for completeness let's implement it:
            changeWasApplied = false
            for change in Cluster.Membership._diff(from: .empty, to: snapshot).changes {
                let directive = self.applyClusterEvent(.membershipChange(change))
                changeWasApplied = changeWasApplied || directive.applied
                // actions we'll calculate below, once
            }
        }

        guard changeWasApplied else {
            return .init(applied: changeWasApplied)
        }

        self.log.trace("Membership updated on [\(self.selfNode)] by \(event): \(pretty: self.membership)")
        return .init(applied: changeWasApplied)
    }

    struct AppliedClusterEventDirective {
        // True if the change was applied, modifying the Membership.
        let applied: Bool
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ClusterShellState + Logging

extension ClusterShellState {
    var metadata: Logger.Metadata {
        [
            "membership/count": "\(String(describing: self.membership.count(atLeast: .joining)))",
        ]
    }

    func metadataForHandshakes(node: Node? = nil, uniqueNode: UniqueNode? = nil, error err: Error?) -> Logger.Metadata {
        var metadata: Logger.Metadata =
            [
                "handshakes": "\(self.handshakes())",
            ]

        if let n = node {
            metadata["handshake/peer"] = "\(n)"
        }
        if let n = uniqueNode {
            metadata["handshake/peer"] = "\(n)"
        }
        if let error = err {
            metadata["handshake/error"] = "\(error)"
            metadata["handshake/errorType"] = "\(String(reflecting: type(of: error as Any)))"
        }

        return metadata
    }
}
