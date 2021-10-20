//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import _Distributed
import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster (OpLog) Receptionist

distributed actor OpLogDistributedReceptionist: DistributedReceptionist, CustomStringConvertible {
    // TODO: remove this
    typealias ReceptionistRef = OpLogDistributedReceptionist
    typealias Key<Guest: DistributedActor & __DistributedClusterActor> = DistributedReception.Key<Guest>

    internal let instrumentation: ReceptionistInstrumentation

    /// Stores the actual mappings of keys to actors.
    let storage = DistributedReceptionistStorage()

    internal enum ReceptionistOp: OpLogStreamOp, Codable {
        case register(key: AnyDistributedReceptionKey, identity: AnyActorIdentity)
        case remove(key: AnyDistributedReceptionKey, identity: AnyActorIdentity)

        var key: AnyDistributedReceptionKey {
            switch self {
            case .register(let key, _): return key
            case .remove(let key, _): return key
            }
        }
    }

    lazy var log: Logger = Logger(actor: self)

    // TODO(distributed): once the transport becomes ActorSystem in the init, and the stored property automatically becomes of this type we don't need this anymore
    var system: ActorSystem {
        self.actorTransport._forceUnwrapActorSystem
    }

    /// Per known receptionist replayer instances, pointing at the latest confirmed message.
    /// Resuming a replay means getting any ops that were not yet observed by the receptionist.
    ///
    /// Replays are triggered upon receiving an `AckOps`, which simultaneously act as ACKing any previously replayed messages.
    var peerReceptionistReplayers: [ReceptionistRef: OpLog<ReceptionistOp>.Replayer]

    /// Local operations log; Replaying events in it results in restoring the key:actor mappings known to this actor locally.
    let ops: OpLog<ReceptionistOp>

    var membership: Cluster.Membership

    var eventsListeningTask: Task<Void, Error>!

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Timers

    static let slowACKReplicationTick: TimerKey = "slow-ack-replication-tick"
    static let fastACKReplicationTick: TimerKey = "fast-ack-replication-tick"

    static let localPublishLocalListingsTick: TimerKey = "publish-local-listings-tick"

    private lazy var timers = ActorTimers<OpLogDistributedReceptionist>(self)

    /// Important: This safeguards us from the following write amplification scenario:
    ///
    /// Since:
    /// - `AckOps` serves both as an ACK and "poll", and
    /// - `AckOps` is used to periodically spread information
    var nextPeriodicAckPermittedDeadline: [AnyActorIdentity: Deadline]

    /// Sequence numbers of op-logs that we have observed, INCLUDING our own latest op's seqNr.
    /// In other words, each receptionist has their own op-log, and we observe and store the latest seqNr we have seen from them.
    var observedSequenceNrs: VersionVector

    /// Tracks up until what SeqNr we actually have applied the operations to our `storage`.
    ///
    /// The difference between these versions at given peer and the `maxObservedSequenceNr` at given peer,
    /// gives a good idea how far "behind" we are with regards to changed performed at that peer.
    var appliedSequenceNrs: VersionVector

    static var props: Props {
        var ps = Props()
        ps._knownActorName = ActorPath.distributedActorReceptionist.name
        ps._systemActor =  true
        ps._wellKnown = true
        return ps
    }

    // FIXME(swift 6): initializer must become async
    init(settings: ClusterReceptionist.Settings,
         transport: ActorTransport
//         transport system: ActorSystem // FIXME(distributed): should be specific ActorSystem type, but that causes the synthesized storage rdar://84329494
    ) {
        let system = transport._forceUnwrapActorSystem
        defer { system.actorReady(self) }

        self.instrumentation = system.settings.instrumentation.makeReceptionistInstrumentation()

        self.ops = OpLog(of: ReceptionistOp.self, batchSize: settings.syncBatchSize)
        self.membership = .empty
        self.peerReceptionistReplayers = [:]

        self.nextPeriodicAckPermittedDeadline = [:]
        
        self.observedSequenceNrs = .empty
        self.appliedSequenceNrs = .empty

        // === listen to cluster events ------------------
        self.eventsListeningTask = Task {
            try await self.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): this is annoying, we must track "known to be local" in typesystem instead
                for try await event in system.cluster.events {
                    __secretlyKnownToBeLocal.onClusterEvent(event: event)
                }
            }
        }

        // TODO(distributed): move the start timers here, once the init is async

        log.debug("Initialized receptionist")
    }

    // FIXME(distributed): once the init is async move this back to init, we need the function to be isolated to the receptionist
    //                     so the closure may perform the self.periodicAckTick() schedule
    distributed func start() {
        // === timers ------------------
        // periodically gossip to other receptionists with the last seqNr we've seen,
        // and if it happens to be outdated by then this will cause a push from that node.
        timers.startPeriodic(
            key: Self.slowACKReplicationTick,
            interval: system.settings.cluster.receptionist.ackPullReplicationIntervalSlow
        ) {
            await self.periodicAckTick()
        }
    }

    nonisolated var description: String {
        "\(Self.self)(\(id.underlying))"
    }

}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Receptionist API impl

extension OpLogDistributedReceptionist: LifecycleWatchSupport {

    func register<Guest>(
        _ guest: Guest,
        with key: DistributedReception.Key<Guest>
    ) async where Guest: DistributedActor & __DistributedClusterActor {
        pprint("distributed receptionist: register(\(guest), with: \(key)")
        log.warning("distributed receptionist: register(\(guest), with: \(key)")
        let key = key.asAnyKey
        guard let address = guest.id._unwrapActorAddress else {
            log.error("Cannot register actor with unknown identity type \(guest.id.underlying) with receptionist")
            return
        }

        let ref = system._resolveUntyped(identity: guest.id)

        guard address._isLocal || (address.uniqueNode == system.cluster.uniqueNode) else {
            log.warning("""
            Actor [\(guest.id.underlying)] attempted to register under key [\(key)], with NOT-local receptionist! \
            Actors MUST register with their local receptionist in today's Receptionist implementation.
            """)
            return // TODO: This restriction could be lifted; perhaps we can direct the register to the right node?
        }

        if self.storage.addRegistration(key: key, guest: guest) {
            // self.instrumentation.actorRegistered(key: key, address: address) // TODO(distributed): make the instrumentation calls compatible with distributed actor based types

            watchTermination(of: guest) { onActorTerminated(identity: $0) }

            self.addOperation(.register(key: key, identity: guest.id))

            log.debug(
                "Registered [\(address)] for key [\(key)]",
                metadata: [
                    "receptionist/key": "\(key)",
                    "receptionist/guest": "\(address)",
                    "receptionist/opLog/maxSeqNr": "\(self.ops.maxSeqNr)",
                    "receptionist/opLog": "\(self.ops.ops)",
                ]
            )

            self.ensureDelayedListingFlush(of: key)
        }

        // Replication of is done in periodic tics, thus we do not perform a push here.

        // reply "registered"
    }

    func subscribe<Guest>(
        to key: DistributedReception.Key<Guest>
    ) async -> DistributedReception.GuestListing<Guest>
            where Guest: DistributedActor & __DistributedClusterActor {
        DistributedReception.GuestListing<Guest>(receptionist: self, key: key)
    }

    func _subscribe<Guest>(
        continuation: AsyncStream<Guest>.Continuation,
        subscriptionID: ObjectIdentifier,
        to key: DistributedReception.Key<Guest>
    ) where Guest: DistributedActor & __DistributedClusterActor {
        let anyKey = key.asAnyKey
        let anySubscribe = AnyDistributedSubscribe(subscriptionID: subscriptionID, send: { listing in
            for guest in listing { // FIXME: no loop here
                continuation.yield(guest.force(as: Guest.self))
            }
        })

        if self.storage.addSubscription(key: anyKey, subscription: anySubscribe) {
            // self.instrumentation.actorSubscribed(key: anyKey, address: self.id._unwrapActorAddress) // FIXME: remove the address parameter, it does not make sense anymore
            log.trace("Subscribed async sequence to \(anyKey) actors")
        }
    }

    func _cancelSubscription<Guest>(
        subscriptionID: ObjectIdentifier,
        to key: DistributedReception.Key<Guest>
    ) where Guest: DistributedActor & __DistributedClusterActor {

        pinfo("Cancel sub: \(subscriptionID), to key \(key)")

    }


    func lookup<Guest>(_ key: DistributedReception.Key<Guest>) async -> Set<Guest>
        where Guest: DistributedActor & __DistributedClusterActor {
        let registrations = self.storage.registrations(forKey: key.asAnyKey) ?? []

        // self.instrumentation.listingPublished(key: message._key, subscribers: 1, registrations: registrations.count) // TODO(distributed): make the instrumentation calls compatible with distributed actor based types
        let guests = Set(registrations.compactMap { any in
            any.underlying as? Guest
        })

        assert(guests.count == registrations.count, """
                                                    Was unable to map some registrations to \(Guest.self). 
                                                      Registrations: \(registrations)
                                                      Guests:        \(guests)
                                                    """)
        return guests
    }
}

distributed actor ReceptionListingSubscriber<Guest: DistributedActor> {
    lazy var log: Logger = Logger(actor: self)

    distributed func onCheckIn(guest: Guest) {
        log.debug("RECEIVED: \(guest)")
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Delayed (Listing Notification) Flush

extension OpLogDistributedReceptionist {
    func ensureDelayedListingFlush(of key: AnyDistributedReceptionKey) {
        let timerKey = self.flushTimerKey(key)

        if self.storage.registrations(forKey: key)?.isEmpty ?? true {
            log.debug("notify now, no need to schedule delayed flush")
            self.notifySubscribers(of: key)
            return // no need to schedule, there are no registered actors at all, we eagerly emit this info
        }

        guard !timers.exists(key: timerKey) else {
            log.debug("timer exists")
            return // timer exists nothing to do
        }

        // TODO: also flush when a key has seen e.g. 100 changes?
        let flushDelay = system.settings.receptionist.listingFlushDelay
        // timers.startSingle(key: timerKey, message: _ReceptionistDelayedListingFlushTick(key: key), delay: flushDelay)
        log.debug("schedule delayed flush")
        timers.startSingle(key: timerKey, delay: flushDelay) {
            self.onDelayedListingFlushTick(key: key)
        }
    }

    func onDelayedListingFlushTick(key: AnyDistributedReceptionKey) {
        log.trace("Run delayed listing flush: \(key), subscribers of key: \(key)")

        self.notifySubscribers(of: key)
    }

    private func notifySubscribers(of key: AnyDistributedReceptionKey) {
        guard let subscriptions = self.storage.subscriptions(forKey: key) else {
            // self.instrumentation.listingPublished(key: key, subscribers: 0, registrations: registrations.count) // TODO(distributed): make the instrumentation calls compatible with distributed actor based types
            log.debug("No one is listening for key \(key)")
            return // ok, no-one to notify
        }

        let registrations = self.storage.registrations(forKey: key) ?? []

        // self.instrumentation.listingPublished(key: key, subscribers: subscriptions.count, registrations: registrations.count) // TODO(distributed): make the instrumentation calls compatible with distributed actor based types
        for subscription in subscriptions {
            Task {
                log.debug("Notify \(subscription) about \(key)")
                try await subscription.send(registrations)
            }
        }
    }

    private func flushTimerKey(_ key: AnyDistributedReceptionKey) -> TimerKey {
        "flush-\(key.hashValue)"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Op replication

extension OpLogDistributedReceptionist {


    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handling Ops

    /// Received a push of ops; apply them to the local view of the key space (storage).
    ///
    /// The incoming ops will be until some max SeqNr, once we have applied them all,
    /// we send back an `ack(maxSeqNr)` to both confirm the receipt, as well as potentially trigger
    /// more ops being delivered
    distributed func pushOps(_ push: PushOps) {
        let peer = push.peer

        // 1.1) apply the pushed ops to our state
        let peerReplicaId: ReplicaID = .actorIdentity(push.peer.id)
        let lastAppliedSeqNrAtPeer = self.appliedSequenceNrs[peerReplicaId]

        // De-duplicate
        // In case we got re-sends (the other node sent us some data twice, yet we already have it, we do not replay the already known data),
        // we do not want to apply the same ops twice, so we skip the already known ones
        let opsToApply = push.sequencedOps.drop(while: { op in
            op.sequenceRange.max <= lastAppliedSeqNrAtPeer
        })

        log.trace(
                "Received \(push.sequencedOps.count) ops",
                metadata: [
                    "receptionist/peer": "\(push.peer.id.underlying)",
                    "receptionist/lastKnownSeqNrAtPeer": "\(lastAppliedSeqNrAtPeer)",
                    "receptionist/opsToApply": Logger.Metadata.Value.array(opsToApply.map { Logger.Metadata.Value.string("\($0)") }),
                ]
        )

        /// Collect which keys have been updated during this push, so we can publish updated listings for them.
        var keysToPublish: Set<AnyDistributedReceptionKey> = []
        for op in opsToApply {
            keysToPublish.insert(self.applyIncomingOp(from: peer, op))
        }

        log.trace("Keys to publish: \(keysToPublish)")

        // 1.2) update our observed version of `pushed.peer` to the incoming
        self.observedSequenceNrs.merge(other: push.observedSeqNrs)
        self.appliedSequenceNrs.merge(other: .init(push.findMaxSequenceNr(), at: peerReplicaId))

        // 2) check for all peers if we are "behind", and should pull information from them
        //    if this message indicated "end" of the push, then we assume we are up to date with it
        //    and will only pull again from it on the SlowACK
        let myselfReplicaID: ReplicaID = .actorIdentity(self.id)
        // Note that we purposefully also skip replying to the peer (sender) to the sender of this push yet,
        // we will do so below in any case, regardless if we are behind or not; See (4) for ACKing the peer
        for replica in push.observedSeqNrs.replicaIDs
            where replica != peerReplicaId && replica != myselfReplicaID &&
                    self.observedSequenceNrs[replica] < push.observedSeqNrs[replica] {
            switch replica.storage {
            case .actorIdentity(let identity):
                self.sendAckOps(receptionistIdentity: identity)
            default:
                fatalError("Only .actorIdentity supported as replica ID, was: \(replica.storage)")
            }
        }

        // 3) Push listings for any keys that we have updated during this batch
        keysToPublish.forEach { key in
            self.publishListings(forKey: key)
        }

        // 4) ACK that we processed the ops, if there's any more to be replayed
        //    the peer will then send us another chunk of data.
        //    IMPORTANT: We want to confirm until the _latest_ number we know about
        self.sendAckOps(receptionistIdentity: peer.id, maybeReceptionistRef: peer)

        // 5) Since we just received ops from `peer` AND also sent it an `AckOps`,
        //    there is no need to send it another _periodic_ AckOps potentially right after.
        //    We DO want to send the Ack directly here as potentially the peer still has some more
        //    ops it might want to send, so we want to allow it to get those over to us as quickly as possible,
        //    without waiting for our Ack ticks to trigger (which could be configured pretty slow).
        let nextPeriodicAckAllowedIn: TimeAmount = system.settings.cluster.receptionist.ackPullReplicationIntervalSlow * 2
        self.nextPeriodicAckPermittedDeadline[peer.id] = Deadline.fromNow(nextPeriodicAckAllowedIn) // TODO: system.timeSource
    }

    /// Apply incoming operation from `peer` and update the associated applied sequenceNumber tracking
    ///
    /// - Returns: Set of keys which have been updated during this
    func applyIncomingOp(from peer: OpLogDistributedReceptionist,
                         _ sequenced: OpLog<ReceptionistOp>.SequencedOp) -> AnyDistributedReceptionKey {
        let op = sequenced.op

        // apply operation to storage
        switch op {
        case .register(let key, let identity):
            let address = identity._forceUnwrapActorAddress
//            let resolved = system._resolveUntyped(context: .init(address: address, system: system))
            let resolved = try! system._resolveStub(identity: identity) // TODO(distributed): remove the throwing here?

            watchTermination(of: resolved) {
                onActorTerminated(identity: $0)
            }
            if self.storage.addRegistration(key: key, guest: resolved) {
                // self.instrumentation.actorRegistered(key: key, address: address) // TODO(distributed): make the instrumentation calls compatible with distributed actor based types
            }

        case .remove(let key, let identity):
            let address = identity._forceUnwrapActorAddress
            //            let resolved = system._resolveUntyped(context: .init(address: address, system: system))
            let resolved = try! system._resolveStub(identity: identity) // TODO(distributed): remove the throwing here?

            unwatch(resolved)
            if self.storage.removeRegistration(key: key, guest: resolved) != nil {
                // self.instrumentation.actorRemoved(key: key, address: address) // TODO(distributed): make the instrumentation calls compatible with distributed actor based types
            }
        }

        // update the version up until which we updated the state
        self.appliedSequenceNrs.merge(other: VersionVector(sequenced.sequenceRange.max, at: .actorIdentity(peer.id)))

        return op.key
    }

    /// Acknowledge the latest applied sequence number we have from the passed in receptionist.
    ///
    /// This simultaneously acts as a "pull" conceptually, since we send an `AckOps` which confirms the latest we've applied
    /// as well as potentially causing further data to be sent.
    private func sendAckOps(
        receptionistIdentity: AnyActorIdentity,
        maybeReceptionistRef: ReceptionistRef? = nil
    ) {
        log.info("Send ack OPS...")
        let receptionistAddress = receptionistIdentity._forceUnwrapActorAddress
        assert(maybeReceptionistRef == nil || maybeReceptionistRef?.id._forceUnwrapActorAddress == receptionistAddress,
                "Provided receptionistRef does NOT match passed Address, this is a bug in receptionist.")
        guard case .remote = receptionistAddress._location else {
            return // this would mean we tried to pull from a "local" receptionist, bail out
        }

        guard self.membership.contains(receptionistAddress.uniqueNode) else {
            // node is either not known to us yet, OR has been downed and removed
            // avoid talking to it until we see it in membership.
            return
        }

        let peerReceptionistRef: ReceptionistRef
        if let ref = maybeReceptionistRef {
            // avoiding doing a resolve if we have a real reference already
            peerReceptionistRef = ref
        } else {
            do {
                peerReceptionistRef = try ReceptionistRef.resolve(receptionistIdentity, using: system)
            } catch {
                return fatalErrorBacktrace("Unable to resolve receptionist: \(receptionistIdentity)")
            }
        }
            // peerReceptionistRef = system._resolve(context: .init(address: receptionistAddress, system: system))

        // Get the latest seqNr of the op that we have applied to our state
        // If we never applied anything, this automatically is `0`, and by sending an `ack(0)`,
        // we effectively initiate the "first pull"
        let latestAppliedSeqNrFromPeer = self.appliedSequenceNrs[.actorIdentity(receptionistIdentity)]


//        let ack = AckOps(
//            appliedUntil: latestAppliedSeqNrFromPeer,
//            observedSeqNrs: self.observedSequenceNrs,
//            peer: self
//        )
//        // tracelog(.push(to: peerReceptionistRef), message: ack)
//        peerReceptionistRef.tell(ack)
        Task {
            do {
                try await peerReceptionistRef.ackOps(until: latestAppliedSeqNrFromPeer, by: self)
            } catch {
                log.error("Error: \(error)")
            }
        }
    }

    /// Listings have changed for this key, thus we need to publish them to all subscribers
    private func publishListings(forKey key: AnyDistributedReceptionKey) {
        guard let subscribers = self.storage.subscriptions(forKey: key) else {
            return // no subscribers for this key
        }

        self.publishListings(forKey: key, to: subscribers)
    }

    private func publishListings(forKey key: AnyDistributedReceptionKey, to subscribers: Set<AnyDistributedSubscribe>) {
        let registrations = self.storage.registrations(forKey: key) ?? []

        log.trace(
            "Publishing listing [\(key)]",
            metadata: [
                "receptionist/key": "\(key.id)",
                "receptionist/registrations": "\(registrations.count)",
                "receptionist/subscribers": "\(subscribers.count)",
            ]
        )

        for subscriber in subscribers {
            Task {
                try await subscriber.send(registrations)
            }
        }
    }

    /// Send `AckOps` to to peers (unless prevented to by silence period because we're already conversing/streaming with one)
    // TODO: This should pick a few at random rather than ping everyone
    func periodicAckTick() {
        log.info("Periodic ack tick")

        for peer in self.peerReceptionistReplayers.keys {
            /// In order to avoid sending spurious acks which would cause the peer to start delivering from the acknowledged `until`,
            /// e.g. while it is still in the middle of sending us more ops, we avoid sending more acks earlier than a regular "tick"
            /// from the point in time we last received ops from this peer. In practice this means:
            /// - if we are in the middle of an ack/ops exchange between us and the peer, we will not send another ack here -- an eager one (not timer based) was already sent
            ///   - if the eager ack would has been lost, this timer will soon enough trigger again, and we'll deliver the ack this way
            /// - if we are NOT in the middle of receiving ops, we share our observed versions and ack as means of spreading information about the seen SeqNrs
            ///   - this may cause the other peer to pull (ack) from any other peer receptionist, if it notices it is "behind" with regards to any of them. // FIXME: what if a peer notices "twice" so we also need to prevent a timer from resending that ack?
            if let periodicAckAllowedAgainDeadline = self.nextPeriodicAckPermittedDeadline[peer.id],
                periodicAckAllowedAgainDeadline.hasTimeLeft() {
                // we still cannot send acks to this peer, it is in the middle of a message exchange with us already
                continue
            }

            // the deadline is clearly overdue, so we remove the value completely to avoid them piling up in there even as peers terminate
            _ = self.nextPeriodicAckPermittedDeadline.removeValue(forKey: peer.id)

            self.sendAckOps(receptionistIdentity: peer.id, maybeReceptionistRef: peer)
        }
    }


    /// Receive an Ack and potentially continue streaming ops to peer if still pending operations available.
    distributed func ackOps(until: UInt64, by peer: ReceptionistRef) {
        guard var replayer = self.peerReceptionistReplayers[peer] else {
            log.trace("Received a confirmation until \(until) from \(peer) but no replayer available for it, ignoring")
            return
        }

        replayer.confirm(until: until)
        self.peerReceptionistReplayers[peer] = replayer

        self.replicateOpsBatch(to: peer)
    }

    private func replicateOpsBatch(to peer: ReceptionistRef) {
        log.trace("Replicate ops to: \(peer.id.underlying)")
        guard peer.id != self.id else {
            log.trace("No need to replicate to myself: \(peer.id.underlying)")
            return // no reason to stream updates to myself
        }

        guard let replayer = self.peerReceptionistReplayers[peer] else {
            log.trace("Attempting to continue replay but no replayer available for it, ignoring", metadata: [
                "receptionist/peer": "\(peer.id.underlying)"
            ])
            return
        }

        let sequencedOps = replayer.nextOpsChunk()
        guard !sequencedOps.isEmpty else {
            log.trace("No ops to replay", metadata: [
                "receptionist/peer": "\(peer.id.underlying)"
            ])
            return // nothing to stream, done
        }

        log.debug(
            "Streaming \(sequencedOps.count) ops: from [\(replayer.atSeqNr)]",
            metadata: [
                "receptionist/peer": "\(peer.id.underlying)",
                "receptionist/ops/replay/atSeqNr": "\(replayer.atSeqNr)",
                "receptionist/ops/maxSeqNr": "\(self.ops.maxSeqNr)",
            ]
        ) // TODO: metadata pattern

        let pushOps = PushOps(
            peer: self,
            observedSeqNrs: self.observedSequenceNrs,
            sequencedOps: Array(sequencedOps)
        )
        // tracelog(.push(to: peer), message: pushOps)

//        // FIXME(distributed): remove this, we can't do this anymore  think
//        /// hack in order to override the Message.self being used to find the serializer
//        switch peer.personality {
//        case .remote(let remote):
//            remote.sendUserMessage(pushOps)
//        default:
//            fatalError("Remote receptionists MUST be of .remote personality, was: \(peer.id)")
//        }
        Task {
            do {
                log.error("Push operations: \(pushOps)", metadata: [
                    "receptionist/peer": "\(peer.id)",
                ])
                try await peer.pushOps(pushOps)
            } catch {
                log.error("Failed to pushOps: \(pushOps)", metadata: [
                    "receptionist/peer": "\(peer.id)",
                ])
            }
        }
    }

    private func addOperation(_ op: ReceptionistOp) {
        self.ops.add(op)
        switch op {
        case .register:
            system.metrics._receptionist_registrations.increment()
        case .remove:
            system.metrics._receptionist_registrations.decrement()
        }

        let latestSelfSeqNr = VersionVector(self.ops.maxSeqNr, at: .actorIdentity(self.id))
        self.observedSequenceNrs.merge(other: latestSelfSeqNr)
        self.appliedSequenceNrs.merge(other: latestSelfSeqNr)

        system.metrics._receptionist_oplog_size.record(self.ops.count)
    }
}


// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Termination handling

extension OpLogDistributedReceptionist {
    // func onActorTerminated(terminated: Signals.Terminated) {
    func onActorTerminated(identity: AnyActorIdentity) {
        guard let address = identity._unwrapActorAddress else {
            return
        }

        if address == ActorAddress._receptionist(on: address.uniqueNode, for: .distributedActors) {
            log.debug("Watched receptionist terminated: \(identity)")
            receptionistTerminated(identity: identity)
        } else {
            log.debug("Watched actor terminated: \(identity.underlying)")
            actorTerminated(identity: identity)
        }
    }

    private func receptionistTerminated(identity: AnyActorIdentity) {
        guard let address = identity._unwrapActorAddress else {
            return
        }

        self.pruneClusterMember(removedNode: address.uniqueNode)
    }

    private func actorTerminated(identity: AnyActorIdentity) {
        let equalityHackRef = try! system._resolveStub(identity: identity) // FIXME: cleanup the try!
        let wasRegisteredWithKeys = self.storage.removeFromKeyMappings(equalityHackRef.asAnyDistributedActor)

        for key in wasRegisteredWithKeys.registeredUnderKeys {
            addOperation(.remove(key: key, identity: identity))
            publishListings(forKey: key)
        }

        log.trace("Actor terminated \(identity), and removed from receptionist.")
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Handle Cluster Events

extension OpLogDistributedReceptionist {
    private func onClusterEvent(event: Cluster.Event) {
        switch event {
        case .snapshot(let snapshot):
            let diff = Cluster.Membership._diff(from: .empty, to: snapshot)
            guard !diff.changes.isEmpty else {
                return // empty changes, nothing to act on
            }
            log.debug(
                "Changes from initial snapshot, applying one by one",
                metadata: [
                    "membership/changes": "\(diff.changes)",
                ]
            )
            diff.changes.forEach { change in
                self.onClusterEvent(event: .membershipChange(change))
            }

        case .membershipChange(let change):
            guard let effectiveChange = self.membership.applyMembershipChange(change) else {
                return
            }

            if effectiveChange.previousStatus == nil {
                // a new member joined, let's store and contact its receptionist
                self.onNewClusterMember(change: effectiveChange)
            } else if effectiveChange.status.isAtLeast(.down) {
                // a member was removed, we should prune it from our observations
                self.pruneClusterMember(removedNode: effectiveChange.node)
            }

        case .leadershipChange, .reachabilityChange:
            return // we ignore those
        }
    }

    private func onNewClusterMember(change: Cluster.MembershipChange) {
        guard change.previousStatus == nil else {
            return // not a new member
        }

        guard change.node != system.cluster.uniqueNode else {
            return // no need to contact our own node, this would be "us"
        }

        log.debug("New member, contacting its receptionist: \(change.node)")

        // resolve receptionist on the other node, so we can stream our registrations to it
        let remoteReceptionistAddress = ActorAddress._receptionist(on: change.node, for: .distributedActors)
        let remoteReceptionist = try! Self.resolve(remoteReceptionistAddress.asAnyActorIdentity, using: system) // try!-safe: we know this resolve won't throw, the identity is known to be correct

        // ==== "push" replication -----------------------------
        // we noticed a new member, and want to offer it our information right away

        // store the remote receptionist and replayer, it shall always use the same replayer
        let replayer = self.ops.replay(from: .beginning)
        self.peerReceptionistReplayers[remoteReceptionist] = replayer

        self.replicateOpsBatch(to: remoteReceptionist)
    }

    func pruneClusterMember(removedNode: UniqueNode) {
        log.trace("Pruning cluster member: \(removedNode)")
        let terminatedReceptionistAddress = ActorAddress._receptionist(on: removedNode, for: .distributedActors)
        let terminatedReceptionistIdentity = terminatedReceptionistAddress.asAnyActorIdentity
        let equalityHackPeer = try! Self.resolve(terminatedReceptionistIdentity, using: system) // try!-safe because we know the address is correct and remote

        guard self.peerReceptionistReplayers.removeValue(forKey: equalityHackPeer) != nil else {
            // we already removed it, so no need to keep scanning for it.
            // this could be because we received a receptionist termination before a node down or vice versa.
            //
            // although this should not happen and may indicate we got a Terminated for an address twice?
            return
        }

        // clear observations; we only get them directly from the origin node, so since it has been downed
        // we will never receive more observations from it.
        _ = self.observedSequenceNrs.pruneReplica(.actorIdentity(terminatedReceptionistIdentity))
        _ = self.appliedSequenceNrs.pruneReplica(.actorIdentity(terminatedReceptionistIdentity))

        // clear state any registrations still lingering about the now-known-to-be-down node
        let pruned = self.storage.pruneNode(removedNode)
        for key in pruned.keys {
            self.publishListings(forKey: key, to: pruned.peersToNotify(key))
        }
    }
}

// ==== ------------------------------------------------------------------------------------------------------------
// MARK: Extra Messages

extension OpLogDistributedReceptionist {

    /// Confirms that the remote peer receptionist has received Ops up until the given element,
    /// allows us to push more elements
    final class PushOps: Receptionist.Message {
        // the "sender" of the push
        let peer: OpLogDistributedReceptionist

        /// Overview of all receptionist's latest SeqNr the `peer` receptionist was aware of at time of pushing.
        /// Recipient shall compare these versions and pull from appropriate nodes.
        ///
        /// Guaranteed to be keyed with `.actorIdentity`.
        // Yes, we're somewhat abusing the VV for our "container of sequence numbers",
        // but its merge() facility is quite handy here.
        let observedSeqNrs: VersionVector

        let sequencedOps: [OpLog<ReceptionistOp>.SequencedOp]

        init(peer: OpLogDistributedReceptionist,
             observedSeqNrs: VersionVector,
             sequencedOps: [OpLog<ReceptionistOp>.SequencedOp]) {
            precondition(observedSeqNrs.replicaIDs.allSatisfy { $0.storage.isActorIdentity },
                    "All observed IDs must be keyed with actor identity replica IDs (of the receptionists), was: \(observedSeqNrs)")
            self.peer = peer
            self.observedSeqNrs = observedSeqNrs
            self.sequencedOps = sequencedOps
            super.init()
        }

        // the passed ops cover the range until the following sequenceNr
        func findMaxSequenceNr() -> UInt64 {
            self.sequencedOps.lazy.map { $0.sequenceRange.max }.max() ?? 0
        }

        public enum CodingKeys: CodingKey {
            case peer
            case observedSeqNrs
            case sequencedOps
        }

        public required init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.peer = try container.decode(OpLogDistributedReceptionist.self, forKey: .peer)
            self.observedSeqNrs = try container.decode(VersionVector.self, forKey: .observedSeqNrs)
            self.sequencedOps = try container.decode([OpLog<ReceptionistOp>.SequencedOp].self, forKey: .sequencedOps)
            super.init()
        }

        public override func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.peer, forKey: .peer)
            try container.encode(self.observedSeqNrs, forKey: .observedSeqNrs)
            try container.encode(self.sequencedOps, forKey: .sequencedOps)
        }
    }

    /// Confirms that the remote peer receptionist has received Ops up until the given element,
    /// allows us to push more elements
    final class AckOps: Receptionist.Message, CustomStringConvertible {
        /// Cumulative ACK of all ops until (and including) this one.
        ///
        /// If a recipient has more ops than the `confirmedUntil` confirms seeing, it shall offer
        /// those to the `peer` which initiated this `ConfirmOps`
        let until: UInt64 // inclusive

        let otherObservedSeqNrs: VersionVector

        /// Reference of the sender of this ConfirmOps message,
        /// if more ops are available on the targets op stream, they shall be pushed to this actor.
        let peer: OpLogDistributedReceptionist

        init(appliedUntil: UInt64, observedSeqNrs: VersionVector, peer: OpLogDistributedReceptionist) {
            self.until = appliedUntil
            self.otherObservedSeqNrs = observedSeqNrs
            self.peer = peer
            super.init()
        }

        public enum CodingKeys: CodingKey {
            case until
            case otherObservedSeqNrs
            case peer
        }

        // TODO: annoyance; init MUST be defined here rather than in extension since it is required
        public required init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let until = try container.decode(UInt64.self, forKey: .until)
            let otherObservedSeqNrs = try container.decode(VersionVector.self, forKey: .otherObservedSeqNrs)
            let peer = try container.decode(OpLogDistributedReceptionist.self, forKey: .peer)

            self.until = until
            self.otherObservedSeqNrs = otherObservedSeqNrs
            self.peer = peer
            super.init()
        }

        public override func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.until, forKey: .until)
            try container.encode(self.otherObservedSeqNrs, forKey: .otherObservedSeqNrs)
            try container.encode(self.peer, forKey: .peer)
        }

        var description: String {
            "Receptionist.AckOps(until: \(self.until), otherObservedSeqNrs: \(self.otherObservedSeqNrs), peer: \(self.peer))"
        }
    }

    final class PublishLocalListingsTrigger: Receptionist.Message, NonTransportableActorMessage, CustomStringConvertible {
        override init() {
            super.init()
        }

        public required init(from decoder: Decoder) throws {
            throw SerializationError.nonTransportableMessage(type: "\(Self.self)")
        }

        var description: String {
            "Receptionist.PublishLocalListingsTrigger()"
        }
    }
}

//// ==== ----------------------------------------------------------------------------------------------------------------
//// MARK: Tracelog
//
//extension OpLogDistributedReceptionist {
//    /// Optional "dump all messages" logging.
//    ///
//    /// Enabled by `Settings.traceLogLevel` or `-DSACT_TRACELOG_RECEPTIONIST`
//    func tracelog(
//            _ type: TraceLogType, message: Any,
//            file: String = #file, function: String = #function, line: UInt = #line
//    ) {
//        if let level = system.settings.cluster.receptionist.traceLogLevel {
//            log.log(
//                    level: level,
//                    "[tracelog:receptionist] \(type.description): \(message)",
//                    file: file, function: function, line: line
//            )
//        }
//    }
//
//    internal enum TraceLogType: CustomStringConvertible {
//        case receive(from: ActorRef<Message>?)
//        case push(to: ActorRef<Message>)
//
//        static var receive: TraceLogType {
//            .receive(from: nil)
//        }
//
//        var description: String {
//            switch self {
//            case .receive(nil):
//                return "RECV"
//            case .push(let to):
//                return "PUSH(to:\(to.address))"
//            case .receive(let .some(from)):
//                return "RECV(from:\(from.address))"
//            }
//        }
//    }
//}
