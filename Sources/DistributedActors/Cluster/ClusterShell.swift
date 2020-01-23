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

/// Cluster namespace.
public struct Cluster {}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Internal Shell responsible for all clustering (i.e. connection management) state.

/// The cluster shell "drives" all internal state machines of the cluster subsystem.
///
/// It is responsible for managing the underlying (re-)connections by extending and accepting/rejecting handshakes,
/// as well as orchestrating any high-level membership changes, e.g. by interacting with a failure detector and other gossip mechanisms.
///
/// It keeps the `Membership` instance that can be seen the source of truth for any membership based decisions.
internal class ClusterShell {
    internal static let naming = ActorNaming.unique("cluster")
    public typealias Ref = ActorRef<ClusterShell.Message>

    // ~~~~~~ HERE BE DRAGONS, shared concurrently modified concurrent state ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    // We do this to avoid "looping" any initial access of an actor ref through the cluster shell's mailbox
    // which would cause more latency to obtaining the association. refs cache the remote control once they have obtained it.

    private let _associationsLock: Lock
    /// Used by remote actor refs to obtain associations
    /// - Protected by: `_associationsLock`
    private var _associationsRegistry: [UniqueNode: AssociationRemoteControl]
    /// Tombstoned nodes are kept here in order to avoid attempting to associate if we get a reference to such node,
    /// which would normally trigger an `ensureAssociated`.
    /// - Protected by: `_associationsLock`
    private var _associationTombstones: Set<Association.TombstoneState>

    private var _swimRef: SWIM.Ref?

    private var clusterEvents: EventStream<Cluster.Event>!

    // `_serializationPool` is only used when `start()` is invoked, and there it is set immediately as well
    // any earlier access to the pool is a bug (in our library) and must be treated as such.
    private var _serializationPool: SerializationPool?
    internal var serializationPool: SerializationPool {
        guard let pool = self._serializationPool else {
            fatalError("BUG! Tried to access serializationPool on \(self) and it was nil! Please report this on the issue tracker.")
        }
        return pool
    }

    /// MUST be called while holding `_associationsLock`.
    internal func _associationHasTombstone(node: UniqueNode) -> Bool {
        self._associationTombstones.contains(.init(remoteNode: node))
    }

    /// Safe to concurrently access by privileged internals directly
    internal func associationRemoteControl(with node: UniqueNode) -> AssociationRemoteControlState {
        self._associationsLock.withLock {
            guard !self._associationHasTombstone(node: node) else {
                return .tombstone
            }
            guard let association = self._associationsRegistry[node] else {
                return .unknown
            }
            return .associated(association)
        }
    }

    enum AssociationRemoteControlState {
        case unknown
        case associated(AssociationRemoteControl)
        case tombstone
    }

    /// Terminate an association including its connection, and store a tombstone for it
    internal func terminateAssociation(_ system: ActorSystem, state: ClusterShellState, _ associated: Association.AssociatedState) -> ClusterShellState {
        traceLog_Remote(system.cluster.node, "Terminate association [\(associated.remoteNode)]")
        var state = state

        if let directive = state.removeAssociation(system, associatedNode: associated.remoteNode) {
            return self.finishTerminateAssociation(system, state: state, removalDirective: directive)
        } else {
            // no association to remove, thus nothing to act on
            return state
        }
    }

    /// Performs all cleanups related to terminating an association:
    /// - cleans the Shell local Association cache
    /// - sets a tombstone for the now-tombstoned UniqueNode
    /// - ensures node is at least .down in the Membership
    ///
    /// Can be invoked as result of a direct .down being issued, or because of a node replacement happening.
    internal func finishTerminateAssociation(_ system: ActorSystem, state: ClusterShellState, removalDirective: ClusterShellState.RemoveAssociationDirective) -> ClusterShellState {
        traceLog_Remote(system.cluster.node, "Finish terminate association [\(removalDirective.tombstone.remoteNode)]")
        var state = state

        let remoteNode = removalDirective.tombstone.remoteNode

        // tombstone the association in the shell immediately.
        // No more message sends to the system will be possible.
        self._associationsLock.withLockVoid {
            traceLog_Remote(system.cluster.node, "Finish terminate association [\(remoteNode)]: Stored tombstone")
            self._associationsRegistry.removeValue(forKey: remoteNode)
            self._associationTombstones.insert(removalDirective.tombstone)
        }

        // if the association was removed, we need to close it and ensure that other layers are synced up with this decision
        guard let removedAssociation = removalDirective.removedAssociation else {
            return state
        }

        // notify the failure detector, that we shall assume this node as dead from here on.
        // it's gossip will also propagate the information through the cluster
        traceLog_Remote(system.cluster.node, "Finish terminate association [\(remoteNode)]: Notifying SWIM, .confirmDead")
        self._swimRef?.tell(.local(.confirmDead(remoteNode)))

        // Ensure to remove (completely) the member from the Membership, it is not even .leaving anymore.
        if state.membership.mark(remoteNode, as: .down) == nil {
            // it was already removed, nothing to do
            state.log.trace("Finish association with \(remoteNode), yet node not in membership already?")
        } // else: Note that we CANNOT remove() just yet, as we only want to do this when all nodes have seen the down/leaving

        let remoteControl = removedAssociation.makeRemoteControl()
        ClusterShell.shootTheOtherNodeAndCloseConnection(system: system, targetNodeRemoteControl: remoteControl)

        return state
    }

    /// Final action performed when severing ties with another node.
    /// We "Shoot The Other Node ..." (STONITH) in order to let it know as soon as possible (i.e. directly, without waiting for gossip to reach it).
    ///
    /// This is a best-effort message; as we may be downing it because we cannot communicate with it after all, in such situation (and many others)
    /// the other node would never receive this direct kill/down eager "gossip." We hope it will either receive the down via some means, or determine
    /// by itself that it should down itself.
    internal static func shootTheOtherNodeAndCloseConnection(system: ActorSystem, targetNodeRemoteControl: AssociationRemoteControl) {
        let log = system.log
        let remoteNode = targetNodeRemoteControl.remoteNode
        traceLog_Remote(system.cluster.node, "Finish terminate association [\(remoteNode)]: Shooting the other node a direct .gossip to down itself")

        // On purpose use the "raw" RemoteControl to send the message -- this way we avoid the association lookup (it may already be removed),
        // and directly hit the channel. It is also guaranteed that the message is flushed() before we close it in the next line.
        let shootTheOtherNodePromise = system._eventLoopGroup.next().makePromise(of: Void.self)

        let ripMessage = Envelope(payload: .message(ClusterShell.Message.inbound(.restInPeace(remoteNode, from: system.cluster.node))))
        targetNodeRemoteControl.sendUserMessage(
            type: ClusterShell.Message.self,
            envelope: ripMessage,
            recipient: ._clusterShell(on: remoteNode),
            promise: shootTheOtherNodePromise
        )

        let shootTheNodeWriteTimeout: NIO.TimeAmount = .seconds(10) // FIXME: hardcoded last write timeout...
        system._eventLoopGroup.next().scheduleTask(deadline: NIODeadline.now() + shootTheNodeWriteTimeout) {
            shootTheOtherNodePromise.fail(TimeoutError(message: "Timed out writing final STONITH to \(remoteNode), should close forcefully.", timeout: .seconds(10))) // FIXME: same timeout but diff type
        }

        shootTheOtherNodePromise.futureResult.flatMap { _ in
            // Only after the write has completed, we close the channel
            targetNodeRemoteControl.closeChannel()
        }.whenComplete { reason in
            log.trace("Closed connection with \(remoteNode): \(reason)")
        }
    }

    /// Safe to concurrently access by privileged internals.
    internal var associationRemoteControls: [AssociationRemoteControl] {
        self._associationsLock.withLock {
            [AssociationRemoteControl](self._associationsRegistry.values)
        }
    }

    /// To be invoked by cluster shell whenever an association is made;
    /// The cache is used by remote actor refs to obtain means of sending messages into the pipeline,
    /// without having to queue through the cluster shell's mailbox.
    private func cacheAssociationRemoteControl(_ associationState: Association.AssociatedState) {
        self._associationsLock.withLockVoid {
            // TODO: or association ID rather than the remote id?
            self._associationsRegistry[associationState.remoteNode] = associationState.makeRemoteControl()
        }
    }

    // ~~~~~~ END OF HERE BE DRAGONS, shared concurrently modified concurrent state ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Cluster Shell, reference used for issuing commands to the cluster

    private var _ref: ClusterShell.Ref?
    var ref: ClusterShell.Ref {
        // since this is initiated during system startup, nil should never happen
        // TODO: slap locks around it...
        guard let it = self._ref else {
            return fatalErrorBacktrace("Accessing ClusterShell.ref failed, was nil! This should never happen as access should only happen after start() was invoked.")
        }
        return it
    }

    init() {
        self._associationsLock = Lock()
        self._associationsRegistry = [:]
        self._associationTombstones = []

        // not enjoying this dance, but this way we can share the ClusterShell as the shell AND the container for the ref.
        // the single thing in the class it will modify is the associations registry, which we do to avoid actor queues when
        // remote refs need to obtain those
        //
        // FIXME: see if we can restructure this to avoid these nil/then-set dance
        self._ref = nil
    }

    /// Actually starts the shell which kicks off binding to a port, and all further cluster work
    internal func start(system: ActorSystem, clusterEvents: EventStream<Cluster.Event>) throws -> LazyStart<Message> {
        self._serializationPool = try SerializationPool(settings: .default, serialization: system.serialization)
        self.clusterEvents = clusterEvents

        // TODO: concurrency... lock the ref as others may read it?
        let delayed = try system._prepareSystemActor(
            ClusterShell.naming,
            self.bind(),
            props: self.props
        )

        self._ref = delayed.ref

        return delayed
    }

    // Due to lack of Union Types, we have to emulate them
    enum Message: NoSerializationVerification {
        // The external API, exposed to users of the ClusterShell
        case command(CommandMessage)
        // The external API, exposed to users of the ClusterShell to query for state
        case query(QueryMessage)
        /// Messages internally driving the state machines; timeouts, network inbound events etc.
        case inbound(InboundMessage)
        /// Used to request making a change to the membership owned by the ClusterShell;
        /// Issued by downing or leader election and similar facilities. Thanks to centralizing the application of changes,
        /// we can ensure that a `Cluster.Event` is signalled only once, and only when it is really needed.
        /// E.g. signalling a down twice for whatever reason, needs not be notified two times to all subscribers of cluster events.
        ///
        /// If the passed in event applied to the current membership is an effective change, the change will be published using the `system.cluster.events`.
        case requestMembershipChange(Cluster.Event) // TODO: make a command
        /// Gossiping is handled by /system/cluster/gossip, however acting on it still is our task,
        /// thus the gossiper forwards gossip whenever interesting things happen ("more up to date gossip")
        /// to the shell, using this message, so we may act on it -- e.g. perform leader actions or change membership that we store.
        case gossipFromGossiper(Cluster.Gossip)
    }

    // this is basically our API internally for this system
    enum CommandMessage: NoSerializationVerification, SilentDeadLetter {
        /// Initiate the joining procedure for the given `Node`, this will result in attempting a handshake,
        /// as well as notifying the underlying failure detector (e.g. SWIM) about the node once shook hands with it.
        case initJoin(Node)

        /// Connect and handshake with remote `Node`, obtaining an `UniqueNode` in the process.
        /// Once the handshake is completed, reply to `replyTo` with the handshake result, and also mark the unique node as `.joining`.
        case handshakeWith(Node, replyTo: ActorRef<HandshakeResult>?)
        case retryHandshake(HandshakeStateMachine.InitiatedState)

        case failureDetectorReachabilityChanged(UniqueNode, Cluster.MemberReachability)

        /// Used to signal a "down was issued" either by the user, or another part of the system.
        case downCommand(Node)
        /// Used to signal a "down was issued" either by the user, or another part of the system.
        case downCommandMember(Cluster.Member)

        case shutdown(BlockingReceptacle<Void>) // TODO: could be NIO future
    }

    enum QueryMessage: NoSerializationVerification {
        case associatedNodes(ActorRef<Set<UniqueNode>>) // TODO: better type here
        case currentMembership(ActorRef<Cluster.Membership>)
    }

    internal enum InboundMessage {
        case handshakeOffer(Wire.HandshakeOffer, channel: Channel, replyTo: EventLoopPromise<Wire.HandshakeResponse>)
        case handshakeAccepted(Wire.HandshakeAccept, channel: Channel)
        case handshakeRejected(Wire.HandshakeReject)
        case handshakeFailed(Node, Error) // TODO: remove?
        /// This message is used to avoid "zombie nodes" which are known as .down by other nodes, but still stay online.
        /// It is sent as a best-effort by any node which terminates the connection with this node, e.g. if it knows already
        /// about this node being `.down` yet it still somehow attempts to communicate with the another node.
        ///
        /// Upon receipt, should be interpreted as having to immediately down myself.
        case restInPeace(UniqueNode, from: UniqueNode)
    }

    // TODO: reformulate as Wire.accept / reject?
    internal enum HandshakeResult: Equatable {
        case success(UniqueNode)
        case failure(HandshakeConnectionError)
    }

    struct HandshakeConnectionError: Error, Equatable { // TODO: merge with HandshakeError?
        let node: Node
        let message: String
    }

    private var behavior: Behavior<Message> {
        self.bind()
    }

    private let props: Props =
        Props()
        .supervision(strategy: .escalate) // always escalate failures, if this actor fails we're in big trouble -> terminate the system
        ._asWellKnown
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster Bootstrap / Binding

extension ClusterShell {
    /// Binds on setup to the configured address (as configured in `system.settings.cluster`).
    ///
    /// Once bound proceeds to `ready` state, where it remains to accept or initiate new handshakes.
    private func bind() -> Behavior<Message> {
        return .setup { context in
            let clusterSettings = context.system.settings.cluster
            let uniqueBindAddress = clusterSettings.uniqueBindNode

            // SWIM failure detector and gossiping
            if !clusterSettings.swim.disabled {
                let swimBehavior = SWIMShell(settings: clusterSettings.swim, clusterRef: context.myself).behavior
                self._swimRef = try context._downcastUnsafe._spawn(SWIMShell.naming, props: ._wellKnown, swimBehavior)
            } else {
                context.log.warning("""
                SWIM Failure Detector has been [disabled]! \
                Reachability events will NOT be emitted, meaning that most downing strategies will not be able to perform \
                their duties. Please ensure that an external mechanism for detecting failed cluster nodes is used.
                """)
                self._swimRef = nil
            }

            // automatic leader election, so it may move members: .joining -> .up (and other `LeaderAction`s)
            if let leaderElection = context.system.settings.cluster.autoLeaderElection.make(context.system.cluster.settings) {
                let leadershipShell = Leadership.Shell(leaderElection)
                _ = try context.spawn(Leadership.Shell.naming, leadershipShell.behavior)
            }

            // .down decisions made by:
            if let downing = clusterSettings.downingStrategy.make(context.system.cluster.settings) {
                let shell = DowningStrategyShell(downing)
                _ = try context.spawn(shell.naming, shell.behavior)
            }

            // FIXME: all the ordering dance with creating of state and the address...
            context.log.info("Binding to: [\(uniqueBindAddress)]")

            let chanElf = self.bootstrapServerSide(
                system: context.system,
                shell: context.myself,
                bindAddress: uniqueBindAddress,
                settings: clusterSettings,
                serializationPool: self.serializationPool
            )

            return context.awaitResultThrowing(of: chanElf, timeout: clusterSettings.bindTimeout) { (chan: Channel) in
                context.log.info("Bound to \(chan.localAddress.map { $0.description } ?? "<no-local-address>")")

                let gossipControl = try ConvergentGossip.start(
                    context, name: "\(ActorAddress._clusterGossip.name)", of: Cluster.Gossip.self,
                    notifyOnGossipRef: context.messageAdapter(from: Cluster.Gossip.self) { Optional.some(Message.gossipFromGossiper($0)) },
                    props: ._wellKnown
                )

                let state = ClusterShellState(
                    settings: clusterSettings,
                    channel: chan,
                    events: self.clusterEvents,
                    gossipControl: gossipControl,
                    log: context.log
                )

                // loop through "self" cluster shell, which in result causes notifying all subscribers about cluster membership change
                var firstGossip = Cluster.Gossip(ownerNode: state.myselfNode)
                _ = firstGossip.membership.join(state.myselfNode) // change will be put into effect by receiving the "self gossip"
                firstGossip.incrementOwnerVersion()
                context.myself.tell(.gossipFromGossiper(firstGossip))
                // TODO: are we ok if we received another gossip first, not our own initial? should be just fine IMHO

                return self.ready(state: state)
            }
        }
    }

    /// Ready and interpreting commands and incoming messages.
    ///
    /// Serves as main "driver" for handshake and association state machines.
    private func ready(state: ClusterShellState) -> Behavior<Message> {
        func receiveShellCommand(_ context: ActorContext<Message>, command: CommandMessage) -> Behavior<Message> {
            state.tracelog(.inbound, message: command)

            switch command {
            case .initJoin(let node):
                return self.onInitJoin(context, state: state, joining: node)

            case .handshakeWith(let node, let replyTo):
                return self.beginHandshake(context, state, with: node, replyTo: replyTo)
            case .retryHandshake(let initiated):
                return self.connectSendHandshakeOffer(context, state, initiated: initiated)

            case .failureDetectorReachabilityChanged(let node, let reachability):
                guard let member = state.membership.uniqueMember(node) else {
                    return .same // reachability change of unknown node
                }
                switch reachability {
                case .reachable:
                    return self.onReachabilityChange(context, state: state, change: Cluster.ReachabilityChange(member: member.asReachable))
                case .unreachable:
                    return self.onReachabilityChange(context, state: state, change: Cluster.ReachabilityChange(member: member.asUnreachable))
                }

            case .shutdown(let receptacle):
                return self.onShutdownCommand(context, state: state, signalOnceUnbound: receptacle)

            case .downCommand(let node):
                if let member = state.membership.member(node) {
                    return self.ready(state: self.onDownCommand(context, state: state, member: member))
                } else {
                    return self.ready(state: state)
                }
            case .downCommandMember(let member):
                return self.ready(state: self.onDownCommand(context, state: state, member: member))
            }
        }

        func receiveQuery(_ context: ActorContext<Message>, query: QueryMessage) -> Behavior<Message> {
            state.tracelog(.inbound, message: query)

            switch query {
            case .associatedNodes(let replyTo):
                replyTo.tell(state.associatedNodes()) // TODO: we'll want to put this into some nicer message wrapper?
                return .same
            case .currentMembership(let replyTo):
                replyTo.tell(state.membership)
                return .same
            }
        }

        func receiveInbound(_ context: ActorContext<Message>, message: InboundMessage) throws -> Behavior<Message> {
            switch message {
            case .handshakeOffer(let offer, let channel, let promise):
                self.tracelog(context, .receiveUnique(from: offer.from), message: offer)
                return self.onHandshakeOffer(context, state, offer, channel: channel, replyInto: promise)

            case .handshakeAccepted(let accepted, let channel):
                self.tracelog(context, .receiveUnique(from: accepted.from), message: accepted)
                return self.onHandshakeAccepted(context, state, accepted, channel: channel)

            case .handshakeRejected(let rejected):
                self.tracelog(context, .receive(from: rejected.from), message: rejected)
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
        func receiveChangeMembershipRequest(_ context: ActorContext<Message>, event: Cluster.Event) -> Behavior<Message> {
            self.tracelog(context, .receive(from: state.myselfNode.node), message: event)
            var state = state

            let changeDirective = state.applyClusterEvent(event)
            self.interpretLeaderActions(&state, changeDirective.leaderActions)

            if case .membershipChange(let change) = event {
                self.tryIntroduceGossipPeer(context, state, change: change)
            }

            if changeDirective.applied {
                state.latestGossip.incrementOwnerVersion()
                // we only publish the event if it really caused a change in membership, to avoid echoing "the same" change many times.
                self.clusterEvents.publish(event)
            } // else no "effective change", thus we do not publish events

            return self.ready(state: state)
        }

        func receiveMembershipGossip(
            _ context: ActorContext<Message>,
            _ state: ClusterShellState,
            gossip: Cluster.Gossip
        ) -> Behavior<Message> {
            tracelog(context, .gossip(gossip), message: gossip)
            var state = state

            let beforeGossipMerge = state.latestGossip

            let mergeDirective = state.latestGossip.mergeForward(incoming: gossip) // mutates the gossip
            context.log.trace("Local membership version is [.\(mergeDirective.causalRelation)] to incoming gossip; Merge resulted in \(mergeDirective.effectiveChanges.count) changes.", metadata: [
                "tag": "membership",
                "membership/changes": Logger.MetadataValue.array(mergeDirective.effectiveChanges.map { Logger.MetadataValue.stringConvertible($0) }),
                "gossip/incoming": "\(gossip)",
                "gossip/before": "\(beforeGossipMerge)",
                "gossip/now": "\(state.latestGossip)",
            ])

            mergeDirective.effectiveChanges.forEach { effectiveChange in
                // a change COULD have also been a replacement, in which case we need to publish it as well
                // the removal od the
                if let replacementChange = effectiveChange.replacementDownPreviousNodeChange {
                    self.clusterEvents.publish(.membershipChange(replacementChange))
                }
                let event: Cluster.Event = .membershipChange(effectiveChange)
                self.clusterEvents.publish(event)
            }

            let leaderActions = state.collectLeaderActions()
            if !leaderActions.isEmpty {
                state.log.trace("Leadership actions upon gossip: \(leaderActions)", metadata: [
                    "tag": "membership",
                ])
            }
            self.interpretLeaderActions(&state, leaderActions)

            return self.ready(state: state)
        }

        return .setup { context in
            .receive { context, message in
                switch message {
                case .command(let command): return receiveShellCommand(context, command: command)
                case .query(let query): return receiveQuery(context, query: query)
                case .inbound(let inbound): return try receiveInbound(context, message: inbound)
                case .requestMembershipChange(let event): return receiveChangeMembershipRequest(context, event: event)
                case .gossipFromGossiper(let gossip): return receiveMembershipGossip(context, state, gossip: gossip)
                }
            }
        }
    }

    func tryIntroduceGossipPeer(_ context: ActorContext<Message>, _ state: ClusterShellState, change: Cluster.MembershipChange, file: String = #file, line: UInt = #line) {
        guard change.toStatus < .down else {
            return
        }
        guard change.member.node != state.myselfNode else {
            return
        }
        // TODO: make it cleaner? though we decided to go with manual peer management as the ClusterShell owns it, hm

        // TODO: consider receptionist instead of this; we're "early" but receptionist could already be spreading its info to this node, since we associated.
        let gossipPeer: ConvergentGossip<Cluster.Gossip>.Ref = context.system._resolve(
            context: .init(address: ._clusterGossip(on: change.member.node), system: context.system)
        )
        // FIXME: make sure that if the peer terminated, we don't add it again in here, receptionist would be better then to power this...
        // today it can happen that a node goes down but we dont know yet so we add it again :O
        state.gossipControl.introduce(peer: gossipPeer)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Handshake init

extension ClusterShell {
    /// Initiate a handshake to the `remoteNode`.
    /// Upon successful handshake, the `replyTo` actor shall be notified with its result, as well as the handshaked-with node shall be marked as `.joining`.
    ///
    /// Handshakes are currently not performed concurrently but one by one.
    internal func beginHandshake(_ context: ActorContext<Message>, _ state: ClusterShellState, with remoteNode: Node, replyTo: ActorRef<HandshakeResult>?) -> Behavior<Message> {
        var state = state

        guard remoteNode != state.myselfNode.node else {
            state.log.debug("Ignoring attempt to handshake with myself; Could have been issued as confused attempt to handshake as induced by discovery via gossip?")
            replyTo?.tell(.failure(.init(node: remoteNode, message: "Would have attempted handshake with self node, aborted handshake.")))
            return .same // TODO: could be drop
        }

        if let existingAssociation = state.association(with: remoteNode) {
            state.log.debug("Attempted associating with already associated node: \(reflecting: remoteNode), existing association: [\(existingAssociation)]")
            switch existingAssociation {
            case .associated(let associationState):
                replyTo?.tell(.success(associationState.remoteNode))
            case .tombstone:
                replyTo?.tell(.failure(HandshakeConnectionError(node: remoteNode, message: "Existing association for \(remoteNode) is already a tombstone! Must not complete association.")))
            }
            return .same // TODO: could be drop
        }

        let whenHandshakeComplete = state.eventLoopGroup.next().makePromise(of: Wire.HandshakeResponse.self)
        whenHandshakeComplete.futureResult.whenComplete { result in
            switch result {
            case .success(.accept(let accept)):
                /// we need to switch here, since we MAY have been attached to an ongoing handshake which may have been initiated
                /// in either direction // TODO check if this is really needed.
                let associatedRemoteNode: UniqueNode
                if accept.from.node == remoteNode {
                    associatedRemoteNode = accept.from
                } else {
                    associatedRemoteNode = accept.origin
                }
                replyTo?.tell(.success(associatedRemoteNode))
            case .success(.reject(let reject)):
                replyTo?.tell(.failure(HandshakeConnectionError(node: remoteNode, message: reject.reason)))
            case .failure(let error):
                replyTo?.tell(HandshakeResult.failure(.init(node: remoteNode, message: "\(error)")))
            }
        }

        let handshakeState = state.registerHandshake(with: remoteNode, whenCompleted: whenHandshakeComplete)
        // we MUST register the intention of shaking hands with remoteAddress before obtaining the connection,
        // in order to let the fsm handle any retry decisions in face of connection failures et al.

        switch handshakeState {
        case .initiated(let initiated):
            return self.connectSendHandshakeOffer(context, state, initiated: initiated)

        case .wasOfferedHandshake, .inFlight, .completed:
            // the reply will be handled already by the future.whenComplete we've set up above here
            // so nothing to do here, just become the next state
            return self.ready(state: state)
        }
    }

    func connectSendHandshakeOffer(_ context: ActorContext<Message>, _ state: ClusterShellState, initiated: HandshakeStateMachine.InitiatedState) -> Behavior<Message> {
        var state = state

        state.log.info("Extending handshake offer to \(initiated.remoteNode))") // TODO: log retry stats?
        let offer: Wire.HandshakeOffer = initiated.makeOffer()
        self.tracelog(context, .send(to: initiated.remoteNode), message: offer)

        let outboundChanElf: EventLoopFuture<Channel> = self.bootstrapClientSide(
            system: context.system,
            shell: context.myself,
            targetNode: initiated.remoteNode,
            handshakeOffer: offer,
            settings: state.settings,
            serializationPool: self.serializationPool
        )

        // the timeout is being handled by the `connectTimeout` socket option
        // in NIO, so it is safe to use an infinite timeout here
        return context.awaitResult(of: outboundChanElf, timeout: .effectivelyInfinite) { result in
            switch result {
            case .success(let chan):
                return self.ready(state: state.onHandshakeChannelConnected(initiated: initiated, channel: chan))

            case .failure(let error):
                return self.onOutboundConnectionError(context, state, with: initiated.remoteNode, error: error)
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Incoming Handshake

extension ClusterShell {
    /// Initial entry point for accepting a new connection; Potentially allocates new handshake state machine.
    internal func onHandshakeOffer(
        _ context: ActorContext<Message>, _ state: ClusterShellState,
        _ offer: Wire.HandshakeOffer, channel: Channel, replyInto promise: EventLoopPromise<Wire.HandshakeResponse>
    ) -> Behavior<Message> {
        var state = state

        switch state.onIncomingHandshakeOffer(offer: offer) {
        case .negotiate(let hsm):
            // handshake is allowed to proceed
            switch hsm.negotiate() {
            case .acceptAndAssociate(let completedHandshake):
                state.log.info("Accept association with \(reflecting: offer.from)!")

                // create and store association
                let directive = state.associate(context.system, completedHandshake, channel: channel)
                let association = directive.association
                self.cacheAssociationRemoteControl(association)

                // send accept to other node
                let accept = completedHandshake.makeAccept()
                self.tracelog(context, .send(to: offer.from.node), message: accept)
                promise.succeed(.accept(accept))

                if directive.membershipChange.replaced != nil,
                    let removalDirective = directive.beingReplacedAssociationToTerminate {
                    state.log.warning("Tombstone association: \(reflecting: removalDirective.tombstone.remoteNode)")
                    state = self.finishTerminateAssociation(context.system, state: state, removalDirective: removalDirective)
                }

                // TODO: try to pull off with receptionist the same dance
                self.tryIntroduceGossipPeer(context, state, change: directive.membershipChange)

                /// a new node joined, thus if we are the leader, we should perform leader tasks to potentially move it to .up
                let actions = state.collectLeaderActions()
                self.interpretLeaderActions(&state, actions)

                /// only after leader (us, if we are one) performed its tasks, we update the metrics on membership (it might have modified membership)
                self.recordMetrics(context.system.metrics, membership: state.membership)

                return self.ready(state: state)

            case .rejectHandshake(let rejectedHandshake):
                state.log.warning("Rejecting handshake from \(offer.from), error: [\(rejectedHandshake.error)]:\(type(of: rejectedHandshake.error))")

                // note that we should NOT abort the channel here since we still want to send back the rejection.

                let reject: Wire.HandshakeReject = rejectedHandshake.makeReject()
                self.tracelog(context, .send(to: offer.from.node), message: reject)
                promise.succeed(.reject(reject))

                return self.ready(state: state)
            }
        case .abortDueToConcurrentHandshake:
            // concurrent handshake and we should abort
            let error = HandshakeConnectionError(
                node: offer.from.node,
                message: """
                Terminating this connection, as there is a concurrently established connection with same host [\(offer.from)] \
                which will be used to complete the handshake.
                """
            )
            state.abortIncomingHandshake(offer: offer, channel: channel)
            promise.fail(error)
            return .same
        }
    }

    internal func interpretLeaderActions(_ state: inout ClusterShellState, _ leaderActions: [ClusterShellState.LeaderAction], file: String = #file, line: UInt = #line) {
        guard !leaderActions.isEmpty else {
            return
        }

        state.log.trace("Performing leader actions: \(leaderActions)")

        for leaderAction in leaderActions {
            switch leaderAction {
            case .moveMember(let movingUp):
                if let change = state.membership.apply(movingUp) {
                    state.log.info("Leader moving member: \(change)", metadata: [
                        "tag": "leader-action",
                        "leader/interpret/location": "\(file):\(line)",
                    ])
                    if let downReplacedNodeChange = change.replacementDownPreviousNodeChange {
                        state.log.info("Downing replaced member: \(change)", metadata: [
                            "tag": "leader-action",
                            "leader/interpret/location": "\(file):\(line)",
                        ])
                        state.events.publish(.membershipChange(downReplacedNodeChange))
                    }
                    state.events.publish(.membershipChange(change))
                }

            case .removeMember(let memberToRemove):
                state.log.info("Leader removing member: \(memberToRemove), all nodes are certain to have seen it as [.down] before", metadata: [
                    "tag": "leader-action",
                    "leader/interpretation/position": "\(file):\(line)",
                    "gossip/current": "\(state.latestGossip)",
                ])

                // !!! IMPORTANT !!!
                // We MUST perform the prune on the _latestGossip, not the wrapper,
                // as otherwise the wrapper enforces "vector time moves forward"
                if let removalChange = state._latestGossip.pruneMember(memberToRemove) {
                    // TODO: do we need terminate association here? or was it done already
                    state._latestGossip.incrementOwnerVersion()
                    state.gossipControl.update(payload: state._latestGossip)
                    // TODO: automate emote so we dont miss the update, make it funcs when we update things?

                    // TODO: will this "just work" as we removed from membership, so gossip will tell others...?
                    // or do we need to push a round of gossip with .removed anyway?
                    state.events.publish(.membershipChange(removalChange))
                }
            }
        }

        state.log.trace("Membership state after leader actions: \(state.membership)")
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Failures to obtain connections

extension ClusterShell {
    func onOutboundConnectionError(_ context: ActorContext<Message>, _ state: ClusterShellState, with remoteNode: Node, error: Error) -> Behavior<Message> {
        var state = state
        state.log.warning("Failed await for outbound channel to \(remoteNode); Error was: \(error)")

        guard let handshakeState = state.handshakeInProgress(with: remoteNode) else {
            state.log.warning("Connection error for handshake which is not in progress, this should not happen, but is harmless.") // TODO: meh or fail hard
            return .same
        }

        switch handshakeState {
        case .initiated(var initiated):
            switch initiated.onHandshakeError(error) {
            case .scheduleRetryHandshake(let delay):
                state.log.debug("Schedule handshake retry to: [\(initiated.remoteNode)] delay: [\(delay)]")
                context.timers.startSingle(
                    key: TimerKey("handshake-timer-\(remoteNode)"),
                    message: .command(.retryHandshake(initiated)),
                    delay: delay
                )
            case .giveUpOnHandshake:
                if let hsmState = state.abortOutgoingHandshake(with: remoteNode) {
                    self.notifyHandshakeFailure(state: hsmState, node: remoteNode, error: error)
                }
            }

        case .wasOfferedHandshake(let state):
            preconditionFailure("Outbound connection error should never happen on receiving end. State was: [\(state)], error was: \(error)")
        case .completed(let state):
            preconditionFailure("Outbound connection error on already completed state handshake. This should not happen. State was: [\(state)], error was: \(error)")
        case .inFlight:
            preconditionFailure("An in-flight marker state should never be stored, yet was encountered in \(#function)")
        }

        return self.ready(state: state)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Incoming Handshake Replies

extension ClusterShell {
    private func onHandshakeAccepted(_ context: ActorContext<Message>, _ state: ClusterShellState, _ accept: Wire.HandshakeAccept, channel: Channel) -> Behavior<Message> {
        var state = state // local copy for mutation

        guard let completed = state.incomingHandshakeAccept(accept) else {
            if state.associatedNodes().contains(accept.from) {
                // this seems to be a re-delivered accept, we already accepted association with this node.
                return .same

                // TODO: check tombstones as well
            } else {
                state.log.error("Illegal handshake accept received. No handshake was in progress with \(accept.from)") // TODO: tests and think this through more
                return .same
            }
        }

        let directive = state.associate(context.system, completed, channel: channel)
        self.cacheAssociationRemoteControl(directive.association)
        state.log.debug("Associated with: \(reflecting: completed.remoteNode); Membership change: \(directive.membershipChange), resulting in: \(state.membership)")

        self.tryIntroduceGossipPeer(context, state, change: directive.membershipChange)

        // by emitting these `change`s, we not only let anyone interested know about this,
        // but we also enable the shell (or leadership) to update the leader if it needs changing.
        if directive.membershipChange.replaced != nil,
            let replacedNodeRemovalDirective = directive.beingReplacedAssociationToTerminate {
            state.log.warning("Tombstone association: \(reflecting: replacedNodeRemovalDirective.tombstone.remoteNode)")
            // MUST be finishTerminate... and not terminate... because if we started a full terminateAssociation here
            // we would terminate the _current_ association which was already removed by the associate() because
            // it already _replaced_ some existing association (held in beingReplacedAssociation)
            state = self.finishTerminateAssociation(context.system, state: state, removalDirective: replacedNodeRemovalDirective)
        }

        /// a new node joined, thus if we are the leader, we should perform leader tasks to potentially move it to .up
        let actions = state.collectLeaderActions()
        self.interpretLeaderActions(&state, actions)

        // TODO: return self.changedMembership which can do the publishing and publishing of metrics? we do it now in two places separately (incoming/outgoing accept)
        /// only after leader (us, if we are one) performed its tasks, we update the metrics on membership (it might have modified membership)
        self.recordMetrics(context.system.metrics, membership: state.membership)

        completed.whenCompleted?.succeed(.accept(completed.makeAccept()))
        return self.ready(state: state)
    }

    private func onHandshakeRejected(_ context: ActorContext<Message>, _ state: ClusterShellState, _ reject: Wire.HandshakeReject) -> Behavior<Message> {
        var state = state

        state.log.error("Handshake was rejected by: [\(reject.from)], reason: [\(reject.reason)]")

        // TODO: back off intensely, give up after some attempts?

        if let hsmState = state.abortOutgoingHandshake(with: reject.from) {
            self.notifyHandshakeFailure(state: hsmState, node: reject.from, error: HandshakeConnectionError(node: reject.from, message: reject.reason))
        }

        self.recordMetrics(context.system.metrics, membership: state.membership)
        return self.ready(state: state)
    }

    private func onHandshakeFailed(_ context: ActorContext<Message>, _ state: ClusterShellState, with node: Node, error: Error) -> Behavior<Message> {
        var state = state

        state.log.error("Handshake error while connecting [\(node)]: \(error)")
        if let hsmState = state.abortOutgoingHandshake(with: node) {
            self.notifyHandshakeFailure(state: hsmState, node: node, error: error)
        }

        self.recordMetrics(context.system.metrics, membership: state.membership)
        return self.ready(state: state)
    }

    private func onRestInPeace(_ context: ActorContext<Message>, _ state: ClusterShellState, intendedNode: UniqueNode, fromNode: UniqueNode) -> Behavior<Message> {
        let myselfNode = state.myselfNode

        guard myselfNode == myselfNode else {
            state.log.warning("Received stray .restInPeace message! Was intended for \(reflecting: intendedNode), ignoring.", metadata: [
                "cluster/node": "\(String(reflecting: myselfNode))",
                "sender/node": "\(String(reflecting: fromNode))",
            ])
            return .same
        }
        guard !context.system.isShuttingDown else {
            // we are already shutting down thus other nodes declaring us as down is expected
            state.log.trace("Already shutting down, received .restInPeace from [\(fromNode)], this is expected, other nodes may sever their connections with this node while we terminate.", metadata: [
                "sender/node": "\(String(reflecting: fromNode))",
            ])
            return .same
        }

        state.log.warning("Received .restInPeace from \(fromNode), meaning this node is known to be .down or worse, and should terminate. Initiating self .down-ing.", metadata: [
            "sender/node": "\(String(reflecting: fromNode))",
        ])

        guard let myselfMember = state.membership.uniqueMember(myselfNode) else {
            state.log.error("Unable to find Cluster.Member for \(myselfNode) self node! This should not happen, please file an issue.")
            return .same
        }

        return self.ready(state: self.onDownCommand(context, state: state, member: myselfMember))
    }

    private func notifyHandshakeFailure(state: HandshakeStateMachine.State, node: Node, error: Error) {
        switch state {
        case .initiated(let initiated):
            initiated.whenCompleted?.fail(HandshakeConnectionError(node: node, message: "\(error)"))
        case .wasOfferedHandshake(let offered):
            offered.whenCompleted?.fail(HandshakeConnectionError(node: node, message: "\(error)"))
        case .completed(let completed):
            completed.whenCompleted?.fail(HandshakeConnectionError(node: node, message: "\(error)"))
        case .inFlight:
            preconditionFailure("An in-flight marker state should never be stored, yet was encountered in \(#function)")
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Shutdown

extension ClusterShell {
    fileprivate func onShutdownCommand(_ context: ActorContext<Message>, state: ClusterShellState, signalOnceUnbound: BlockingReceptacle<Void>) -> Behavior<Message> {
        let addrDesc = "\(state.settings.uniqueBindNode.node.host):\(state.settings.uniqueBindNode.node.port)"
        return context.awaitResult(of: state.channel.close(), timeout: context.system.settings.cluster.unbindTimeout) {
            // FIXME: also close all associations (!!!)
            switch $0 {
            case .success:
                context.log.info("Unbound server socket [\(addrDesc)], node: \(reflecting: state.myselfNode)")
                self.serializationPool.shutdown()
                signalOnceUnbound.offerOnce(())
                return .stop
            case .failure(let err):
                context.log.warning("Failed while unbinding server socket [\(addrDesc)], node: \(reflecting: state.myselfNode). Error: \(err)")
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
    /// Ensure an association, and let SWIM know about it
    func onInitJoin(_ context: ActorContext<Message>, state _: ClusterShellState, joining node: Node) -> Behavior<Message> {
        let handshakeResultAnswer: AskResponse<HandshakeResult> = context.myself.ask(for: HandshakeResult.self, timeout: .seconds(3)) {
            Message.command(.handshakeWith(node, replyTo: $0))
        }

        context.onResultAsync(of: handshakeResultAnswer, timeout: .effectivelyInfinite) { (res: Result<HandshakeResult, Error>) in
            switch res {
            case .success(.success(let uniqueNode)):
                context.log.debug("Associated \(uniqueNode), informing SWIM to monitor this node.")
                self._swimRef?.tell(.local(.monitor(uniqueNode)))
                return .same // .same, since state was modified since inside the handshakeWith (!)
            case .success(.failure(let error)):
                context.log.debug("Handshake with \(reflecting: node) failed: \(error)")
                return .same
            case .failure(let error):
                context.log.debug("Handshake with \(reflecting: node) failed: \(error)")
                return .same
            }
        }

        return .same
    }

    func onReachabilityChange(
        _ context: ActorContext<Message>,
        state: ClusterShellState,
        change: Cluster.ReachabilityChange
    ) -> Behavior<Message> {
        var state = state

        // TODO: make sure we don't end up infinitely spamming reachability events
        if state.membership.applyReachabilityChange(change) != nil {
            self.clusterEvents.publish(.reachabilityChange(change))
            self.recordMetrics(context.system.metrics, membership: state.membership)
            return self.ready(state: state) // TODO: return membershipChanged() where we can do the publish + record in one spot
        } else {
            return .same
        }
    }

    /// Convenience function for directly handling down command in shell.
    /// Attempts to locate which member to down and delegates further.
    func onDownCommand(_ context: ActorContext<Message>, state: ClusterShellState, member memberToDown: Cluster.Member) -> ClusterShellState {
        var state = state

        if let change = state.membership.apply(.init(member: memberToDown, toStatus: .down)) {
            self.clusterEvents.publish(.membershipChange(change))

            if let logChangeLevel = state.settings.logMembershipChanges {
                context.log.log(level: logChangeLevel, "Cluster membership change: \(reflecting: change), membership: \(state.membership)")
            }
        }

        guard memberToDown.node != state.myselfNode else {
            // ==== ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
            // Down(self node); ensuring SWIM knows about this and should likely initiate graceful shutdown
            context.log.warning("Self node was marked [.down]!", metadata: [ // TODO: carry reason why -- was it gossip, manual or other
                "cluster/membership": "\(state.membership)", // TODO: introduce state.metadata pattern?
            ])

            self._swimRef?.tell(.local(.confirmDead(memberToDown.node)))

            do {
                let onDownAction = context.system.settings.cluster.onDownAction.make()
                try onDownAction(context.system) // TODO: return a future and run with a timeout
            } catch {
                context.system.log.error("Failed to executed onDownAction! Shutting down system forcefully! Error: \(error)")
                context.system.shutdown()
            }

            self.interpretLeaderActions(&state, state.collectLeaderActions())

            return state
        }

        // ==== ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
        // Down(other node);

        guard let association = state.association(with: memberToDown.node.node) else {
            context.log.warning("Received Down command for not associated node [\(reflecting: memberToDown.node.node)], ignoring.")
            self.interpretLeaderActions(&state, state.collectLeaderActions())
            return state
        }

        switch association {
        case .associated(let associated):
            state = self.terminateAssociation(context.system, state: state, associated)
            self.interpretLeaderActions(&state, state.collectLeaderActions())
            return state
        case .tombstone:
            state.log.warning("Attempted to .down already tombstoned association/node: [\(memberToDown)]")
            self.interpretLeaderActions(&state, state.collectLeaderActions())
            return state
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ClusterShell's actor address

extension ActorAddress {
    internal static let _clusterShell: ActorAddress = ActorPath._clusterShell.makeLocalAddress(incarnation: .wellKnown)
    internal static func _clusterShell(on node: UniqueNode? = nil) -> ActorAddress {
        switch node {
        case .none:
            return ._clusterShell
        case .some(let node):
            return ActorPath._clusterShell.makeRemoteAddress(on: node, incarnation: .wellKnown)
        }
    }

    internal static let _clusterGossip: ActorAddress = ActorPath._clusterGossip.makeLocalAddress(incarnation: .wellKnown)
    internal static func _clusterGossip(on node: UniqueNode? = nil) -> ActorAddress {
        switch node {
        case .none:
            return ._clusterGossip
        case .some(let node):
            return ActorPath._clusterGossip.makeRemoteAddress(on: node, incarnation: .wellKnown)
        }
    }
}

extension ActorPath {
    internal static let _clusterShell: ActorPath = try! ActorPath._system.appendingKnownUnique(ClusterShell.naming)

    internal static let _clusterGossip: ActorPath = try! ActorPath._clusterShell.appending("gossip")
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster Metrics recording

extension ClusterShell {
    func recordMetrics(_ metrics: ActorSystemMetrics, membership: Cluster.Membership) {
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
