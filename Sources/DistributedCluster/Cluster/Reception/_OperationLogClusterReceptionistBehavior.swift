//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import CoreMetrics
import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster (OpLog) Receptionist

public final class _OperationLogClusterReceptionist {
    typealias Message = Receptionist.Message
    typealias ReceptionistRef = _ActorRef<Message>

    internal let instrumentation: _ReceptionistInstrumentation

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Timer Keys

    static let slowACKReplicationTick: _TimerKey = "slow-ack-replication-tick"

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: State

    /// Stores the actual mappings of keys to actors.
    let storage = Receptionist.Storage()

    internal enum ReceptionistOp: OpLogStreamOp, Codable {
        case register(key: AnyReceptionKey, id: ActorID)
        case remove(key: AnyReceptionKey, id: ActorID)

        var key: AnyReceptionKey {
            switch self {
            case .register(let key, _): return key
            case .remove(let key, _): return key
            }
        }
    }

    /// Per known receptionist replayer instances, pointing at the latest confirmed message.
    /// Resuming a replay means getting any ops that were not yet observed by the receptionist.
    ///
    /// Replays are triggered upon receiving an `AckOps`, which simultaneously act as ACKing any previously replayed messages.
    var peerReceptionistReplayers: [_ActorRef<Message>: OpLog<ReceptionistOp>.Replayer]

    /// Local operations log; Replaying events in it results in restoring the key:actor mappings known to this actor locally.
    let ops: OpLog<ReceptionistOp>

    var membership: Cluster.Membership

    /// Important: This safeguards us from the following write amplification scenario:
    ///
    /// Since:
    /// - `AckOps` serves both as an ACK and "poll", and
    /// - `AckOps` is used to periodically spread information
    var nextPeriodicAckPermittedDeadline: [_ActorRef<Message>: ContinuousClock.Instant]

    /// Sequence numbers of op-logs that we have observed, INCLUDING our own latest op's seqNr.
    /// In other words, each receptionist has their own op-log, and we observe and store the latest seqNr we have seen from them.
    var observedSequenceNrs: VersionVector

    /// Tracks up until what SeqNr we actually have applied the operations to our `storage`.
    ///
    /// The difference between these versions at given peer and the `maxObservedSequenceNr` at given peer,
    /// gives a good idea how far "behind" we are with regards to changed performed at that peer.
    var appliedSequenceNrs: VersionVector

    internal init(settings: ReceptionistSettings, instrumentation: _ReceptionistInstrumentation = NoopReceptionistInstrumentation()) {
        self.instrumentation = instrumentation

        self.ops = .init(batchSize: settings.syncBatchSize)
        self.membership = .empty
        self.peerReceptionistReplayers = [:]

        self.observedSequenceNrs = .empty
        self.appliedSequenceNrs = .empty

        self.nextPeriodicAckPermittedDeadline = [:]
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Behavior

    var behavior: _Behavior<Message> {
        .setup { context in
            context.log.debug("Initialized receptionist")

            // === listen to cluster events ------------------
            let onClusterEventRef = context.subReceive(Cluster.Event.self) { event in
                self.onClusterEvent(context, event: event)
            }
            context.system.cluster.events.subscribe(onClusterEventRef)

            // === timers ------------------
            // periodically gossip to other receptionists with the last seqNr we've seen,
            // and if it happens to be outdated by then this will cause a push from that node.
            context.timers.startPeriodic(
                key: Self.slowACKReplicationTick,
                message: Self.PeriodicAckTick(),
                interval: context.system.settings.receptionist.ackPullReplicationIntervalSlow
            )

            // === behavior -----------
            return _Behavior<Receptionist.Message>.receiveMessage {
                self.tracelog(context, .receive, message: $0)
                switch $0 {
                case let push as PushOps:
                    self.receiveOps(context, push: push)
                case let ack as AckOps:
                    self.receiveAckOps(context, until: ack.until, by: ack.peer)

                case _ as PeriodicAckTick:
                    self.onPeriodicAckTick(context)

                case let message as _AnyRegister:
                    do {
                        try self.onRegister(context: context, message: message)
                    } catch {
                        context.log.error("Receptionist error caught: \(error)")  // TODO: simplify, but we definitely cannot escalate here
                    }

                case let message as _Lookup:
                    do {
                        try self.onLookup(context: context, message: message)  // FIXME: would terminate the receptionist!
                    } catch {
                        context.log.error("Receptionist error caught: \(error)")  // TODO: simplify, but we definitely cannot escalate here
                    }

                case let message as _Subscribe:
                    do {
                        try self.onSubscribe(context: context, message: message)  // FIXME: would terminate the receptionist!
                    } catch {
                        context.log.error("Receptionist error caught: \(error)")  // TODO: simplify, but we definitely cannot escalate here
                    }

                case let message as _ReceptionistDelayedListingFlushTick:
                    self.onDelayedListingFlushTick(context: context, message: message)

                default:
                    context.log.warning("Received unexpected message: \(String(reflecting: $0)), \(type(of: $0))")
                }
                return .same
            }.receiveSpecificSignal(_Signals.Terminated.self) { _, terminated in
                self.onTerminated(context: context, terminated: terminated)
                return .same
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Receptionist API impl

extension _OperationLogClusterReceptionist {
    private func onSubscribe(context: _ActorContext<Message>, message: _Subscribe) throws {
        let boxedMessage = message._boxed
        let anyKey = message._key
        if self.storage.addSubscription(key: anyKey, subscription: boxedMessage) {
            self.instrumentation.actorSubscribed(key: anyKey, id: message._addressableActorRef.id)

            context.watch(message._addressableActorRef)
            context.log.trace("Subscribed \(message._addressableActorRef.id) to \(anyKey)")
            boxedMessage.replyWith(self.storage.registrations(forKey: anyKey) ?? [])
        }
    }

    private func onLookup(context: _ActorContext<Message>, message: _Lookup) throws {
        let registrations = self.storage.registrations(forKey: message._key) ?? []

        self.instrumentation.listingPublished(key: message._key, subscribers: 1, registrations: registrations.count)
        message.replyWith(registrations)
    }

    private func onRegister(context: _ActorContext<Message>, message: _AnyRegister) throws {
        let key = message._key.asAnyKey
        let ref = message._addressableActorRef

        guard ref.id._isLocal || (ref.id.node == context.system.cluster.node) else {
            context.log.warning(
                """
                Actor [\(ref)] attempted to register under key [\(key)], with NOT-local receptionist! \
                Actors MUST register with their local receptionist in today's Receptionist implementation.
                """
            )
            return  // TODO: This restriction could be lifted; perhaps we can direct the register to the right node?
        }

        if self.storage.addRegistration(key: key, ref: ref) {
            self.instrumentation.actorRegistered(key: key, id: ref.id)

            context.watch(ref)

            self.addOperation(context, .register(key: key, id: ref.id))

            context.log.debug(
                "Registered [\(ref.id)] for key [\(key)]",
                metadata: [
                    "receptionist/key": "\(key)",
                    "receptionist/registered": "\(ref.id)",
                    "receptionist/opLog/maxSeqNr": "\(self.ops.maxSeqNr)",
                ]
            )

            self.ensureDelayedListingFlush(of: key, context: context)
        }

        // ---
        // Replication of is done in periodic tics, thus we do not perform a push here.
        // ---

        message.replyRegistered()
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Delayed (Listing Notification) Flush

extension _OperationLogClusterReceptionist {
    func ensureDelayedListingFlush(of key: AnyReceptionKey, context: _ActorContext<Message>) {
        let timerKey = self.flushTimerKey(key)

        if self.storage.registrations(forKey: key)?.isEmpty ?? true {
            self.notifySubscribers(of: key)
            return  // no need to schedule, there are no registered actors at all, we eagerly emit this info
        }

        guard !context.timers.exists(key: timerKey) else {
            return  // timer exists nothing to do
        }

        // TODO: also flush when a key has seen e.g. 100 changes?
        let flushDelay = context.system.settings.receptionist.listingFlushDelay
        context.timers.startSingle(key: timerKey, message: _ReceptionistDelayedListingFlushTick(key: key), delay: flushDelay)
    }

    func onDelayedListingFlushTick(context: _ActorContext<_ReceptionistMessage>, message: _ReceptionistDelayedListingFlushTick) {
        context.log.trace("Delayed listing flush: \(message.key)")

        self.notifySubscribers(of: message.key)
    }

    func notifySubscribers(of key: AnyReceptionKey) {
        let registrations: Set<_AddressableActorRef> = self.storage.registrations(forKey: key) ?? []

        guard let subscriptions = self.storage.subscriptions(forKey: key) else {
            self.instrumentation.listingPublished(key: key, subscribers: 0, registrations: registrations.count)
            return  // ok, no-one to notify
        }

        self.instrumentation.listingPublished(key: key, subscribers: subscriptions.count, registrations: registrations.count)
        for subscription in subscriptions {
            subscription._replyWith(registrations)
        }
    }

    private func flushTimerKey(_ key: AnyReceptionKey) -> _TimerKey {
        "flush-\(key.hashValue)"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Op replication

extension _OperationLogClusterReceptionist {
    /// Received a push of ops; apply them to the local view of the key space (storage).
    ///
    /// The incoming ops will be until some max SeqNr, once we have applied them all,
    /// we send back an `ack(maxSeqNr)` to both confirm the receipt, as well as potentially trigger
    /// more ops being delivered
    func receiveOps(_ context: _ActorContext<Message>, push: PushOps) {
        let peer = push.peer

        // 1.1) apply the pushed ops to our state
        let peerReplicaId: ReplicaID = .actorID(push.peer.id)
        let lastAppliedSeqNrAtPeer = self.appliedSequenceNrs[peerReplicaId]

        // De-duplicate
        // In case we got re-sends (the other node sent us some data twice, yet we already have it, we do not replay the already known data),
        // we do not want to apply the same ops twice, so we skip the already known ones
        let opsToApply = push.sequencedOps.drop(while: { op in
            op.sequenceRange.max <= lastAppliedSeqNrAtPeer
        })

        context.log.trace(
            "Received \(push.sequencedOps.count) ops",
            metadata: [
                "receptionist/peer": "\(push.peer.id)",
                "receptionist/lastKnownSeqNrAtPeer": "\(lastAppliedSeqNrAtPeer)",
                "receptionist/opsToApply": Logger.Metadata.Value.array(opsToApply.map { Logger.Metadata.Value.string("\($0)") }),
            ]
        )

        /// Collect which keys have been updated during this push, so we can publish updated listings for them.
        var keysToPublish: Set<AnyReceptionKey> = []
        for op in opsToApply {
            keysToPublish.insert(self.applyIncomingOp(context, from: peer, op))
        }

        context.log.trace("Keys to publish: \(keysToPublish)")

        // 1.2) update our observed version of `pushed.peer` to the incoming
        self.observedSequenceNrs.merge(other: push.observedSeqNrs)
        self.appliedSequenceNrs.merge(other: .init(push.findMaxSequenceNr(), at: peerReplicaId))

        // 2) check for all peers if we are "behind", and should pull information from them
        //    if this message indicated "end" of the push, then we assume we are up to date with it
        //    and will only pull again from it on the SlowACK
        let myselfReplicaID: ReplicaID = .actorID(context.myself.id)
        // Note that we purposefully also skip replying to the peer (sender) to the sender of this push yet,
        // we will do so below in any case, regardless if we are behind or not; See (4) for ACKing the peer
        for replica in push.observedSeqNrs.replicaIDs
        where replica != peerReplicaId && replica != myselfReplicaID && self.observedSequenceNrs[replica] < push.observedSeqNrs[replica] {
            switch replica.storage {
            case .actorID(let address):
                self.sendAckOps(context, receptionistAddress: address)
            default:
                fatalError("Only .actorID supported as replica ID")
            }
        }

        // 3) Push listings for any keys that we have updated during this batch
        for key in keysToPublish {
            self.publishListings(context, forKey: key)
        }

        // 4) ACK that we processed the ops, if there's any more to be replayed
        //    the peer will then send us another chunk of data.
        //    IMPORTANT: We want to confirm until the _latest_ number we know about
        self.sendAckOps(context, receptionistAddress: peer.id, maybeReceptionistRef: peer)

        // 5) Since we just received ops from `peer` AND also sent it an `AckOps`,
        //    there is no need to send it another _periodic_ AckOps potentially right after.
        //    We DO want to send the Ack directly here as potentially the peer still has some more
        //    ops it might want to send, so we want to allow it to get those over to us as quickly as possible,
        //    without waiting for our Ack ticks to trigger (which could be configured pretty slow).
        let nextPeriodicAckAllowedIn: Duration = context.system.settings.receptionist.ackPullReplicationIntervalSlow * 2
        self.nextPeriodicAckPermittedDeadline[peer] = .fromNow(nextPeriodicAckAllowedIn)  // TODO: context.system.timeSource
    }

    /// Apply incoming operation from `peer` and update the associated applied sequenceNumber tracking
    ///
    /// - Returns: Set of keys which have been updated during this
    func applyIncomingOp(_ context: _ActorContext<Message>, from peer: _ActorRef<Message>, _ sequenced: OpLog<ReceptionistOp>.SequencedOp) -> AnyReceptionKey {
        let op = sequenced.op

        // apply operation to storage
        switch op {
        case .register(let key, let id):
            let resolved = context.system._resolveUntyped(context: .init(id: id, system: context.system))
            context.watch(resolved)
            if self.storage.addRegistration(key: key, ref: resolved) {
                self.instrumentation.actorRegistered(key: key, id: id)
            }

        case .remove(let key, let id):
            let resolved = context.system._resolveUntyped(context: .init(id: id, system: context.system))
            context.unwatch(resolved)
            if self.storage.removeRegistration(key: key, ref: resolved) != nil {
                self.instrumentation.actorRemoved(key: key, id: id)
            }
        }

        // update the version up until which we updated the state
        self.appliedSequenceNrs.merge(other: VersionVector(sequenced.sequenceRange.max, at: .actorID(peer.id)))

        return op.key
    }

    /// Acknowledge the latest applied sequence number we have from the passed in receptionist.
    ///
    /// This simultaneously acts as a "pull" conceptually, since we send an `AckOps` which confirms the latest we've applied
    /// as well as potentially causing further data to be sent.
    private func sendAckOps(
        _ context: _ActorContext<Message>,
        receptionistAddress: ActorID,
        maybeReceptionistRef: ReceptionistRef? = nil
    ) {
        assert(maybeReceptionistRef == nil || maybeReceptionistRef?.id == receptionistAddress, "Provided receptionistRef does NOT match passed Address, this is a bug in receptionist.")
        guard case .remote = receptionistAddress._location else {
            return  // this would mean we tried to pull from a "local" receptionist, bail out
        }

        guard self.membership.contains(receptionistAddress.node) else {
            // node is either not known to us yet, OR has been downed and removed
            // avoid talking to it until we see it in membership.
            return
        }

        let peerReceptionistRef: ReceptionistRef
        if let ref = maybeReceptionistRef {
            peerReceptionistRef = ref  // allows avoiding to have to perform a resolve here
        } else {
            peerReceptionistRef = context.system._resolve(context: .init(id: receptionistAddress, system: context.system))
        }

        // Get the latest seqNr of the op that we have applied to our state
        // If we never applied anything, this automatically is `0`, and by sending an `ack(0)`,
        // we effectively initiate the "first pull"
        let latestAppliedSeqNrFromPeer = self.appliedSequenceNrs[.actorID(receptionistAddress)]

        let ack = AckOps(
            appliedUntil: latestAppliedSeqNrFromPeer,
            observedSeqNrs: self.observedSequenceNrs,
            peer: context.myself
        )

        tracelog(context, .push(to: peerReceptionistRef), message: ack)
        peerReceptionistRef.tell(ack)
    }

    /// Listings have changed for this key, thus we need to publish them to all subscribers
    private func publishListings(_ context: _ActorContext<Message>, forKey key: AnyReceptionKey) {
        guard let subscribers = self.storage.subscriptions(forKey: key) else {
            return  // no subscribers for this key
        }

        self.publishListings(context, forKey: key, to: subscribers)
    }

    private func publishListings(_ context: _ActorContext<Message>, forKey key: AnyReceptionKey, to subscribers: Set<AnySubscribe>) {
        let registrations = self.storage.registrations(forKey: key) ?? []

        context.log.trace(
            "Publishing listing [\(key)]",
            metadata: [
                "receptionist/key": "\(key.id)",
                "receptionist/registrations": "\(registrations.count)",
                "receptionist/subscribers": "\(subscribers.count)",
            ]
        )

        for subscriber: AnySubscribe in subscribers {
            subscriber._replyWith(registrations)
        }
    }

    /// Send `AckOps` to to peers (unless prevented to by silence period because we're already conversing/streaming with one)
    // TODO: This should pick a few at random rather than ping everyone
    private func onPeriodicAckTick(_ context: _ActorContext<Message>) {
        for peer in self.peerReceptionistReplayers.keys {
            /// In order to avoid sending spurious acks which would cause the peer to start delivering from the acknowledged `until`,
            /// e.g. while it is still in the middle of sending us more ops, we avoid sending more acks earlier than a regular "tick"
            /// from the point in time we last received ops from this peer. In practice this means:
            /// - if we are in the middle of an ack/ops exchange between us and the peer, we will not send another ack here -- an eager one (not timer based) was already sent
            ///   - if the eager ack would has been lost, this timer will soon enough trigger again, and we'll deliver the ack this way
            /// - if we are NOT in the middle of receiving ops, we share our observed versions and ack as means of spreading information about the seen SeqNrs
            ///   - this may cause the other peer to pull (ack) from any other peer receptionist, if it notices it is "behind" with regards to any of them. // FIXME: what if a peer notices "twice" so we also need to prevent a timer from resending that ack?
            if let periodicAckAllowedAgainDeadline = self.nextPeriodicAckPermittedDeadline[peer],
                periodicAckAllowedAgainDeadline.hasTimeLeft()
            {
                // we still cannot send acks to this peer, it is in the middle of a message exchange with us already
                continue
            }

            // the deadline is clearly overdue, so we remove the value completely to avoid them piling up in there even as peers terminate
            _ = self.nextPeriodicAckPermittedDeadline.removeValue(forKey: peer)

            self.sendAckOps(context, receptionistAddress: peer.id, maybeReceptionistRef: peer)
        }
    }

    /// Receive an Ack and potentially continue streaming ops to peer if still pending operations available.
    private func receiveAckOps(_ context: _ActorContext<Message>, until: UInt64, by peer: _ActorRef<_OperationLogClusterReceptionist.Message>) {
        guard var replayer = self.peerReceptionistReplayers[peer] else {
            context.log.trace("Received a confirmation until \(until) from \(peer) but no replayer available for it, ignoring")
            return
        }

        replayer.confirm(until: until)
        self.peerReceptionistReplayers[peer] = replayer

        self.replicateOpsBatch(context, to: peer)
    }

    private func replicateOpsBatch(_ context: _ActorContext<Message>, to peer: _ActorRef<Receptionist.Message>) {
        guard peer.id != context.id else {
            return  // no reason to stream updates to myself
        }

        guard let replayer = self.peerReceptionistReplayers[peer] else {
            context.log.trace("Attempting to continue replay for \(peer) but no replayer available for it, ignoring")
            return
        }

        let sequencedOps = replayer.nextOpsChunk()
        guard !sequencedOps.isEmpty else {
            return  // nothing to stream, done
        }

        context.log.debug(
            "Streaming \(sequencedOps.count) ops: from [\(replayer.atSeqNr)]",
            metadata: [
                "receptionist/peer": "\(peer.id)",
                "receptionist/ops/replay/atSeqNr": "\(replayer.atSeqNr)",
                "receptionist/ops/maxSeqNr": "\(self.ops.maxSeqNr)",
            ]
        )  // TODO: metadata pattern

        let pushOps = PushOps(
            peer: context.myself,
            observedSeqNrs: self.observedSequenceNrs,
            sequencedOps: Array(sequencedOps)
        )
        self.tracelog(context, .push(to: peer), message: pushOps)

        /// hack in order ro override the Message.self being used to find the serializer
        switch peer.personality {
        case .remote(let remote):
            remote.sendUserMessage(pushOps)
        default:
            fatalError("Remote receptionists MUST be of .remote personality, was: \(peer.personality), \(peer.id)")
        }
    }

    private func addOperation(_ context: _ActorContext<Message>, _ op: ReceptionistOp) {
        self.ops.add(op)
        switch op {
        case .register:
            context.system.metrics._receptionist_registrations.increment()
        case .remove:
            context.system.metrics._receptionist_registrations.decrement()
        }

        let latestSelfSeqNr = VersionVector(self.ops.maxSeqNr, at: .actorID(context.myself.id))
        self.observedSequenceNrs.merge(other: latestSelfSeqNr)
        self.appliedSequenceNrs.merge(other: latestSelfSeqNr)

        context.system.metrics._receptionist_oplog_size.record(self.ops.count)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Termination handling

extension _OperationLogClusterReceptionist {
    private func onTerminated(context: _ActorContext<_ReceptionistMessage>, terminated: _Signals.Terminated) {
        if terminated.id == ActorID._receptionist(on: terminated.id.node, for: .actorRefs) {
            context.log.debug("Watched receptionist terminated: \(terminated)")
            self.onReceptionistTerminated(context, terminated: terminated)
        } else {
            context.log.debug("Watched actor terminated: \(terminated)")
            self.onActorTerminated(context, terminated: terminated)
        }
    }

    private func onReceptionistTerminated(_ context: _ActorContext<Message>, terminated: _Signals.Terminated) {
        self.pruneClusterMember(context, removedNode: terminated.id.node)
    }

    private func onActorTerminated(_ context: _ActorContext<Message>, terminated: _Signals.Terminated) {
        self.onActorTerminated(context, id: terminated.id)
    }

    private func onActorTerminated(_ context: _ActorContext<Message>, id: ActorID) {
        let equalityHackRef = _ActorRef<Never>(.deadLetters(.init(context.log, id: id, system: nil)))
        let wasRegisteredWithKeys = self.storage.removeFromKeyMappings(equalityHackRef.asAddressable)

        for key in wasRegisteredWithKeys.registeredUnderKeys {
            self.addOperation(context, .remove(key: key, id: id))
            self.publishListings(context, forKey: key)
        }

        context.log.trace("Actor terminated \(id), and removed from receptionist.")
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Handle Cluster Events

extension _OperationLogClusterReceptionist {
    private func onClusterEvent(_ context: _ActorContext<Message>, event: Cluster.Event) {
        switch event {
        case .snapshot(let snapshot):
            let diff = Cluster.Membership._diff(from: .empty, to: snapshot)
            guard !diff.changes.isEmpty else {
                return  // empty changes, nothing to act on
            }
            context.log.debug(
                "Changes from initial snapshot, applying one by one",
                metadata: [
                    "membership/changes": "\(diff.changes)"
                ]
            )
            for change in diff.changes {
                self.onClusterEvent(context, event: .membershipChange(change))
            }

        case .membershipChange(let change):
            guard let effectiveChange = self.membership.applyMembershipChange(change) else {
                return
            }

            if effectiveChange.previousStatus == nil {
                // a new member joined, let's store and contact its receptionist
                self.onNewClusterMember(context, change: effectiveChange)
            } else if effectiveChange.status.isAtLeast(.down) {
                // a member was removed, we should prune it from our observations
                self.pruneClusterMember(context, removedNode: effectiveChange.node)
            }

        case .leadershipChange, .reachabilityChange:
            return  // we ignore those

        case ._PLEASE_DO_NOT_EXHAUSTIVELY_MATCH_THIS_ENUM_NEW_CASES_MIGHT_BE_ADDED_IN_THE_FUTURE:
            context.log.error("Received Cluster.Event [\(event)]. This should not happen, please file an issue.")
        }
    }

    private func onNewClusterMember(_ context: _ActorContext<_OperationLogClusterReceptionist.Message>, change: Cluster.MembershipChange) {
        guard change.previousStatus == nil else {
            return  // not a new member
        }

        guard change.node != context.system.cluster.node else {
            return  // no need to contact our own node, this would be "us"
        }

        context.log.debug("New member, contacting its receptionist: \(change.node)")

        // resolve receptionist on the other node, so we can stream our registrations to it
        let remoteReceptionistAddress = ActorID._receptionist(on: change.node, for: .actorRefs)
        let remoteReceptionist: _ActorRef<Message> = context.system._resolve(context: .init(id: remoteReceptionistAddress, system: context.system))

        // ==== "push" replication -----------------------------
        // we noticed a new member, and want to offer it our information right away

        // store the remote receptionist and replayer, it shall always use the same replayer
        let replayer = self.ops.replay(from: .beginning)
        self.peerReceptionistReplayers[remoteReceptionist] = replayer

        self.replicateOpsBatch(context, to: remoteReceptionist)
    }

    private func pruneClusterMember(_ context: _ActorContext<_OperationLogClusterReceptionist.Message>, removedNode: Cluster.Node) {
        context.log.trace("Pruning cluster member: \(removedNode)")
        let terminatedReceptionistAddress = ActorID._receptionist(on: removedNode, for: .actorRefs)
        let equalityHackPeerRef = _ActorRef<Message>(.deadLetters(.init(context.log, id: terminatedReceptionistAddress, system: nil)))

        guard self.peerReceptionistReplayers.removeValue(forKey: equalityHackPeerRef) != nil else {
            // we already removed it, so no need to keep scanning for it.
            // this could be because we received a receptionist termination before a node down or vice versa.
            //
            // although this should not happen and may indicate we got a Terminated for an address twice?
            return
        }

        // clear observations; we only get them directly from the origin node, so since it has been downed
        // we will never receive more observations from it.
        _ = self.observedSequenceNrs.pruneReplica(.actorID(terminatedReceptionistAddress))
        _ = self.appliedSequenceNrs.pruneReplica(.actorID(terminatedReceptionistAddress))

        // clear state any registrations still lingering about the now-known-to-be-down node
        let pruned = self.storage.pruneNode(removedNode)
        for key in pruned.keys {
            self.publishListings(context, forKey: key, to: pruned.peersToNotify(key))
        }
    }
}

// ==== ------------------------------------------------------------------------------------------------------------
// MARK: Extra Messages

extension _OperationLogClusterReceptionist {
    /// Confirms that the remote peer receptionist has received Ops up until the given element,
    /// allows us to push more elements
    class PushOps: Receptionist.Message {
        // the "sender" of the push
        let peer: _ActorRef<Receptionist.Message>

        /// Overview of all receptionist's latest SeqNr the `peer` receptionist was aware of at time of pushing.
        /// Recipient shall compare these versions and pull from appropriate nodes.
        ///
        /// Guaranteed to be keyed with `.actorID`. // FIXME ensure this
        // Yes, we're somewhat abusing the VV for our "container of sequence numbers",
        // but its merge() facility is quite handy here.
        let observedSeqNrs: VersionVector

        let sequencedOps: [OpLog<ReceptionistOp>.SequencedOp]

        init(peer: _ActorRef<Receptionist.Message>, observedSeqNrs: VersionVector, sequencedOps: [OpLog<ReceptionistOp>.SequencedOp]) {
            self.peer = peer
            self.observedSeqNrs = observedSeqNrs
            self.sequencedOps = sequencedOps
            super.init()
        }

        // the passed ops cover the range until the following sequenceNr
        func findMaxSequenceNr() -> UInt64 {
            self.sequencedOps.lazy.map(\.sequenceRange.max).max() ?? 0
        }

        enum CodingKeys: CodingKey {
            case peer
            case observedSeqNrs
            case sequencedOps
        }

        // TODO: annoyance; init MUST be defined here rather than in extension since it is required
        required init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.peer = try container.decode(_ActorRef<Receptionist.Message>.self, forKey: .peer)
            self.observedSeqNrs = try container.decode(VersionVector.self, forKey: .observedSeqNrs)
            self.sequencedOps = try container.decode([OpLog<ReceptionistOp>.SequencedOp].self, forKey: .sequencedOps)
            super.init()
        }

        override func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.peer, forKey: .peer)
            try container.encode(self.observedSeqNrs, forKey: .observedSeqNrs)
            try container.encode(self.sequencedOps, forKey: .sequencedOps)
        }
    }

    /// Confirms that the remote peer receptionist has received Ops up until the given element,
    /// allows us to push more elements
    class AckOps: Receptionist.Message, CustomStringConvertible {
        /// Cumulative ACK of all ops until (and including) this one.
        ///
        /// If a recipient has more ops than the `confirmedUntil` confirms seeing, it shall offer
        /// those to the `peer` which initiated this `ConfirmOps`
        let until: UInt64  // inclusive

        let otherObservedSeqNrs: VersionVector

        /// Reference of the sender of this ConfirmOps message,
        /// if more ops are available on the targets op stream, they shall be pushed to this actor.
        let peer: _ActorRef<Receptionist.Message>

        init(appliedUntil: UInt64, observedSeqNrs: VersionVector, peer: _ActorRef<Receptionist.Message>) {
            self.until = appliedUntil
            self.otherObservedSeqNrs = observedSeqNrs
            self.peer = peer
            super.init()
        }

        enum CodingKeys: CodingKey {
            case until
            case otherObservedSeqNrs
            case peer
        }

        // TODO: annoyance; init MUST be defined here rather than in extension since it is required
        required init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let until = try container.decode(UInt64.self, forKey: .until)
            let otherObservedSeqNrs = try container.decode(VersionVector.self, forKey: .otherObservedSeqNrs)
            let peer = try container.decode(_ActorRef<Receptionist.Message>.self, forKey: .peer)

            self.until = until
            self.otherObservedSeqNrs = otherObservedSeqNrs
            self.peer = peer
            super.init()
        }

        override func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.until, forKey: .until)
            try container.encode(self.otherObservedSeqNrs, forKey: .otherObservedSeqNrs)
            try container.encode(self.peer, forKey: .peer)
        }

        var description: String {
            "Receptionist.AckOps(until: \(self.until), otherObservedSeqNrs: \(self.otherObservedSeqNrs), peer: \(self.peer))"
        }
    }

    class PeriodicAckTick: Receptionist.Message, _NotActuallyCodableMessage, CustomStringConvertible {
        override init() {
            super.init()
        }

        public required init(from decoder: Decoder) throws {
            throw SerializationError(.nonTransportableMessage(type: "\(Self.self)"))
        }

        var description: String {
            "Receptionist.PeriodicAckTick()"
        }
    }

    class PublishLocalListingsTrigger: Receptionist.Message, _NotActuallyCodableMessage, CustomStringConvertible {
        override init() {
            super.init()
        }

        public required init(from decoder: Decoder) throws {
            throw SerializationError(.nonTransportableMessage(type: "\(Self.self)"))
        }

        var description: String {
            "Receptionist.PublishLocalListingsTrigger()"
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Tracelog

extension _OperationLogClusterReceptionist {
    /// Optional "dump all messages" logging.
    ///
    /// Enabled by `Settings.traceLogLevel` or `-DSACT_TRACELOG_RECEPTIONIST`
    func tracelog(
        _ context: _ActorContext<Message>,
        _ type: TraceLogType,
        message: Any,
        file: String = #filePath,
        function: String = #function,
        line: UInt = #line
    ) {
        if let level = context.system.settings.receptionist.traceLogLevel {
            context.log.log(
                level: level,
                "[tracelog:receptionist] \(type.description): \(message)",
                file: file,
                function: function,
                line: line
            )
        }
    }

    enum TraceLogType: CustomStringConvertible {
        case receive(from: _ActorRef<Message>?)
        case push(to: _ActorRef<Message>)

        static var receive: TraceLogType {
            .receive(from: nil)
        }

        var description: String {
            switch self {
            case .receive(nil):
                return "RECV"
            case .push(let to):
                return "PUSH(to:\(to.id))"
            case .receive(let .some(from)):
                return "RECV(from:\(from.id))"
            }
        }
    }
}
