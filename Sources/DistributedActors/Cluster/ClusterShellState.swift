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
    var backoffStrategy: BackoffStrategy { get }

    /// Unique address of the current node.
    var selfNode: UniqueNode { get }
    var settings: ClusterSettings { get }
}

/// State of the `ClusterShell` state machine.
internal struct ClusterShellState: ReadOnlyClusterState {
    typealias Messages = ClusterShell.Message

    // TODO: maybe move log and settings outside of state into the shell?
    var log: Logger
    let settings: ClusterSettings

    let events: EventStream<ClusterEvent>

    let selfNode: UniqueNode
    let channel: Channel

    // TODO: replace with gossip
    let gossip: PeriodicBroadcastControl<ClusterShell.Message>

    let eventLoopGroup: EventLoopGroup

    var backoffStrategy: BackoffStrategy {
        return self.settings.handshakeBackoffStrategy
    }

    let allocator: ByteBufferAllocator

    internal var _handshakes: [Node: HandshakeStateMachine.State] = [:]
    private var _associations: [Node: Association.State] = [:]

    var membership: Membership

    init(settings: ClusterSettings, channel: Channel, events: EventStream<ClusterEvent>, gossip: PeriodicBroadcastControl<ClusterShell.Message>, log: Logger) {
        self.log = log
        self.settings = settings
        self.allocator = settings.allocator
        self.eventLoopGroup = settings.eventLoopGroup ?? settings.makeDefaultEventLoopGroup()

        self.selfNode = settings.uniqueBindNode
        self.membership = .empty

        self.events = events
        self.gossip = gossip
        self.channel = channel
    }

    func association(with node: Node) -> Association.State? {
        return self._associations[node]
    }

    func associatedNodes() -> Set<UniqueNode> {
        var set: Set<UniqueNode> = .init(minimumCapacity: self._associations.count)

        for asm in self._associations.values {
            switch asm {
            case .associated(let state): set.insert(state.remoteNode)
            }
        }

        return set
    }

    func handshakes() -> [HandshakeStateMachine.State] {
        return self._handshakes.values.map { hsm -> HandshakeStateMachine.State in
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

        if let existingAssociation = self.association(with: remoteNode) {
            fatalError("Beginning new handshake to [\(reflecting: remoteNode)], with already existing association: \(existingAssociation). Could this be a bug?")
        }

        let initiated = HandshakeStateMachine.InitiatedState(
            settings: self.settings,
            localNode: self.selfNode,
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
        return self._handshakes[node]
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
            _ = initiated.channel?.close()
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
        _ = channel.close()
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
            self.log.warning("""
            Concurrently initiated handshakes from nodes [\(initiated.localNode)](local) and [\(offer.from)](remote) \
            detected! Resolving race by address ordering; This node \(tieBreakWinner ? "WON (will negotiate and reply)" : "LOST (will await reply)") tie-break. 
            """)
            if tieBreakWinner {
                if let abortedHandshake = self.abortOutgoingHandshake(with: offer.from.node) {
                    self.log.info("Aborted handshake, as concurrently negotiating another one with same node already; Aborted handshake: \(abortedHandshake)")
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

    mutating func incomingHandshakeAccept(_ accept: Wire.HandshakeAccept) -> HandshakeStateMachine.CompletedState? { // TODO: return directives to act on
        if let inProgressHandshake = self._handshakes[accept.from.node] {
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
        } else {
            fatalError("Accept incoming for handshake which was not in progress!") // TODO: model differently
        }
    }

    /// "Upgrades" a connection with a remote node from handshaking state to associated.
    /// Stores an `Association` for the newly established association;
    ///
    /// Does NOT by itself move the member to joining, but via the directive asks the outer to do this.
    mutating func associate(_ handshake: HandshakeStateMachine.CompletedState, channel: Channel) -> AssociatedDirective {
        guard self._handshakes.removeValue(forKey: handshake.remoteNode.node) != nil else {
            fatalError("Can not complete a handshake which was not in progress!")
            // TODO: perhaps we instead just warn and ignore this; since it should be harmless
        }

        // Membership may not know about the remote node yet, i.e. it reached out directly to this node;
        // In that case, the join will return a change; Though if the node is already known, e.g. we were told about it
        // via gossip from other nodes, though didn't yet complete associating until just now, so we can make a `change`
        // based on the stored member
        let changeOption: MembershipChange? = self.membership.apply(.init(member: .init(node: handshake.remoteNode, status: .joining))) ??
            self.membership.uniqueMember(handshake.remoteNode).map { MembershipChange(member: $0) }
        guard let change = changeOption else {
            fatalError("""
            Attempt to associate with \(reflecting: handshake.remoteNode) failed; It was neither a new node .joining, \
            nor was it a node that we already know. This should never happen as one of those two cases is always true. \
            Please report a bug.
            """)
        }

        // Note: The following replace handling has to be done here - before we complete the association(!)
        //       As otherwise querying the associations by node would return the new one, leaving the old "replaced one" hanging (and channel not-closed).
        //
        // If the change is a replacement of a previously associated note, i.e. the remote node died, we didn't notice yet,
        // but a new instance was started on the same host:port and now has reached out to us to associate. We need to eject
        // the previous "replaced" node, and mark it as down, while at the same time accepting the association from the new node.
        let beingReplacedAssociationToTerminate: Association.AssociatedState?
        if let replacedMember = change.replaced {
            switch self._associations.removeValue(forKey: replacedMember.node.node) {
            case .some(.associated(let beingReplacedAssociation)):
                self.log.warning("Node \(reflecting: handshake.remoteNode) joining OVER existing associated node \(reflecting: beingReplacedAssociation.remoteNode) as its replacement. Severing ties with previous incarnation of node.")
                // we are fairly certain the old node is dead now, since the new node is taking its place and has same address,
                // thus the channel is most likely pointing to an "already-dead" connection; we close it to cut off clean.

                beingReplacedAssociationToTerminate = beingReplacedAssociation
                self.events.publish(.membershipChange(.init(member: replacedMember, toStatus: .down)))

            default:
                self.log.warning("Membership change indicated node replacement, yet no 'old' association to replace found. Continuing with association of \(reflecting: handshake.remoteNode)")
                beingReplacedAssociationToTerminate = nil
            }
        } else {
            // this is not a replacement operation, no pre-existing association to terminate
            beingReplacedAssociationToTerminate = nil
        }

        self.events.publish(.membershipChange(change))

        // Usual happy-path for an association; We associated a new node.
        let association = Association.AssociatedState(fromCompleted: handshake, log: self.log, over: channel)
        self._associations[handshake.remoteNode.node] = .associated(association)

        return AssociatedDirective(membershipChange: change, association: association, beingReplacedAssociationToTerminate: beingReplacedAssociationToTerminate)
    }

    struct AssociatedDirective {
        let membershipChange: MembershipChange
        let association: Association.AssociatedState

        /// An association was replaced by the `membershipChange` and this "old" association must be closed, pruned from caches, and tombstoned.
        let beingReplacedAssociationToTerminate: Association.AssociatedState?
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Membership

extension ClusterShellState {
    /// - Returns: `true` if the change actually caused an effective change, `false` otherwise.
    mutating func applyClusterMembershipChange(_ event: ClusterEvent) -> Bool {
        let changeWasApplied: Bool
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
            if let appliedChange = self.membership.apply(change) {
                self.log.trace("Applied change via cluster event: \(appliedChange)", metadata: self.metadata)
                changeWasApplied = true
            } else {
                changeWasApplied = false
            }
        case .reachabilityChange(let change):
            if self.applyMemberReachabilityChange(change) != nil {
                self.log.trace("Applied reachability change: \(change)", metadata: self.metadata)
                changeWasApplied = true
            } else {
                changeWasApplied = false
            }
        case .snapshot:
            // TODO: not handling snapshot here, we are a source of snapshots... yet what about gossip vs. "push membership", we may want ot handle here, by diff+apply
            self.log.info("SNAPSHOT NOT APPLIED, NOT IMPLEMENTED; \(event)")
            changeWasApplied = false
        }

        guard changeWasApplied else {
            self.log.info("NOT APPLIED \(event)")
            return false
        }

        _ = self.tryPerformLeaderTasks()
        // TODO: actions may want to be acted upon, they're like directives, we currently have no such need though;
        // such actions be e.g. "kill association right away" or "asap tell that node .down" directly without waiting for gossip etc

        self.log.trace("Membership updated \(self.membership.prettyDescription(label: "\(self.selfNode)")), by \(event)")
        return true
    }

    /// - Returns: the `MembershipChange` that was the result of moving the member identified by the `node` to the `toStatus`,
    ///    or `nil` if no (observable) change resulted from this move (e.g. marking a `.dead` node as `.dead` again, is not a "change").
    mutating func applyMembershipChange(_ node: UniqueNode, toStatus: MemberStatus) -> MembershipChange? {
        return self.membership.apply(MembershipChange(member: Member(node: node, status: toStatus)))
    }

    /// - Returns: the changed member if the change was a transition (unreachable -> reachable, or back),
    ///            or `nil` if the reachability is the same as already known by the membership.
    mutating func applyMemberReachabilityChange(_ change: ReachabilityChange) -> Member? {
        return self.membership.applyReachabilityChange(change)
    }

    /// If, and only if, the current node is a leader it performs a set of tasks, such as moving nodes to `.up` etc.
    mutating func tryPerformLeaderTasks() -> [LeaderAction] {
        guard self.membership.isLeader(self.selfNode) else {
            return []
        }

        var leadershipActions: [LeaderAction] = []

        func moveMembersUp() {
            let joiningMembers = self.membership.members(withStatus: .joining, reachability: .reachable)

            // TODO; do we really need seen tables here? Need to look at some more cases when "move to up" would be a potentially wrong decision... when really?
            // TODO: can a seen table be a number of "every they at least know about membership in version X" -- TODO causality checking...
            guard !joiningMembers.isEmpty else {
                return
            }

            for joiningMember in joiningMembers {
                let movingUp = MembershipChange(member: joiningMember, toStatus: .up)
                leadershipActions.append(.moveMember(movingUp))
                let change = self.membership.apply(movingUp)

                // FIXME: the changes should be gossiped rather than sent directly
                if let change = change {
                    self.log.info("Leader moving member: \(change)")
                    self.events.publish(.membershipChange(change))
                }
            }
        }

        moveMembersUp()

        return leadershipActions
    }

    enum LeaderAction {
        case moveMember(MembershipChange)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ClusterShellState + Logging

extension ClusterShellState {
    var metadata: Logger.Metadata {
        return [
            "membership/count": "\(String(describing: self.membership.count(atLeast: .joining)))",
        ]
    }

    func logMembership() {
        self.log.info("MEMBERSHIP:::: \(self.membership.prettyDescription(label: self.selfNode.node.systemName))")
    }
}
