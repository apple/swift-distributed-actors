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

// TODO: we hopefully will rather than this, end up with specialized protocols depending on what we need to expose,
// and then types may require those specific capabilities from the shell; e.g. scheduling things or similar.
internal protocol ReadOnlyClusterState {
    var log: Logger { get }
    var allocator: ByteBufferAllocator { get }
    var eventLoopGroup: EventLoopGroup { get } // TODO: or expose the MultiThreaded one...?

    /// Base backoff strategy to use in handshake retries // TODO: move it around somewhere so only handshake cares?
    var handshakeBackoff: BackoffStrategy { get }

    /// Unique address of the current node.
    var myselfNode: UniqueNode { get }
    var settings: ClusterSettings { get }
}

/// State of the `ClusterShell` state machine.
internal struct ClusterShellState: ReadOnlyClusterState {
    typealias Messages = ClusterShell.Message

    // TODO: maybe move log and settings outside of state into the shell?
    var log: Logger
    let settings: ClusterSettings

    let events: EventStream<Cluster.Event>

    let myselfNode: UniqueNode
    let channel: Channel

    let eventLoopGroup: EventLoopGroup

    var handshakeBackoff: BackoffStrategy {
        self.settings.associationHandshakeBackoff
    }

    let allocator: ByteBufferAllocator

    internal var _handshakes: [Node: HandshakeStateMachine.State] = [:]

    let gossipControl: ConvergentGossipControl<Cluster.Gossip>

    /// Updating the `latestGossip` causes the gossiper to be informed about it, such that the next time it does a gossip round
    /// it uses the latest gossip available.
    var _latestGossip: Cluster.Gossip

    /// Any change to the gossip data, is propagated to the gossiper immediately.
    var latestGossip: Cluster.Gossip {
        get {
            self._latestGossip
        }
        set {
            if self._latestGossip.membership == newValue.membership {
                self._latestGossip = newValue
            } else {
                let next: Cluster.Gossip
                if self._latestGossip.version == newValue.version {
                    next = newValue.incrementingOwnerVersion()
                } else {
                    next = newValue
                }

                self._latestGossip = next
            }
            self.gossipControl.update(payload: self._latestGossip)
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

    init(settings: ClusterSettings, channel: Channel, events: EventStream<Cluster.Event>, gossipControl: ConvergentGossipControl<Cluster.Gossip>, log: Logger) {
        self.log = log
        self.settings = settings
        self.allocator = settings.allocator
        self.eventLoopGroup = settings.eventLoopGroup ?? settings.makeDefaultEventLoopGroup()

        self.myselfNode = settings.uniqueBindNode
        self._latestGossip = Cluster.Gossip(ownerNode: settings.uniqueBindNode)

        self.events = events
        self.gossipControl = gossipControl
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
    mutating func registerHandshake(with remoteNode: Node, whenCompleted: EventLoopPromise<Wire.HandshakeResponse>) -> HandshakeStateMachine.State {
        if let handshakeState = self.handshakeInProgress(with: remoteNode) {
            switch handshakeState {
            case .initiated(let state):
                state.whenCompleted?.futureResult.cascade(to: whenCompleted)
            case .completed(let state):
                state.whenCompleted?.futureResult.cascade(to: whenCompleted)
            case .wasOfferedHandshake(let state):
                state.whenCompleted?.futureResult.cascade(to: whenCompleted)
            case .inFlight:
                fatalError("An inFlight may never be stored, yet seemingly was! Offending state: \(self) for node \(remoteNode)")
            }

            return .inFlight(HandshakeStateMachine.InFlightState(state: self, whenCompleted: whenCompleted))
        }

        let initiated = HandshakeStateMachine.InitiatedState(
            settings: self.settings,
            localNode: self.myselfNode,
            connectTo: remoteNode,
            whenCompleted: whenCompleted
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
                fatalError("""
                onHandshakeChannelConnected MUST be called with the existing ongoing initiated
                handshake! Existing: \(existingInitiated), passed in: \(initiated).
                """)
            }
            if existingInitiated.channel != nil {
                fatalError("onHandshakeChannelConnected should only be invoked once on an initiated state; yet seems the state already has a channel! Was: \(String(reflecting: handshakeInProgress))")
            }
        }
        #endif

        var initiated = initiated
        initiated.onChannelConnected(channel: channel)

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
    mutating func abortOutgoingHandshake(with node: Node) -> HandshakeStateMachine.State? {
        guard let state = self._handshakes.removeValue(forKey: node) else {
            return nil
        }

        switch state {
        case .initiated(let initiated):
            if let channel = initiated.channel {
                channel.close().whenFailure { [log = self.log] error in
                    log.warning("Failed to abortOutgoingHandshake (close) channel [\(channel)], error: \(error)")
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
    mutating func abortIncomingHandshake(offer: Wire.HandshakeOffer, channel: Channel) {
        channel.close().whenFailure { [log = self.log, metadata = self.metadata] error in
            log.warning("Failed to abortIncomingHandshake (close) channel [\(channel)], error: \(error)", metadata: metadata)
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
    mutating func onIncomingHandshakeOffer(offer: Wire.HandshakeOffer) -> OnIncomingHandshakeOfferDirective {
        func negotiate(promise: EventLoopPromise<Wire.HandshakeResponse>? = nil) -> OnIncomingHandshakeOfferDirective {
            let promise = promise ?? self.eventLoopGroup.next().makePromise(of: Wire.HandshakeResponse.self)
            let fsm = HandshakeStateMachine.HandshakeReceivedState(state: self, offer: offer, whenCompleted: promise)
            self._handshakes[offer.from.node] = .wasOfferedHandshake(fsm)
            return .negotiate(fsm)
        }

        guard let inProgress = self._handshakes[offer.from.node] else {
            // no other concurrent handshakes in progress; good, this is happy path, so we simply continue our negotiation
            return negotiate()
        }

        switch inProgress {
        case .initiated(let initiated):
            /// order on nodes is somewhat arbitrary, but that is fine, since we only need this for tiebreakers
            let tieBreakWinner = initiated.localNode < offer.from
            self.log.info("""
            Concurrently initiated handshakes from nodes [\(initiated.localNode)](local) and [\(offer.from)](remote) \
            detected! Resolving race by address ordering; This node \(tieBreakWinner ? "WON (will negotiate and reply)" : "LOST (will await reply)") tie-break. 
            """)
            if tieBreakWinner {
                if self.abortOutgoingHandshake(with: offer.from.node) != nil {
                    self.log.debug(
                        "Aborted handshake, as concurrently negotiating another one with same node already",
                        metadata: [
                            "handshake/status": "abort-incoming,offer",
                            "handshake/from": "\(offer.from)",
                        ]
                    )
                }

                self.log.debug("Proceed to negotiate handshake offer.")
                return negotiate(promise: initiated.whenCompleted)

            } else {
                // we "lost", the other node will send the accept; when it does, the will complete the future.
                return .abortDueToConcurrentHandshake
            }
        case .wasOfferedHandshake:
            // suspicious but but not wrong, so we were offered before, and now are being offered again?
            // Situations:
            // - it could be that the remote re-sent their offer before it received our accept?
            // - maybe remote did not receive our accept/reject and is trying again?
            return negotiate()

        // --- these are never stored ----
        case .inFlight(let inFlight):
            fatalError("inFlight state [\(inFlight)] should never have been stored as handshake state; This is likely a bug, please open an issue.")
        case .completed(let completed):
            fatalError("completed state [\(completed)] should never have been stored as handshake state; This is likely a bug, please open an issue.")
        }
    }

    enum OnIncomingHandshakeOfferDirective {
        case negotiate(HandshakeStateMachine.HandshakeReceivedState)
        /// An existing handshake with given peer is already in progress,
        /// do not negotiate but rest assured that the association will be handled properly by the already ongoing process.
        case abortDueToConcurrentHandshake
    }

    mutating func incomingHandshakeAccept(_ accept: Wire.HandshakeAccept) -> HandshakeStateMachine.CompletedState? {
        guard let inProgressHandshake = self._handshakes[accept.from.node] else {
            // TODO: what if node that sent handshake, has already terminated -- would we have removed the in progress handshake already causing this?
            // fatalError("Accept incoming [\(accept)] for handshake which was not in progress! On node: \(self.myselfNode), cluster shell state: \(self), membership: \(self.membership)") // TODO: model differently
            return nil
        }

        switch inProgressHandshake {
        case .initiated(let hsm):
            let completed = HandshakeStateMachine.CompletedState(fromInitiated: hsm, remoteNode: accept.from)
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
    mutating func associate(_ system: ActorSystem, _ handshake: HandshakeStateMachine.CompletedState, channel: Channel) -> AssociatedDirective {
        guard self._handshakes.removeValue(forKey: handshake.remoteNode.node) != nil else {
            fatalError("Can not complete a handshake which was not in progress!")
            // TODO: perhaps we instead just warn and ignore this; since it should be harmless
        }

        // Membership may not know about the remote node yet, i.e. it reached out directly to this node;
        // In that case, the join will return a change; Though if the node is already known, e.g. we were told about it
        // via gossip from other nodes, though didn't yet complete associating until just now, so we can make a `change`
        // based on the stored member
        let changeOption: Cluster.MembershipChange? = self.membership.applyMembershipChange(.init(member: .init(node: handshake.remoteNode, status: .joining))) ??
            self.membership.uniqueMember(handshake.remoteNode).map { Cluster.MembershipChange(member: $0) }

        guard let change = changeOption else {
            fatalError("""
            Attempt to associate with \(reflecting: handshake.remoteNode) failed; It was neither a new node .joining, \
            nor was it a node that we already know. This should never happen as one of those two cases is always true. \
            Please report a bug.
            """)
        }

        return AssociatedDirective(membershipChange: change, handshake: handshake, channel: channel)
    }

    struct AssociatedDirective {
        let membershipChange: Cluster.MembershipChange
        // let association: Association.AssociationState
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
                    self.log.info("Leader change: \(appliedChange)", metadata: self.metadata)
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
            return .init(applied: changeWasApplied, leaderActions: [])
        }

        // will be empty if myself node is NOT a leader
        let leaderActions = self.collectLeaderActions()
        // TODO: actions may want to be acted upon, they're like directives, we currently have no such need though;
        // such actions be e.g. "kill association right away" or "asap tell that node .down" directly without waiting for gossip etc

        self.log.trace("Membership updated \(self.membership.prettyDescription(label: "\(self.myselfNode)")),\n  by \(event)")
        return .init(applied: changeWasApplied, leaderActions: leaderActions)
    }

    struct AppliedClusterEventDirective {
        // True if the change was applied, modifying the Membership.
        let applied: Bool
        // will be empty if myself node is NOT a Leader
        let leaderActions: [LeaderAction]
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
}
