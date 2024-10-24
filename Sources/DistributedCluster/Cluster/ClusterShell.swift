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

import DistributedActorsConcurrencyHelpers
import Logging
import NIO
import SWIM

/// Cluster namespace.
public enum Cluster {}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Internal Shell responsible for all clustering (i.e. connection management) state.

/// The cluster shell "drives" all internal state machines of the cluster subsystem.
///
/// It is responsible for managing the underlying (re-)connections by extending and accepting/rejecting handshakes,
/// as well as orchestrating any high-level membership changes, e.g. by interacting with a failure detector and other gossip mechanisms.
///
/// It keeps the `Membership` instance that can be seen the source of truth for any membership based decisions.
internal class ClusterShell {
    internal static let naming = _ActorNaming.unique("cluster")
    public typealias Ref = _ActorRef<ClusterShell.Message>

    static let gossipID: StringGossipIdentifier = "membership"

    private var selfNode: Cluster.Node {
        self.settings.bindNode
    }

    private let settings: ClusterSystemSettings

    // ~~~~~~ HERE BE DRAGONS, shared concurrently modified concurrent state ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    // We do this to avoid "looping" any initial access of an actor ref through the cluster shell's mailbox
    // which would cause more latency to obtaining the association. refs cache the remote control once they have obtained it.

    // TODO: consider ReadWriteLock lock, these accesses are very strongly read only biased
    private let _associationsLock: Lock

    /// Used by remote actor refs to obtain associations
    /// - Protected by: `_associationsLock`
    private var _associations: [Cluster.Node: Association]
    /// Node tombstones are kept here in order to avoid attempting to associate if we get a reference to such node,
    /// which would normally trigger an `ensureAssociated`.
    /// - Protected by: `_associationsLock`
    private var _associationTombstones: [Cluster.Node: Association.Tombstone]

    internal func getAnyExistingAssociation(with endpoint: Cluster.Endpoint) -> Association? {
        self._associationsLock.withLock {
            // TODO: a bit terrible; perhaps key should be Node and then confirm by Cluster.Node?
            // this used to be separated in the State keeping them by Node and here we kept by unique though that caused other challenges
            self._associations.first { $0.key.endpoint == endpoint }?.value
        }
    }

    internal func getExistingAssociationTombstone(with node: Cluster.Node) -> Association.Tombstone? {
        self._associationsLock.withLock {
            self._associationTombstones[node]
        }
    }

    /// Get an existing association or ensure that a new one shall be stored and joining kicked off if the target node was not known yet.
    /// Safe to concurrently access by privileged internals directly
    internal func getEnsureAssociation(with node: Cluster.Node, file: String = #filePath, line: UInt = #line) -> StoredAssociationState {
        self._associationsLock.withLock {
            if let tombstone = self._associationTombstones[node] {
                return .tombstone(tombstone)
            } else if let existing = self._associations[node] {
                return .association(existing)
            } else {
                let association = Association(selfNode: self.selfNode, remoteNode: node)
                self._associations[node] = association

                /// We're trying to send to `node` yet it has no association (not even in progress),
                /// thus we need to kick it off. Once it completes it will .completeAssociation() on the stored one (here in the field in Shell).
                self.ref.tell(.command(.handshakeWithSpecific(node)))

                return .association(association)
            }
        }
    }

    internal func getSpecificExistingAssociation(with node: Cluster.Node) -> Association? {
        self._associationsLock.withLock {
            self._associations[node]
        }
    }

    enum StoredAssociationState {
        /// An existing (ready or being associated association) which can be used to send (or buffer buffer until associated/terminated)
        case association(Association)
        /// The association with the node existed, but is now a tombstone and no more messages shall be send to it.
        case tombstone(Association.Tombstone)
    }

    /// To be invoked by cluster shell whenever handshake is accepted, creating a completed association.
    /// Causes messages to be flushed onto the new associated channel.
    private func completeAssociation(_ associated: ClusterShellState.AssociatedDirective, file: String = #filePath, line: UInt = #line) throws {
        // 1) Complete and store the association
        try self._associationsLock.withLockVoid {
            let node: Cluster.Node = associated.handshake.remoteNode
            let association = self._associations[node] ??
                Association(selfNode: associated.handshake.localNode, remoteNode: node)

            try association.completeAssociation(handshake: associated.handshake, over: associated.channel)

            self._associations[node] = association
        }

        // 2) Ensure the failure detector knows about this node
        Task {
            await self._swimShell?.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): rename once https://github.com/apple/swift/pull/42098 is implemented
                __secretlyKnownToBeLocal.monitor(node: associated.handshake.remoteNode)
            }
        }
    }

    /// Performs all cleanups related to terminating an association:
    /// - cleans the Shell local Association cache
    /// - sets a tombstone for the now-tombstone Cluster.Node
    /// - ensures node is at least .down in the Membership
    ///
    /// Can be invoked as result of a direct .down being issued, or because of a node replacement happening.
    internal func terminateAssociation(_ system: ClusterSystem, state: inout ClusterShellState, _ remoteNode: Cluster.Node) {
        traceLog_Remote(system.cluster.node, "Terminate association with [\(remoteNode)]")

        let removedAssociationOption: Association? = self._associationsLock.withLock {
            // tombstone the association in the shell immediately.
            // No more message sends to the system will be possible.
            traceLog_Remote(system.cluster.node, "Finish terminate association [\(remoteNode)]: Stored tombstone")
            self._associationTombstones[remoteNode] = Association.Tombstone(remoteNode, settings: system.settings)
            return self._associations.removeValue(forKey: remoteNode)
        }

        guard let removedAssociation = removedAssociationOption else {
            system.log.debug("Attempted to terminate non-existing association [\(reflecting: remoteNode)].")
            return
        }

        system.log.warning("Terminate existing association [\(reflecting: remoteNode)].")

        // notify the failure detector, that we shall assume this node as dead from here on.
        // it's gossip will also propagate the information through the cluster
        traceLog_Remote(system.cluster.node, "Finish terminate association [\(remoteNode)]: Notifying SWIM, .confirmDead")
        system.log.warning("Confirm .dead to underlying SWIM, node: \(reflecting: remoteNode)")
        self._swimShell?.confirmDead(node: remoteNode)

        // it is important that we first check the contains; as otherwise we'd re-add a .down member for what was already removed (!)
        if state.membership.contains(remoteNode) {
            // Ensure to down the "previous" member in the Membership, it is not even .leaving anymore.
            if state.membership.mark(remoteNode, as: .down) == nil {
                // it was already removed, nothing to do
                state.log.trace(
                    "Terminate association with \(reflecting: remoteNode), yet node not in membership already?", metadata: [
                        "cluster/membership": "\(pretty: state.membership)",
                    ]
                )
            } // else: Note that we CANNOT remove() just yet, as we only want to do this when all nodes have seen the down/leaving
        }

        // The last thing we attempt to do with the other node is to shoot it,
        // in case it's a "zombie" that still may receive messages for some reason.
        ClusterShell.shootTheOtherNodeAndCloseConnection(system: system, targetNodeAssociation: removedAssociation)
    }

    /// Final action performed when severing ties with another node.
    /// We "Shoot The Other Node ..." (STONITH) in order to let it know as soon as possible (i.e. directly, without waiting for gossip to reach it).
    ///
    /// This is a best-effort message; as we may be downing it because we cannot communicate with it after all, in such situation (and many others)
    /// the other node would never receive this direct kill/down eager "gossip." We hope it will either receive the down via some means, or determine
    /// by itself that it should down itself.
    internal static func shootTheOtherNodeAndCloseConnection(system: ClusterSystem, targetNodeAssociation: Association) {
        let log = system.log
        let remoteNode = targetNodeAssociation.remoteNode
        traceLog_Remote(system.cluster.node, "Finish terminate association [\(remoteNode)]: Shooting the other node a direct .gossip to down itself")

        // On purpose use the "raw" RemoteControl to send the message -- this way we avoid the association lookup (it may already be removed),
        // and directly hit the channel. It is also guaranteed that the message is flushed() before we close it in the next line.
        let shootTheOtherNodePromise: EventLoopPromise<Void> = system._eventLoopGroup.next().makePromise(of: Void.self)

        let ripMessage = Payload(payload: .message(ClusterShell.Message.inbound(.restInPeace(remoteNode, from: system.cluster.node))))
        targetNodeAssociation.sendUserMessage(
            envelope: ripMessage,
            recipient: ._clusterShell(on: remoteNode),
            promise: shootTheOtherNodePromise
        )

        let shootTheNodeWriteTimeout: NIO.TimeAmount = .seconds(10) // FIXME: hardcoded last write timeout...
        system._eventLoopGroup.next().scheduleTask(deadline: NIODeadline.now() + shootTheNodeWriteTimeout) {
            shootTheOtherNodePromise.fail(TimeoutError(message: "Timed out writing final STONITH to \(remoteNode), should close forcefully.", timeout: .seconds(10))) // FIXME: same timeout but diff type
        }

        shootTheOtherNodePromise.futureResult.map { _ in
            // Only after the write has completed, we close the channel
            targetNodeAssociation.terminate(system)
        }.whenComplete { reason in
            log.trace("Closed connection with \(remoteNode): \(reason)")
        }
    }

    /// For testing only.
    /// Safe to concurrently access by privileged internals.
    internal var _testingOnly_associations: [Association] {
        self._associationsLock.withLock {
            [Association](self._associations.values)
        }
    }

    /// For testing only.
    /// Safe to concurrently access by privileged internals.
    internal var _testingOnly_associationTombstones: [Association.Tombstone] {
        self._associationsLock.withLock {
            [Association.Tombstone](self._associationTombstones.values)
        }
    }

    /// For testing only.
    internal func _associatedNodes() -> Set<Cluster.Node> {
        self._associationsLock.withLock {
            Set(self._associations.keys)
        }
    }

    // ~~~~~~ END OF HERE BE DRAGONS, shared concurrently modified concurrent state ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

    // `_serializationPool` is only used when `start()` is invoked, and there it is set immediately as well
    // any earlier access to the pool is a bug (in our library) and must be treated as such.
    private var _serializationPool: _SerializationPool?
    internal var serializationPool: _SerializationPool {
        guard let pool = self._serializationPool else {
            fatalError("BUG! Tried to access serializationPool on \(self) and it was nil! Please report this on the issue tracker.")
        }
        return pool
    }

    internal private(set) var _swimShell: SWIMActor?

    private var clusterEvents: ClusterEventStream?

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Cluster Shell, reference used for issuing commands to the cluster

    private let refLock = Lock()

    private var _ref: ClusterShell.Ref?
    var ref: ClusterShell.Ref {
        self.refLock.lock()
        defer { refLock.unlock() }

        // since this is initiated during system startup, nil should never happen
        guard let it = self._ref else {
            return fatalErrorBacktrace("Accessing ClusterShell.ref failed, was nil! This should never happen as access should only happen after start() was invoked.")
        }
        return it
    }

    init(settings: ClusterSystemSettings) {
        self.settings = settings
        self._associationsLock = Lock()
        self._associations = [:]
        self._associationTombstones = [:]

        // not enjoying this dance, but this way we can share the ClusterShell as the shell AND the container for the ref.
        // the single thing in the class it will modify is the associations registry, which we do to avoid actor queues when
        // remote refs need to obtain those
        //
        // FIXME: see if we can restructure this to avoid these nil/then-set dance
        self._ref = nil
    }

    /// Actually starts the shell which kicks off binding to a port, and all further cluster work
    internal func start(system: ClusterSystem, clusterEvents: ClusterEventStream) async throws -> _ActorRef<Message> {
        let instrumentation = system.settings.instrumentation.makeInternalActorTransportInstrumentation()
        self._serializationPool = try _SerializationPool(settings: .default, serialization: system.serialization, instrumentation: instrumentation)
        self.clusterEvents = clusterEvents

        let ref = try system._spawnSystemActor(ClusterShell.naming, self.bind(), props: self.props)
        self._ref = ref

        await _Props.$forSpawn.withValue(SWIMActor.props) {
            self._swimShell = await SWIMActor(settings: self.settings.swim, clusterRef: ref, system: system)
        }

        return ref
    }

    // Due to lack of Union Types, we have to emulate them
    enum Message: Codable {
        // The external API, exposed to users of the ClusterShell
        case command(CommandMessage)
        // The external API, exposed to users of the ClusterShell to query for state
        case query(QueryMessage)
        /// Messages internally driving the state machines; timeouts, network inbound events etc.
        case inbound(InboundMessage)
        /// Used to request making a change to the membership owned by the ClusterShell;
        /// Issued by downing or leader election and similar facilities. Thanks to centralizing the application of changes,
        /// we can ensure that a ``Cluster/Event`` is signalled only once, and only when it is really needed.
        /// E.g. signalling a down twice for whatever reason, needs not be notified two times to all subscribers of cluster events.
        ///
        /// If the passed in event applied to the current membership is an effective change, the change will be published using the `system.cluster.events`.
        case requestMembershipChange(Cluster.Event) // TODO: make a command
        /// Gossiping is handled by /system/cluster/gossip, however acting on it still is our task,
        /// thus the gossiper forwards gossip whenever interesting things happen ("more up to date gossip")
        /// to the shell, using this message, so we may act on it -- e.g. perform leader actions or change membership that we store.
        case gossipFromGossiper(Cluster.MembershipGossip)
    }

    // this is basically our API internally for this system
    enum CommandMessage: _NotActuallyCodableMessage, SilentDeadLetter {
        /// Connect and handshake with remote `Node`, obtaining an `Cluster.Node` in the process.
        /// Once the handshake is completed, reply to `replyTo` with the handshake result, and also mark the unique node as `.joining`.
        ///
        /// If one is present, the underlying failure detector will be asked to monitor this node as well.
        case handshakeWith(Cluster.Endpoint)
        case handshakeWithSpecific(Cluster.Node)
        case retryHandshake(HandshakeStateMachine.InitiatedState)

        case failureDetectorReachabilityChanged(Cluster.Node, Cluster.MemberReachability)

        /// Used to signal a "down was issued" either by the user, or another part of the system.
        case downCommand(Cluster.Endpoint) // TODO: add reason
        /// Used to signal a "down was issued" either by the user, or another part of the system.
        case downCommandMember(Cluster.Member)
        case shutdown(BlockingReceptacle<Void>) // TODO: could be NIO future
        case cleanUpAssociationTombstones
    }

    enum QueryMessage: _NotActuallyCodableMessage {
        case associatedNodes(_ActorRef<Set<Cluster.Node>>) // TODO: better type here
        case currentMembership(_ActorRef<Cluster.Membership>)
    }

    internal enum InboundMessage {
        case handshakeOffer(Wire.HandshakeOffer, channel: Channel, handshakeReplyTo: EventLoopPromise<Wire.HandshakeResponse>)
        case handshakeAccepted(Wire.HandshakeAccept, channel: Channel)
        case handshakeRejected(Wire.HandshakeReject)
        case handshakeFailed(Cluster.Endpoint, Error)
        /// This message is used to avoid "zombie nodes" which are known as .down by other nodes, but still stay online.
        /// It is sent as a best-effort by any node which terminates the connection with this node, e.g. if it knows already
        /// about this node being `.down` yet it still somehow attempts to communicate with the another node.
        ///
        /// Upon receipt, should be interpreted as having to immediately down myself.
        case restInPeace(Cluster.Node, from: Cluster.Node)
    }

    // TODO: reformulate as Wire.accept / reject?
    internal enum HandshakeResult: Equatable, _NotActuallyCodableMessage {
        case success(Cluster.Node)
        case failure(HandshakeStateMachine.HandshakeConnectionError)
    }

    private let props: _Props =
        .init()
            .supervision(strategy: .escalate) // always escalate failures, if this actor fails we're in big trouble -> terminate the system
            ._asWellKnown
    
    deinit {
        self.clusterEvents?.clean()
        self._swimShell?.clean()
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster Bootstrap / Binding

extension ClusterShell {
    /// Binds on setup to the configured address (as configured in `system.settings`).
    ///
    /// Once bound proceeds to `ready` state, where it remains to accept or initiate new handshakes.
    private func bind() -> _Behavior<Message> {
        return .setup { context in
            // let clusterSettings = context.system.settings
            let bindNode = self.selfNode

            // 1) failure detector (SWIM)
            // Moved to start method

            // 2) discovering of new members:
            if let discoverySettings = self.settings.discovery {
                _ = try context._spawn(DiscoveryShell.naming, DiscoveryShell(settings: discoverySettings, cluster: context.myself).behavior)
            }

            // 3) leader election, so it may move members: .joining -> .up (and other `LeaderAction`s)
            if let leaderElection = self.settings.autoLeaderElection.make(context.system.cluster.settings) {
                let leadershipShell = Leadership.Shell(leaderElection)
                let leadership = try context._spawn(Leadership.Shell.naming, leadershipShell.behavior)
                context.watch(leadership) // if leadership fails for some reason, we are in trouble and need to know about it
            }

            context.log.info("Binding to: [\(bindNode)]")

            let chanElf = self.bootstrapServerSide(
                system: context.system,
                shell: context.myself,
                bindNode: bindNode,
                settings: self.settings,
                serializationPool: self.serializationPool
            )

            return context.awaitResultThrowing(of: chanElf, timeout: self.settings.bindTimeout) { (chan: Channel) in
                context.log.info("Bound to \(chan.localAddress.map(\.description) ?? "<no-local-address>")")

                let gossiperControl: GossiperControl<Cluster.MembershipGossip, Cluster.MembershipGossip> = try Gossiper._spawn(
                    context,
                    name: "\(ActorPath._clusterGossip.name)",
                    settings: .init(
                        interval: self.settings.membershipGossipInterval,
                        intervalRandomFactor: self.settings.membershipGossipIntervalRandomFactor,
                        style: .acknowledged(timeout: self.settings.membershipGossipInterval),
                        peerDiscovery: .onClusterMember(atLeast: .joining, resolve: { member in
                            let resolveContext = _ResolveContext<GossipShell<Cluster.MembershipGossip, Cluster.MembershipGossip>.Message>(id: ._clusterGossip(on: member.node), system: context.system)
                            return context.system._resolve(context: resolveContext).asAddressable
                        })
                    ),
                    props: ._wellKnown,
                    makeLogic: {
                        MembershipGossipLogic(
                            $0,
                            notifyOnGossipRef: context.messageAdapter(from: Cluster.MembershipGossip.self) {
                                Optional.some(Message.gossipFromGossiper($0))
                            }
                        )
                    }
                )

                guard let events = self.clusterEvents else {
                    throw ClusterSystemError(.shuttingDown(""))
                }
                
                var state = ClusterShellState(
                    settings: self.settings,
                    channel: chan,
                    events: events,
                    gossiperControl: gossiperControl,
                    log: context.log
                )

                // immediately join the owner node (us), as we always should be part of the membership
                // this immediate join is important in case we immediately get a handshake from other nodes,
                // and will need to reply to them with our `Member`.
                if let change = state.latestGossip.membership.join(state.selfNode) {
                    // always update the snapshot before emitting events
                    context.system.cluster.updateMembershipSnapshot(state.membership)
                    self.publish(.membershipChange(change))
                }

                return self.ready(state: state)
            }
        }
    }

    private func publish(_ event: Cluster.Event) {
        self.clusterEvents.map { self.publish(event, to: $0) }
    }

    private func publish(_ event: Cluster.Event, to eventStream: ClusterEventStream) {
        Task {
            await eventStream.publish(event)
        } // TODO(send): we need "send"
    }

    /// Called periodically to remove association tombstones after the configured TTL.
    private func cleanUpAssociationTombstones() -> _Behavior<Message> {
        self._associationsLock.withLockVoid {
            for (id, tombstone) in self._associationTombstones {
                if tombstone.removalDeadline.isOverdue() {
                    self._associationTombstones.removeValue(forKey: id)
                }
            }
        }
        return .same
    }

    /// Ready and interpreting commands and incoming messages.
    ///
    /// Serves as main "driver" for handshake and association state machines.
    private func ready(state: ClusterShellState) -> _Behavior<Message> {
        func receiveShellCommand(_ context: _ActorContext<Message>, command: CommandMessage) -> _Behavior<Message> {
            state.tracelog(.inbound, message: command)

            switch command {
            case .handshakeWith(let node):
                return self.beginHandshake(context, state, with: node)
            case .handshakeWithSpecific(let node):
                return self.beginHandshake(context, state, with: node.endpoint)
            case .retryHandshake(let initiated):
                return self.retryHandshake(context, state, initiated: initiated)

            case .failureDetectorReachabilityChanged(let node, let reachability):
                guard let member = state.membership.member(node) else {
                    return .same // reachability change of unknown node
                }
                switch reachability {
                case .reachable:
                    return self.onReachabilityChange(context, state: state, change: Cluster.ReachabilityChange(member: member.asReachable))
                case .unreachable:
                    return self.onReachabilityChange(context, state: state, change: Cluster.ReachabilityChange(member: member.asUnreachable))
                case ._PLEASE_DO_NOT_EXHAUSTIVELY_MATCH_THIS_ENUM_NEW_CASES_MIGHT_BE_ADDED_IN_THE_FUTURE:
                    context.log.error("Received Cluster.MemberReachability [\(reachability)]. This should not happen, please file an issue.")
                    return .same
                }

            case .shutdown(let receptacle):
                return self.onShutdownCommand(context, state: state, signalOnceUnbound: receptacle)

            case .downCommand(let endpoint):
                if let member = state.membership.anyMember(forEndpoint: endpoint) {
                    return self.ready(state: self.onDownCommand(context, state: state, member: member))
                } else {
                    return self.ready(state: state)
                }
            case .downCommandMember(let member):
                return self.ready(state: self.onDownCommand(context, state: state, member: member))
            case .cleanUpAssociationTombstones:
                return self.cleanUpAssociationTombstones()
            }
        }

        func receiveQuery(_ context: _ActorContext<Message>, query: QueryMessage) -> _Behavior<Message> {
            state.tracelog(.inbound, message: query)

            switch query {
            case .associatedNodes(let replyTo):
                replyTo.tell(self._associatedNodes())
                return .same
            case .currentMembership(let replyTo):
                replyTo.tell(state.membership)
                return .same
            }
        }

        func receiveInbound(_ context: _ActorContext<Message>, message: InboundMessage) throws -> _Behavior<Message> {
            switch message {
            case .handshakeOffer(let offer, let channel, let promise):
                self.tracelog(context, .receiveUnique(from: offer.originNode), message: offer)
                return self.onHandshakeOffer(context, state, offer, inboundChannel: channel, replyInto: promise)

            case .handshakeAccepted(let accepted, let channel):
                self.tracelog(context, .receiveUnique(from: accepted.targetNode), message: accepted)
                return self.onHandshakeAccepted(context, state, accepted, channel: channel)

            case .handshakeRejected(let rejected):
                self.tracelog(context, .receiveUnique(from: rejected.targetNode), message: rejected)
                return self.onHandshakeRejected(context, state, rejected)

            case .handshakeFailed(let fromNode, let error):
                self.tracelog(context, .receive(from: fromNode), message: error)
                return self.onHandshakeFailed(context, state, with: fromNode, error: error) // FIXME: implement this basically disassociate() right away?

            case .restInPeace(let intendedNode, let fromNode):
                self.tracelog(context, .receiveUnique(from: fromNode), message: message)
                return self.onRestInPeace(context, state, intendedNode: intendedNode, fromNode: fromNode)
            }
        }

        /// Allows processing in one spot, all membership changes which we may have emitted in other places, due to joining, downing etc.
        func receiveChangeMembershipRequest(_ context: _ActorContext<Message>, event: Cluster.Event) -> _Behavior<Message> {
            self.tracelog(context, .receive(from: state.selfNode.endpoint), message: event)
            var state = state

            // 1) IMPORTANT: We MUST apply and act on the incoming event FIRST, before handling the other events.
            // This is because:
            //   - is the event is a `leadershipChange` applying it could make us become the leader
            //   - if that happens, the 2) phase will collect leader actions (perhaps for the first time),
            //     and issue any pending up/down events.
            //   - For consistency such events MUST only be issued AFTER we have emitted the leadership change (!)
            //     Otherwise subscribers may end up seeing joining->up changes BEFORE they see the leadershipChange,
            //     which is not strictly wrong per se, however it is very confusing -- we know there MUST be a leader
            //     somewhere in order to perform those moves, so it is confusing if such joining->up events were to be
            //     seen by a subscriber before they saw "we have a leader".
            if state.applyClusterEvent(event).applied {
                state.latestGossip.incrementOwnerVersion()

                // Always FIRST update the snapshot, before emitting events:
                context.system.cluster.updateMembershipSnapshot(state.membership)

                // we only publish the event if it really caused a change in membership, to avoid echoing "the same" change many times.
                self.publish(event)
            } // else no "effective change", thus we do not publish events

            // 3) Collect and interpret leader actions which may result changing the membership and publishing events for the changes
            let actions: [ClusterShellState.LeaderAction] = state.collectLeaderActions()
            state = self.interpretLeaderActions(context.system, state, actions)

            if case .membershipChange(let change) = event {
                self.tryConfirmDeadToSWIM(context, state, change: change)
                self.tryIntroduceGossipPeer(context, state, change: change)
            }

            return self.ready(state: state)
        }

        func receiveMembershipGossip(
            _ context: _ActorContext<Message>,
            _ state: ClusterShellState,
            gossip: Cluster.MembershipGossip
        ) -> _Behavior<Message> {
            tracelog(context, .gossip(gossip), message: gossip)
            var state = state

            let beforeGossipMerge = state.latestGossip

            let mergeDirective = state.latestGossip.mergeForward(incoming: gossip) // mutates the gossip
            context.log.trace(
                "Local membership version is [.\(mergeDirective.causalRelation)] to incoming gossip; Merge resulted in \(mergeDirective.effectiveChanges.count) changes.",
                metadata: [
                    "tag": "membership",
                    "membership/changes": Logger.MetadataValue.array(mergeDirective.effectiveChanges.map {
                        Logger.MetadataValue.stringConvertible($0)
                    }),
                    "gossip/incoming": "\(pretty: gossip)",
                    "gossip/before": "\(pretty: beforeGossipMerge)",
                    "gossip/now": "\(pretty: state.latestGossip)",
                ]
            )

            // we want to update the snapshot before the events are published
            context.system.cluster.updateMembershipSnapshot(state.membership)

            // Publish the events
            var eventsToPublish: [Cluster.Event] = []
            mergeDirective.effectiveChanges.forEach { effectiveChange in
                // a change COULD have also been a replacement, in which case we need to publish it as well the removal od the
                if let replacementChange = effectiveChange.replacementDownPreviousNodeChange {
                    eventsToPublish.append(.membershipChange(replacementChange))
                    self.tryConfirmDeadToSWIM(context, state, change: replacementChange)
                }
                eventsToPublish.append(.membershipChange(effectiveChange))
                self.tryConfirmDeadToSWIM(context, state, change: effectiveChange)
            }

            Task { [eventsToPublish] in
                for event in eventsToPublish {
                    await self.clusterEvents?.publish(event)
                }
            }

            // follow up with leader actions
            let leaderActions = state.collectLeaderActions()
            state = self.interpretLeaderActions(context.system, state, leaderActions)

            return self.ready(state: state)
        }

        return _Behavior<Message>
            .receive { context, message in
                switch message {
                case .command(let command): return receiveShellCommand(context, command: command)
                case .query(let query): return receiveQuery(context, query: query)
                case .inbound(let inbound): return try receiveInbound(context, message: inbound)
                case .requestMembershipChange(let event): return receiveChangeMembershipRequest(context, event: event)
                case .gossipFromGossiper(let gossip): return receiveMembershipGossip(context, state, gossip: gossip)
                }
            }
            .receiveSpecificSignal(_Signals.Terminated.self) { context, signal in
                context.log.error("Cluster actor \(signal.id) terminated unexpectedly! Will initiate cluster shutdown.")
                try context.system.shutdown()
                return .same // the system shutdown will cause downing which we may want to still handle, and then will stop us
            }
    }

    func tryConfirmDeadToSWIM(_ context: _ActorContext<Message>, _ state: ClusterShellState, change: Cluster.MembershipChange) {
        if change.status.isAtLeast(.down) {
            self._swimShell?.confirmDead(node: change.member.node)
        }
    }

    func tryIntroduceGossipPeer(_ context: _ActorContext<Message>, _ state: ClusterShellState, change: Cluster.MembershipChange) {
        guard change.status < .down else {
            return
        }
        guard change.member.node != state.selfNode else {
            return
        }
        // TODO: make it cleaner? though we decided to go with manual peer management as the ClusterShell owns it, hm

        // TODO: consider receptionist instead of this; we're "early" but receptionist could already be spreading its info to this node, since we associated.
        let gossipPeer: GossipShell<Cluster.MembershipGossip, Cluster.MembershipGossip>.Ref = context.system._resolve(
            context: .init(id: ._clusterGossip(on: change.member.node), system: context.system)
        )
        // FIXME: make sure that if the peer terminated, we don't add it again in here, receptionist would be better then to power this...
        // today it can happen that a node goes down but we dont know yet so we add it again :O
        state.gossiperControl.introduce(peer: gossipPeer)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Handshake init

extension ClusterShell {
    /// Initiate a handshake to the `remoteNode`.
    /// Upon successful handshake, the `replyTo` actor shall be notified with its result, as well as the handshaked-with node shall be marked as `.joining`.
    ///
    /// Handshakes are currently not performed concurrently but one by one.
    func beginHandshake(_ context: _ActorContext<Message>, _ state: ClusterShellState, with remoteNode: Cluster.Endpoint) -> _Behavior<Message> {
        var state = state

        guard remoteNode != state.selfNode.endpoint else {
            state.log.debug("Ignoring attempt to handshake with myself; Could have been issued as confused attempt to handshake as induced by discovery via gossip?")
            return .same
        }

        // if an association exists for any Cluster.Node that this Node represents, we can use this and abort the handshake dance here
        if let existingAssociation = self.getAnyExistingAssociation(with: remoteNode) {
            state.log.debug("Association already allocated for remote: \(reflecting: remoteNode), existing association: [\(existingAssociation)]")
            switch existingAssociation.state {
            case .associating:
                // continue, we may be the first beginHandshake (as associations may be ensured outside of actor context)
                ()
            case .associated:
                // nothing to do, we already associated
                return .same
            case .tombstone:
                // TODO: soundness check if this isn't about handshaking with a replacement, then we should continue;
                return .same
            }
        }

        let handshakeState = state.initHandshake(with: remoteNode)
        // we MUST register the intention of shaking hands with remoteAddress before obtaining the connection,
        // in order to let the fsm handle any retry decisions in face of connection failures et al.

        switch handshakeState {
        case .initiated(let initiated):
            state.log.debug("Initiated handshake: \(initiated)", metadata: [
                "cluster/associatedNodes": "\(self._associatedNodes())",
            ])
            return self.connectSendHandshakeOffer(context, state, initiated: initiated)

        case .wasOfferedHandshake, .inFlight, .completed:
            state.log.debug("Handshake in other state: \(handshakeState)")
            // the reply will be handled already by the future.whenComplete we've set up above here
            // so nothing to do here, just become the next state
            return self.ready(state: state)
        }
    }

    func retryHandshake(_ context: _ActorContext<Message>, _ state: ClusterShellState, initiated: HandshakeStateMachine.InitiatedState) -> _Behavior<Message> {
        state.log.debug("Retry handshake with: \(initiated.remoteEndpoint)")
//
//        // FIXME: this needs more work...
//        let assoc = self.getRetryAssociation(with: initiated.remoteNode)

        return self.connectSendHandshakeOffer(context, state, initiated: initiated)
    }

    func connectSendHandshakeOffer(_ context: _ActorContext<Message>, _ state: ClusterShellState, initiated: HandshakeStateMachine.InitiatedState) -> _Behavior<Message> {
        var state = state
        state.log.debug("Extending handshake offer", metadata: [
            "handshake/remoteNode": "\(initiated.remoteEndpoint)",
        ])

        let offer: Wire.HandshakeOffer = initiated.makeOffer()
        self.tracelog(context, .send(to: initiated.remoteEndpoint), message: offer)

        let outboundChanElf: EventLoopFuture<Channel> = self.bootstrapClientSide(
            system: context.system,
            shell: context.myself,
            targetNode: initiated.remoteEndpoint,
            handshakeOffer: offer,
            settings: state.settings,
            serializationPool: self.serializationPool
        )

        // the timeout is being handled by the `connectTimeout` socket option in NIO, so it is safe to use an infinite timeout here
        return context.awaitResult(of: outboundChanElf, timeout: .effectivelyInfinite) { result in
            switch result {
            case .success(let chan):
                return self.ready(state: state.onHandshakeChannelConnected(initiated: initiated, channel: chan))

            case .failure(let error):
                return self.onOutboundConnectionError(context, state, with: initiated.remoteEndpoint, error: error)
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Incoming Handshake

extension ClusterShell {
    func rejectIfNodeAlreadyLeaving(
        _ context: _ActorContext<Message>,
        _ state: ClusterShellState,
        _ offer: Wire.HandshakeOffer
    ) -> Wire.HandshakeReject? {
        let member = state.selfMember

        if member.status.isAtLeast(.leaving) {
            state.log.notice("Received handshake while already [\(member.status)]")

            return .init(
                version: state.settings.protocolVersion,
                targetNode: state.selfNode,
                originNode: offer.originNode,
                reason: "Node already leaving cluster.",
                whenHandshakeReplySent: nil
            )
        }

        // let's try that to make that handshake
        return nil
    }

    /// Initial entry point for accepting a new connection; Potentially allocates new handshake state machine.
    /// - parameter inboundChannel: the inbound connection channel that the other node has opened and is offering its handshake on,
    ///   (as opposed to the channel which we may have opened when we first extended a handshake to that node which would be stored in `state`)
    func onHandshakeOffer(
        _ context: _ActorContext<Message>, _ state: ClusterShellState,
        _ offer: Wire.HandshakeOffer, inboundChannel: Channel,
        replyInto handshakePromise: EventLoopPromise<Wire.HandshakeResponse>
    ) -> _Behavior<Message> {
        var state = state

        // TODO: guard that the target node is actually "us"? i.e. if we're exposed over various protocols and/or ports etc?
        if let rejection = self.rejectIfNodeAlreadyLeaving(context, state, offer) {
            handshakePromise.succeed(.reject(rejection))
            return .same
        }

        // if there already is an existing association, we'll bail out and abort this "new" connection; there must only ever be one association
        let maybeExistingAssociation: Association? = self.getSpecificExistingAssociation(with: offer.originNode)

        switch state.onIncomingHandshakeOffer(offer: offer, existingAssociation: maybeExistingAssociation, incomingChannel: inboundChannel) {
        case .negotiateIncoming(let hsm):
            // 0) ensure, since it seems we're indeed going to negotiate it;
            // otherwise another actor or something else could kick off the negotiation and we'd become the initiating (offering the handshake),
            // needlessly causing the "both nodes racing the handshake offer" situation, which will be resolved, but there's no need for rhat race here,
            // we'll simply accept (or not) the incoming offer.
            _ = self.getEnsureAssociation(with: offer.originNode)

            // 1) handshake is allowed to proceed
            switch hsm.negotiate() {
            case .acceptAndAssociate(let handshakeCompleted):
                state.log.trace("Accept handshake with \(reflecting: offer.originNode)!", metadata: [
                    "handshake/channel": "\(inboundChannel)",
                ])

                // 1.1) we're accepting; prepare accept
                let accept = handshakeCompleted.makeAccept(whenHandshakeReplySent: nil)

                // 2) Only now we can succeed the accept promise (as the old one has been terminated and cleared)
                self.tracelog(context, .send(to: offer.originNode.endpoint), message: accept)
                handshakePromise.succeed(.accept(accept))

                // 3) Complete and store the association, we are now ready to flush writes onto the network
                //
                // it is VERY important that we do so BEFORE we emit any cluster events, since then actors are free to
                // talk to other actors on the (now associated node) and if there is no `.associating` association yet
                // their communication attempts could kick off a handshake attempt; there is no need for this, since we're already accepting here.
                let directive = state.completeHandshakeAssociate(self, handshakeCompleted, channel: inboundChannel)

                // This association may mean that we've "replaced" a previously known node of the same host:port,
                // In case of such replacement we must down and terminate the association of the previous node.
                //
                // This MUST be called before we complete the new association as it may need to terminate the old one.
                self.handlePotentialAssociatedMemberReplacement(directive: directive, accept: accept, context: context, state: &state)

                do {
                    try self.completeAssociation(directive)
                    state.log.trace("Associated with: \(reflecting: handshakeCompleted.remoteNode)", metadata: [
                        "membership/change": "\(optional: directive.membershipChange)",
                        "membership": "\(state.membership)",
                    ])
                } catch {
                    state.log.warning("Error while trying to complete association with: \(reflecting: handshakeCompleted.remoteNode), error: \(error)", metadata: [
                        "membership/change": "\(optional: directive.membershipChange)",
                        "membership": "\(state.membership)",
                        "association/error": "\(error)",
                    ])
                }

                // 4) Emit cluster events (i.e. .join the new member)
                // publish any cluster events this association caused.
                // As the new association is stored, any reactions to these events will use the right underlying connection
                if let change = directive.membershipChange {
                    context.system.cluster.updateMembershipSnapshot(state.membership)
                    self.publish(.membershipChange(change), to: state.events) // TODO: need a test where a leader observes a replacement, and we ensure that it does not end up signalling up or removal twice?
                    self.tryIntroduceGossipPeer(context, state, change: change)
                }

                /// a new node joined, thus if we are the leader, we should perform leader tasks to potentially move it to .up
                let actions = state.collectLeaderActions()
                state = self.interpretLeaderActions(context.system, state, actions)

                /// only after leader (us, if we are one) performed its tasks, we update the metrics on membership (it might have modified membership)
                self.recordMetrics(context.system.metrics, membership: state.membership)

                return self.ready(state: state)

            case .rejectHandshake(let rejectedHandshake):
                state.log.warning("Rejecting handshake from \(offer.originNode), error: [\(rejectedHandshake.error)]:\(type(of: rejectedHandshake.error))")

                // note that we should NOT abort the channel here since we still want to send back the rejection.

                let reject: Wire.HandshakeReject = rejectedHandshake.makeReject(whenHandshakeReplySent: { () in
                    self.terminateAssociation(context.system, state: &state, rejectedHandshake.remoteNode)
                })
                self.tracelog(context, .send(to: offer.originNode.endpoint), message: reject)
                handshakePromise.succeed(.reject(reject))

                return self.ready(state: state)
            }

        case .abortIncomingHandshake(let error):
            state.log.debug("Aborting incoming handshake: \(error)")
            handshakePromise.fail(error)
            state.closeHandshakeChannel(offer: offer, channel: inboundChannel)
            return .same
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Failures to obtain connections

extension ClusterShell {
    func onOutboundConnectionError(_ context: _ActorContext<Message>, _ state: ClusterShellState, with remoteNode: Cluster.Endpoint, error: Error) -> _Behavior<Message> {
        var state = state
        state.log.debug("Failed to establish outbound channel to \(remoteNode), error: \(error)", metadata: [
            "handshake/remoteNode": "\(remoteNode)",
            "handshake/error": "\(error)",
        ])

        guard let handshakeState = state.handshakeInProgress(with: remoteNode) else {
            state.log.warning("Connection error for handshake which is not in progress, this should not happen, but is harmless.", metadata: [
                "handshake/remoteNode": "\(remoteNode)",
                "handshake/error": "\(error)",
            ])
            return .same
        }

        switch handshakeState {
        case .initiated(var initiated):
            guard initiated.channel == nil else {
                fatalError("Seems we DO have a channel already! \(initiated)\n \(state)")
            }

            switch initiated.onConnectionError(error) {
            case .scheduleRetryHandshake(let retryDelay):
                state.log.debug("Schedule handshake retry", metadata: [
                    "handshake/remoteNote": "\(initiated.remoteEndpoint)",
                    "handshake/retryDelay": "\(retryDelay)",
                ])
                context.timers.startSingle(
                    key: _TimerKey("handshake-timer-\(remoteNode)"),
                    message: .command(.retryHandshake(initiated)),
                    delay: retryDelay
                )

                // ensure we store the updated state; since retry attempts modify the backoff state
                state._handshakes[remoteNode] = .initiated(initiated)

            case .giveUpOnHandshake:
                if let hsmState = state.closeOutboundHandshakeChannel(with: remoteNode) {
                    state.log.warning("Giving up on handshake with node [\(remoteNode)]", metadata: [
                        "handshake/error": "\(error)",
                        "handshake/state": "\(hsmState)",
                    ])
                }
            }

        case .wasOfferedHandshake(let state):
            preconditionFailure("Outbound connection error should never happen on receiving end. State was: [\(state)], error was: \(error)")
        case .completed(let completedState):
            // this could mean that another (perhaps inbound, rather than the outbound handshake we're attempting here) actually succeeded
            state.log.notice("Stored handshake state is .completed, while outbound connection establishment failed. Assuming existing completed association is correct.", metadata: [
                "handshake/error": "\(error)",
                "handshake/state": "\(state)",
                "handshake/completed": "\(completedState)",
            ])
        case .inFlight:
            preconditionFailure("An in-flight marker state should never be stored, yet was encountered in \(#function). State was: [\(state)], error was: \(error)")
        }

        return self.ready(state: state)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Incoming Handshake Replies

extension ClusterShell {
    private func onHandshakeAccepted(_ context: _ActorContext<Message>, _ state: ClusterShellState, _ inboundAccept: Wire.HandshakeAccept, channel: Channel) -> _Behavior<Message> {
        var state = state // local copy for mutation

        state.log.debug("Accept association with \(reflecting: inboundAccept.targetNode)!", metadata: [
            "handshake/localNode": "\(inboundAccept.originNode)",
            "handshake/remoteNode": "\(inboundAccept.targetNode)",
            "handshake/channel": "\(channel)",
        ])

        guard let handshakeCompleted = state.incomingHandshakeAccept(inboundAccept) else {
            if self._associatedNodes().contains(inboundAccept.targetNode) {
                // this seems to be a re-delivered accept, we already accepted association with this node.
                return .same
            } else {
                state.log.error("Unexpected handshake accept received: [\(inboundAccept)]. No handshake was in progress with \(inboundAccept.targetNode)")
                return .same
            }
        }

        // 1) Complete the handshake (in the cluster state)
        let directive = state.completeHandshakeAssociate(self, handshakeCompleted, channel: channel)

        // 1.1) This association may mean that we've "replaced" a previously known node of the same host:port,
        //   In case of such replacement we must down and terminate the association of the previous node.
        //
        //   This MUST be called before we complete the new association as it may need to terminate the old one.
        //   This MAY emit a .down event if there is a node being replaced; this is ok but MUST happen before we issue the new .joining change for the replacement
        self.handlePotentialAssociatedMemberReplacement(directive: directive, accept: inboundAccept, context: context, state: &state)

        // 2) Store the (now completed) association first, as it may be immediately used by remote _ActorRefs attempting to send to the remoteNode
        do {
            try self.completeAssociation(directive)
            state.log.trace("Associated with: \(reflecting: handshakeCompleted.remoteNode)", metadata: [
                "membership/change": "\(optional: directive.membershipChange)",
                "membership": "\(state.membership)",
            ])
        } catch {
            state.log.warning("Error while trying to complete association with: \(reflecting: handshakeCompleted.remoteNode), error: \(error)", metadata: [
                "membership/change": "\(optional: directive.membershipChange)",
                "membership": "\(state.membership)",
                "association/error": "\(error)",
            ])
        }

        // we want to update the snapshot before the events are published
        context.system.cluster.updateMembershipSnapshot(state.membership)

        // 3) publish any cluster events this association caused.
        //    As the new association is stored, any reactions to these events will use the right underlying connection
        if let change = directive.membershipChange {
            self.publish(.membershipChange(change), to: state.events) // TODO: need a test where a leader observes a replacement, and we ensure that it does not end up signalling up or removal twice?
            self.tryConfirmDeadToSWIM(context, state, change: change)
            self.tryIntroduceGossipPeer(context, state, change: change)
        }

        // 4) Since a new node joined, if we are the leader, we should perform leader tasks to potentially move it to .up
        let actions = state.collectLeaderActions()
        state = self.interpretLeaderActions(context.system, state, actions)

        self.recordMetrics(context.system.metrics, membership: state.membership)

        return self.ready(state: state)
    }

    /// An accept may imply that it replaced a previously associated member.
    /// If so, this method will .down it in the membership and terminate the previous instances association.
    private func handlePotentialAssociatedMemberReplacement(
        directive: ClusterShellState.AssociatedDirective,
        accept: Wire.HandshakeAccept,
        context: _ActorContext<Message>,
        state: inout ClusterShellState
    ) {
        if let replacedMember = directive.membershipChange?.replaced {
            // the change was a replacement and thus we need to down the old member (same host:port as the new one),
            // and terminate its association.

            state.log.info("Accepted handshake from [\(reflecting: directive.handshake.remoteNode)] which replaces the previously known: [\(reflecting: replacedMember)].")

            // We MUST be careful to first terminate the association and then store the new one in 2)
            self.terminateAssociation(context.system, state: &state, replacedMember.node)

            // we want to update the snapshot before the events are published
            context.system.cluster.updateMembershipSnapshot(state.membership)

            // By emitting these `change`s, we not only let anyone interested know about this,
            // but we also enable the shell (or leadership) to update the leader if it needs changing.
            //
            // We MUST emit this `.down` before emitting the replacement's event
            let change = Cluster.MembershipChange(member: replacedMember, toStatus: .down)
            self.publish(.membershipChange(change), to: state.events)
            self.tryConfirmDeadToSWIM(context, state, change: change)
        }
    }

    private func onHandshakeRejected(_ context: _ActorContext<Message>, _ state: ClusterShellState, _ reject: Wire.HandshakeReject) -> _Behavior<Message> {
        var state = state

        // we MAY be seeing a handshake failure from a 2 nodes concurrently shaking hands on 2 connections,
        // and we decided to tie-break and kill one of the connections. As such, the handshake COMPLETED successfully but
        // on the other connection; and the terminated one may yield an error (e.g. truncation error during proto parsing etc),
        // however that error is harmless - as we associated with the "other" right connection.
        if let existingAssociation = self.getSpecificExistingAssociation(with: reject.targetNode),
           existingAssociation.isAssociating
        {
            state.log.warning(
                "Handshake rejected by [\(reject.targetNode)], it was associating and is now tombstoned",
                metadata: state.metadataForHandshakes(node: reject.targetNode, error: nil)
            )
            self.terminateAssociation(context.system, state: &state, reject.targetNode)
            return self.ready(state: state)
        }

        if let existingAssociation = self.getAnyExistingAssociation(with: reject.targetNode.endpoint),
           existingAssociation.isAssociated || existingAssociation.isTombstone
        {
            state.log.debug(
                "Handshake rejected by [\(reject.targetNode)], however existing association with node exists. Could be that a concurrent handshake was failed on purpose.",
                metadata: state.metadataForHandshakes(node: reject.targetNode, error: nil)
            )
            return .same
        }

        state.log.warning(
            "Handshake rejected by [\(reject.targetNode)], reason: \(reject.reason)",
            metadata: state.metadataForHandshakes(node: reject.targetNode, error: nil)
        )

        // FIXME: don't retry on rejections; those are final; just failures are not, clarify this
        return .same
    }

    private func onHandshakeFailed(_ context: _ActorContext<Message>, _ state: ClusterShellState, with endpoint: Cluster.Endpoint, error: Error) -> _Behavior<Message> {
        // we MAY be seeing a handshake failure from a 2 nodes concurrently shaking hands on 2 connections,
        // and we decided to tie-break and kill one of the connections. As such, the handshake COMPLETED successfully but
        // on the other connection; and the terminated one may yield an error (e.g. truncation error during proto parsing etc),
        // however that error is harmless - as we associated with the "other" right connection.
        if let existingAssociation = self.getAnyExistingAssociation(with: endpoint),
           existingAssociation.isAssociated || existingAssociation.isTombstone
        {
            state.log.debug(
                "Handshake failed, however existing association with node exists. Could be that a concurrent handshake was failed on purpose.",
                metadata: state.metadataForHandshakes(endpoint: endpoint, error: error)
            )
            return .same
        }

        guard state.handshakeInProgress(with: endpoint) != nil else {
            state.log.debug("Received handshake failed notification, however handshake is not in progress, error: \(message: error)", metadata: [
                "handshake/node": "\(endpoint)",
            ])
            return .same
        }

        // TODO: tweak logging some more, this is actually not scary in racy handshakes; so it may happen often
        state.log.warning("Handshake error while connecting [\(endpoint)]: \(error)", metadata: state.metadataForHandshakes(endpoint: endpoint, error: error))

        return .same
    }

    private func onRestInPeace(_ context: _ActorContext<Message>, _ state: ClusterShellState, intendedNode: Cluster.Node, fromNode: Cluster.Node) -> _Behavior<Message> {
        let myselfNode = state.selfNode

        guard myselfNode == myselfNode else {
            state.log.warning(
                "Received stray .restInPeace message! Was intended for \(reflecting: intendedNode), ignoring.",
                metadata: [
                    "cluster/node": "\(String(reflecting: myselfNode))",
                    "sender/node": "\(String(reflecting: fromNode))",
                ]
            )
            return .same
        }
        guard !context.system.isShuttingDown else {
            // we are already shutting down thus other nodes declaring us as down is expected
            state.log.trace(
                "Already shutting down, received .restInPeace from [\(fromNode)], this is expected, other nodes may sever their connections with this node while we terminate.",
                metadata: [
                    "sender/node": "\(String(reflecting: fromNode))",
                ]
            )
            return .same
        }

        state.log.warning(
            "Received .restInPeace from \(fromNode), meaning this node is known to be .down or worse, and should terminate. Initiating self .down-ing.",
            metadata: [
                "sender/node": "\(String(reflecting: fromNode))",
            ]
        )

        guard let myselfMember = state.membership.member(myselfNode) else {
            state.log.error("Unable to find Cluster.Member for \(myselfNode) self node! This should not happen, please file an issue.")
            return .same
        }

        return self.ready(state: self.onDownCommand(context, state: state, member: myselfMember))
    }

//    private func notifyHandshakeFailure(state: HandshakeStateMachine.State, node: Cluster.Node, error: Error) {
//        switch state {
//        case .initiated(let initiated):
//            initiated.whenCompleted.fail(HandshakeConnectionError(node: node, message: "\(error)"))
//        case .wasOfferedHandshake(let offered):
//            offered.whenCompleted.fail(HandshakeConnectionError(node: node, message: "\(error)"))
//        case .completed(let completed):
//            completed.whenCompleted.fail(HandshakeConnectionError(node: node, message: "\(error)"))
//        case .inFlight:
//            preconditionFailure("An in-flight marker state should never be stored, yet was encountered in \(#function)")
//        }
//    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Shutdown

extension ClusterShell {
    private func onShutdownCommand(_ context: _ActorContext<Message>, state: ClusterShellState, signalOnceUnbound: BlockingReceptacle<Void>) -> _Behavior<Message> {
        // we exit the death-pact with any children we spawned, even if they fail now, we don't mind because we're shutting down
        context.children.forEach { ref in
            context.unwatch(ref)
        }

        let addrDesc = "\(state.settings.bindNode.endpoint.host):\(state.settings.bindNode.endpoint.port)"
        return context.awaitResult(of: state.channel.close(), timeout: context.system.settings.unbindTimeout) {
            // FIXME: also close all associations (!!!)
            switch $0 {
            case .success:
                context.log.info("Unbound server socket [\(addrDesc)], node: \(reflecting: state.selfNode)")
                self.serializationPool.shutdown()
                signalOnceUnbound.offerOnce(())
                return .stop
            case .failure(let err):
                context.log.warning("Failed while unbinding server socket [\(addrDesc)], node: \(reflecting: state.selfNode). Error: \(err)")
                self.serializationPool.shutdown()
                signalOnceUnbound.offerOnce(())
                throw err
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Handling cluster membership changes

extension ClusterShell {
    func onReachabilityChange(
        _ context: _ActorContext<Message>,
        state: ClusterShellState,
        change: Cluster.ReachabilityChange
    ) -> _Behavior<Message> {
        var state = state
        guard state.membership.applyReachabilityChange(change) != nil else {
            return .same
        }

        // we want to update the snapshot before the events are published
        context.system.cluster.updateMembershipSnapshot(state.membership)

        // then publish events and update metrics
        self.publish(.reachabilityChange(change))
        self.recordMetrics(context.system.metrics, membership: state.membership)

        return self.ready(state: state)
    }

    /// Convenience function for directly handling down command in shell.
    /// Attempts to locate which member to down and delegates further.
    func onDownCommand(_ context: _ActorContext<Message>, state: ClusterShellState, member memberToDown: Cluster.Member) -> ClusterShellState {
        var state = state

        guard let change = state.membership.applyMembershipChange(.init(member: memberToDown, toStatus: .down)) else {
            // the change was ineffective, e.g. the node was already replaced by another node and down events were already sent
            return state
        }

        // the change was applied, so we should update the membership and publish an event
        context.system.cluster.updateMembershipSnapshot(state.membership)
        self.publish(.membershipChange(change))
        self.tryConfirmDeadToSWIM(context, state, change: change)

        if let logChangeLevel = state.settings.logMembershipChanges {
            context.log.log(level: logChangeLevel, "Cluster membership change: \(reflecting: change)", metadata: [
                "cluster/membership/change": "\(change)",
                "cluster/membership": Logger.MetadataValue.array(state.membership.members(atMost: .down).map { "\($0)" }),
            ])
        }

        // whenever we down a node we must ensure to confirm it to swim, so it won't keep monitoring it forever needlessly
        self._swimShell?.confirmDead(node: memberToDown.node)

        if memberToDown.node == state.selfNode {
            // ==== ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
            // Down(self node); ensuring SWIM knows about this and should likely initiate graceful shutdown
            context.log.warning(
                "Self node was marked [.down]!",
                metadata: [ // TODO: carry reason why -- was it gossip, manual or other?
                    "cluster/membership": "\(state.membership)",
                ]
            )

            do {
                let onDownAction = context.system.settings.onDownAction.make()
                try onDownAction(context.system) // TODO: return a future and run with a timeout
            } catch {
                context.system.log.error("Failed to executed onDownAction! Shutting down system forcefully!", metadata: ["error": "\(error)"])
                do {
                    try context.system.shutdown()
                } catch {
                    context.system.log.error("Failed shutting down actor system!", metadata: ["error": "\(error)"])
                }
            }

            state = self.interpretLeaderActions(context.system, state, state.collectLeaderActions())
            return state
        } else {
            // ==== ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
            // Terminate association and Down the (other) node

            state = self.interpretLeaderActions(context.system, state, state.collectLeaderActions())
            self.terminateAssociation(context.system, state: &state, memberToDown.node)
            return state
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ClusterShell's actor address

extension ActorID {
    static func _clusterShell(on node: Cluster.Node) -> ActorID {
        let id = ActorPath._clusterShell.makeRemoteID(on: node, incarnation: .wellKnown)
        // id.metadata.wellKnown = "$cluster"
        return id
    }

    static func _clusterGossip(on node: Cluster.Node) -> ActorID {
        let id = ActorPath._clusterGossip.makeRemoteID(on: node, incarnation: .wellKnown)
        // id.metadata.wellKnown = "$gossip"
        return id
    }
}

extension ActorPath {
    static let _clusterShell: ActorPath = try! ActorPath._system.appendingKnownUnique(ClusterShell.naming)

    static let _clusterGossip: ActorPath = try! ActorPath._clusterShell.appending("gossip")
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster Metrics recording

extension ClusterShell {
    func recordMetrics(_ metrics: ClusterSystemMetrics, membership: Cluster.Membership) {
        metrics.recordMembership(membership)
        self._associationsLock.withLockVoid {
            metrics._cluster_association_tombstones.record(self._associationTombstones.count)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Errors

/// Connection errors should result in Disassociating with the offending system.
enum ActorsProtocolError: Error {
    case illegalHandshake(reason: Error)
}
