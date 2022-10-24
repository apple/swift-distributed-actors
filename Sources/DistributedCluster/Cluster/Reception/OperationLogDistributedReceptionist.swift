//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import AsyncAlgorithms
import Distributed
import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster (OpLog) Receptionist

/// Cluster-aware (atomic broadcast style, push/pull-gossip) Receptionist implementation.
///
/// ### Intended usage / Optimization choices
/// This Receptionist implementation is optimized towards small to medium clusters (many tens of nodes) with much actor churn,
/// rather than wide (hundreds of nodes) clusters with few registered actors. This implementation is guided by a pragmatic view of
/// how most actor clusters operate, and also in face of the lack of built-in sharding or "virtual namespace" (yet),
/// which would normally be the way to handle millions of actors and tracking their locations (by "sharding" them and
/// moving and tracking them in groups).
///
/// The current implementation gives priority to streaming large amounts of refs between peers, without exceeding
/// a maximum batch size (thus avoiding too large messages, which would lead to head of line blocking of other messages,
/// including heartbeats etc).
///
/// We will re-consider and re-implement this receptionist given other requirements, or allow selecting its mode of operation
/// in the future. E.g. a CRDT based receptionist would be preferable for wide clusters, as we can then avoid the "origin"
/// peer having to stream all data to all peer receptionists. This approach however risks having to gossip a full state
/// when a new nodes join, or potentially for keys where we are unable to propagate _just deltas_. We hope that a future
/// CRDT replicator will be smart enough that we can replace this implementation without fear of too-large messages being
/// put on the wire. We can achieve this in a number of ways (chunking full-state sync into a series of deltas anyway).
/// We will revisit this topic as we implement more advanced CRDT replicators.
///
/// ### Protocol
/// The protocol works on sending individual updates (operations, kind of like an operation based CRDT replicator would),
/// rather than replicating "the entire set of actors registered under a key". The general implementation can be seen as
/// operation-log replication, where each receptionist "owns" its own log and others ask for "replays" of this log once
/// they notice they are behind (i.e. the last sequence nr they observed of the log is older than the latest available).
/// Once other receptionists notice (due to periodic ack gossip carrying "latest observed sequence nrs" of all other receptionists)
/// a receptionist which's sequence nr is newer than they have observed from it, they initiate a pull by sending an
/// an `ack(until: latestAppliedSeqNrFromTarget)`. This causes the owner of the data to initiate a replay of the operations
/// from the `ack.until` sequence nr.
///
/// There are a number of optimizations possible here which will be discussed below, though not all are implemented today.
/// As usual in such schemes, log compaction becomes an important topic, though today we do not offer advanced compaction yet.
///
/// The protocol can be visualized identical state machines acting on incoming operation logs (which inherently separate,
/// and not affecting each other's), like so:
///
/// ```
///                                                     +---------------+
///                                                     |  rec B (@2)   | // Upon receipt of (1), notice that should pull from A,
///                                                 +-->>  A@3,B@2,C@4  | // since A@3 < A@10. It would send (ack <A@3,...>) to initiate a pull.
///      +--------------+       (1)                 |   +---------------+
///      |  rec A (@10) >>---(ack <B@2,...>)--------+
///      | A@10,B@2,C@4 <<---(ops [op,op,...] <>)---+   +---------------+
///      +--------------+       (2)                 |   |   rec C (@9)  | // Caused a different `ack` from A, C knows that A is "behind",
///                                                 +--<< A@10,B@2,C@9  | // and thus replicates its log to A by sending (2) PushOps.
///                                                     +---------------+ // A will confirm and eventually the two peers are in-sync.
///
/// pull == ack - acknowledgements serve also as pull messages, if the ack-ed receptionist sees there is more data to be sent, it does so
///
/// <v> - collection of "latest known" seqNr
/// op  - versioned operation, when applying an op we know up to which `X@n` n seqNr our state has been forwarded to.
/// ```
///
/// #### Observation: Single-writer property of receptionist logs, as they are always "local to a receptionist":
/// Each receptionist only takes care of "their own" actors (i.e. on their own nodes), thus they are the authoritative
/// single-writer source of any information if a ref is registered or not. This is why we can rely on the 1:1 replaying
/// of events. Only a given node's receptionist takes care of the local register/remove, and later on gets pulled for this
/// information by other receptionists -- the other peers will never remove an actor "owned" by another node, unless that
/// node's receptionist tells them to do so. This also means we do not have to watch every single actor that is spread throughout the cluster.
///
/// #### Observation: Fast streaming when needed / periodic small seqNr dissemination
/// It is worth noting that the protocol works effectively in "one mode," meaning that there is no explicit "streaming from a peer"
/// and later "just gossiping" mode. The same message (`AckOps`) is used both to cause a pull, confirmation of receipt of a `PushOps` as well as just spread observed sequence
/// number observations.
///
/// #### Optimization: "Blip" Registration Replication Avoidance
/// We define a "blip registration" as a registration of an actor, which immediately (or very quickly) after registering
/// terminates. It can be argued it is NOT useful to replicate the very existence of such short lived actor to other peers,
/// as even if they'd act on the `register`, it'd be immediately followed by `remove` and/or a termination signal.
///
/// Thanks to the op-log replication scheme, where we gossip pushes in "batch", we can notice such blips and avoid pushing them
/// completely to other nodes. could also avoid sending to peers "blips" i.e. actors which register and immediately terminate.
/// This remains to be debated, but one could argue it is NOT helpful to replicate such short lived ref at all,
/// if we already know it has terminated, thus we can avoid other nodes acting on this ref which they'd immediately
/// be notified has been terminated already.
///
/// The tradeoff here is that subscribing to a key may not be used to get "total number of actors that ever registered under this key globally."
/// We believe this is a sensible tradeoff, as receptionists are only about current and live actors, it MAY however cause weird initialization lockups,
/// where we "know" an actor should have spawned somewhere and registered, but we never see it -- this pattern seems very fragile though so it seems
/// to make sense to discourage it.
///
/// ### Overall protocol outline
/// The goal of the protocol is to replicate a log of "ops" (`register` and `remove` operations), among all receptionists within the cluster.
/// This is achieved by implementing atomic broadcast in the form of replay and re-delivery (pull/acknowledgement driven) of these operations.
/// The operations are replicated directly from the "origin" receptionist ("the receptionist local to the actors which register with it"),
/// to all other peer receptionists by means of them pulling for the ops, once they realize they are "behind." Receptionists periodically
/// gossip their "observed sequence numbers", which is a set of `Receptionist@SequenceNr`. When a receptionist notices that for a given
/// remote receptionist an observed `seqNr` is _lower_ than it has already _applied_ to its state, it performs an ack/pull from that node directly.
///
/// This protocol requires that peers communicate with the "origin" receptionist of an actor to obtain its registration,
/// and therefore is NOT a full gossip implementation. The gossip is only used to detect that a pull shall be performed,
/// and the pull from thereon happens directly between those peers, which the recipient MAY flow control if it so wanted to; TODO: more detailed flow control rather than just the maxChunk?
///
/// Discussion, Upside: This method as upsides which reflect the p2p nature of actor communication, e.g.: Since to obtain a registration of an actor
/// on node `A`, we must communicate with node `A`, this means that if we CANNOT for whatever reason communicate with it (e.g. unreachability),
/// even if we got the reference registration, and emitted it to users, it may end up not being useful.
///
/// Discussion, Downside: Unlike in a full peer to peer gossip replicated receptionist implementation, nodes MUST communicate with the
/// origin receptionist to obtain refs from it. This can cause a "popular node" to get overwhelmed with having to stream to many other
/// nodes its members... In this implementation we considered the tradeoffs and consider smaller clusters but large amounts of actors
/// to be the dominant usage pattern, and thus are less worried about the large fan-out/in-cast of these ops streams. This may change
/// as we face larger clusters and we'd love to explore a full CRDT based implementation that DOES NOT need to full-state-sync periodically
/// (which is the reason we avoided an CRDT implementation in the first place today, as we would have to perform a full-state sync of a potentially
/// _very large_ Dictionary<Key: Set<_ActorRef<T>>).
///
/// 1) Members form a cluster, each has exactly one well known receptionist
/// 2) Upon joining, the new receptionist introduces itself and pulls, by sending ack(until: 0)
/// 3) All receptionists receive this and start a replay for it, from the `0`
///
/// Gossip, of Latest Op SeqNr:
/// - Receptionists gossip about their latestSequenceNr (each has a sequence Nr, associated with add/remove it performs)
/// 1) When a receptionist receives gossip, it looks at the numbers, and if it notices ANY receptionist where it is "behind",
///    i.e. we know A@4, but gossip claims it is @10, then we send to it `ack(4)` which causes the receptionist to reply with
///    its latest information
///  - Pushed information is batched (!), i.e the pushed would send only e.g. 50 updates, yet still inform us with its
///   latest SeqNr, and we'd notice that actually bu now it already is @100, thus we `ack(50)`, and it continues the sending.
///   (Note that we simply always `ack(latest)` and if in the meantime the pusher got more updates, it'll push those to us as well.
///
/// - SeeAlso: [Wikipedia: Atomic broadcast](https://en.wikipedia.org/wiki/Atomic_broadcast)
public distributed actor OpLogDistributedReceptionist: DistributedReceptionist, CustomStringConvertible {
    // TODO: compact the log whenever we know all members of the cluster have seen
    // TODO: Optimization: gap collapsing: [+a,+b,+c,-c] -> [+a,+b,gap(until:4)]
    // TODO: Optimization: head collapsing: [+a,+b,+c,-b,-a] -> [gap(until:2),+c,-b]
    //
    // TODO: slow/fast ticks: When we know there's nothing new to share with others, we use the slow tick (which should be increased to 5 seconds or less)
    //       when we received a register() or observed an "ahead" receptionist, we should schedule a "fast tick" in order to more quickly spread this information
    //       This should still be done on a delay, e.g. if we are receiving many registrations, we want to get the benefit of batching them up before sending after all
    //       The fast tick could be 1s or 0.5s for example as a default.

    public typealias ActorSystem = ClusterSystem

    @ActorID.Metadata(\.wellKnown)
    var wellKnownName: String

    // TODO: remove this
    typealias ReceptionistRef = OpLogDistributedReceptionist
    typealias Key<Guest: DistributedActor> = DistributedReception.Key<Guest> where Guest.ActorSystem == ClusterSystem

    internal let instrumentation: _ReceptionistInstrumentation

    /// Stores the actual mappings of keys to actors.
    let storage = DistributedReceptionistStorage()

    internal enum ReceptionistOp: OpLogStreamOp, Codable {
        case register(key: AnyDistributedReceptionKey, identity: ID)
        case remove(key: AnyDistributedReceptionKey, identity: ID)

        var isRegister: Bool {
            switch self {
            case .register:
                return true
            default:
                return false
            }
        }

        var isRemove: Bool {
            switch self {
            case .remove:
                return true
            default:
                return false
            }
        }

        var key: AnyDistributedReceptionKey {
            switch self {
            case .register(let key, _): return key
            case .remove(let key, _): return key
            }
        }
    }

    lazy var log: Logger = .init(actor: self)

    /// Per known receptionist replayer instances, pointing at the latest confirmed message.
    /// Resuming a replay means getting any ops that were not yet observed by the receptionist.
    ///
    /// Replays are triggered upon receiving an `AckOps`, which simultaneously act as ACKing any previously replayed messages.
    var peerReceptionistReplayers: [ReceptionistRef: OpLog<ReceptionistOp>.Replayer]

    /// Local operations log; Replaying events in it results in restoring the key:actor mappings known to this actor locally.
    let ops: OpLog<ReceptionistOp>

    var membership: Cluster.Membership

    var eventsListeningTask: Task<Void, Error>?

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Timers

    private var slowACKReplicationTimerTask: Task<Void, Error>?
    private var flushTimerTasks: [Int: Task<Void, Error>] = [:]

    /// Important: This safeguards us from the following write amplification scenario:
    ///
    /// Since:
    /// - `AckOps` serves both as an ACK and "poll", and
    /// - `AckOps` is used to periodically spread information
    var nextPeriodicAckPermittedDeadline: [ID: ContinuousClock.Instant]

    /// Sequence numbers of op-logs that we have observed, INCLUDING our own latest op's seqNr.
    /// In other words, each receptionist has their own op-log, and we observe and store the latest seqNr we have seen from them.
    var observedSequenceNrs: VersionVector

    /// Tracks up until what SeqNr we actually have applied the operations to our `storage`.
    ///
    /// The difference between these versions at given peer and the `maxObservedSequenceNr` at given peer,
    /// gives a good idea how far "behind" we are with regards to changed performed at that peer.
    var appliedSequenceNrs: VersionVector

    static var props: _Props {
        var ps = _Props()
        ps._systemActor = true
        ps._wellKnown = true
        ps._knownActorName = ActorPath.distributedActorReceptionist.name
        return ps
    }

    init(settings: ReceptionistSettings, system: ActorSystem) async {
        self.actorSystem = system
        self.instrumentation = system.settings.instrumentation.makeReceptionistInstrumentation()

        self.ops = OpLog(of: ReceptionistOp.self, batchSize: settings.syncBatchSize)
        self.membership = .empty
        self.peerReceptionistReplayers = [:]

        self.nextPeriodicAckPermittedDeadline = [:]

        self.observedSequenceNrs = .empty
        self.appliedSequenceNrs = .empty

        // === listen to cluster events ------------------
        self.wellKnownName = ActorPath.distributedActorReceptionist.name
        assert(self.id.path.description == "/system/receptionist") // TODO(distributed): remove when we remove paths entirely

        self.eventsListeningTask = Task { [weak self, system] in
            for try await event in system.cluster.events {
                guard let __secretlyKnownToBeLocal = self else { return }
                __secretlyKnownToBeLocal.onClusterEvent(event: event)
            }
        }

        // === timers ------------------
        // periodically gossip to other receptionists with the last seqNr we've seen,
        // and if it happens to be outdated by then this will cause a push from that node.
        self.slowACKReplicationTimerTask = Task { [weak self] in
            for await _ in AsyncTimerSequence.repeating(every: system.settings.receptionist.ackPullReplicationIntervalSlow, clock: .continuous) {
                guard let __secretlyKnownToBeLocal = self else { return }
                __secretlyKnownToBeLocal.periodicAckTick()
            }
        }

        self.log.debug("Initialized receptionist")
    }

    deinit {
        self.eventsListeningTask?.cancel()
        self.slowACKReplicationTimerTask?.cancel()
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Receptionist API impl

extension OpLogDistributedReceptionist: LifecycleWatch {
    public nonisolated func checkIn<Guest>(
        _ guest: Guest,
        with key: DistributedReception.Key<Guest>
    ) async where Guest: DistributedActor, Guest.ActorSystem == ClusterSystem {
        await self.whenLocal { __secretlyKnownToBeLocal in
            await __secretlyKnownToBeLocal._checkIn(guest, with: key)
        }
    }

    public nonisolated func checkIn<Guest>(
        _ guest: Guest
    ) async where Guest: DistributedActor, Guest.ActorSystem == ClusterSystem {
        guard let keyID: String = guest.id.metadata.receptionID else {
            fatalError("""
            Attempted to \(#function) distributed actor without `@ActorID.Metadata(\\.receptionID)` set on ActorID!
            Please set the metadata during actor initialization.
            """)
        }
        let key = DistributedReception.Key(Guest.self, id: keyID)

        await self.whenLocal { myself in
            await myself._checkIn(guest, with: key)
        }
    }

    // 'local' implementation of checkIn
    private func _checkIn<Guest>(
        _ guest: Guest,
        with key: DistributedReception.Key<Guest>
    ) async where Guest: DistributedActor, Guest.ActorSystem == ClusterSystem {
        let id = guest.id
        let key = key.asAnyKey

        self.log.debug("Receptionist checkIn [\(guest.id)] with key [\(key)]", metadata: [
            "receptionist/key": "\(key)",
            "receptionist/guest": "\(guest.id)",
        ])

        guard id._isLocal || (id.uniqueNode == actorSystem.cluster.uniqueNode) else {
            self.log.warning("""
            Actor [\(guest.id)] attempted to checkIn under key [\(key)], with NOT-local receptionist! \
            Actors MUST checkIn with their local receptionist in today's Receptionist implementation.
            """)
            return // TODO: This restriction could be lifted; perhaps we can direct the checkIn to the right node?
        }

        let sequenced: OpLog<ReceptionistOp>.SequencedOp =
            self.addOperation(.register(key: key, identity: guest.id))

        if self.storage.addRegistration(sequenced: sequenced, key: key, guest: guest) {
            // self.instrumentation.actorRegistered(key: key, id: id) // TODO(distributed): make the instrumentation calls compatible with distributed actor based types

            watchTermination(of: guest)

            self.log.debug(
                "Registered [\(id)] for key [\(key)]",
                metadata: [
                    "receptionist/key": "\(key)",
                    "receptionist/guest": "\(id)",
                    "receptionist/opLog/maxSeqNr": "\(self.ops.maxSeqNr)",
                    "receptionist/opLog": Logger.MetadataValue.array(
                        self.ops.ops.map { Logger.MetadataValue.string("\($0)") }
                    ),
                ]
            )

            self.ensureDelayedListingFlush(of: key)
        } else {
            self.log.warning("Unable to register \(guest) with receptionist, unknown identity type?", metadata: [
                "guest/id": "\(guest.id)",
                "reception/key": "\(key)",
            ])
        }

        // Replication of is done in periodic tics, thus we do not perform a push here.

        // TODO: reply "registered"?
    }

    public nonisolated func listing<Guest>(
        of key: DistributedReception.Key<Guest>,
        file: String = #fileID, line: UInt = #line
    ) async -> DistributedReception.GuestListing<Guest>
        where Guest: DistributedActor, Guest.ActorSystem == ClusterSystem
    {
        DistributedReception.GuestListing<Guest>(receptionist: self, key: key, file: file, line: line)
    }

    public nonisolated func listing<Guest>(
        of _: Guest.Type,
        file: String = #fileID, line: UInt = #line
    ) async -> DistributedReception.GuestListing<Guest>
        where Guest: DistributedActor, Guest.ActorSystem == ClusterSystem
    {
        DistributedReception.GuestListing<Guest>(receptionist: self, key: Key<Guest>(), file: file, line: line)
    }

    // 'local' impl for 'listing'
    func _listing(
        subscription: AnyDistributedReceptionListingSubscription,
        file: String = #fileID, line: UInt = #line
    ) {
        if self.storage.addSubscription(key: subscription.key, subscription: subscription) {
            // self.instrumentation.actorSubscribed(key: anyKey, id: self.id._unwrapActorID) // FIXME: remove the address parameter, it does not make sense anymore
            self.log.trace("Subscribed async sequence to \(subscription.key)", metadata: [
                "subscription/key": "\(subscription.key)",
                "subscription/callSite": "\(file):\(line)",
            ])

            // We immediately flush all already-known registrations;
            // as new ones come in, they will be reported to this subscription later on
            for alreadyRegisteredAtSubscriptionTime in self.storage.registrations(forKey: subscription.key) ?? [] {
                if subscription.tryOffer(registration: alreadyRegisteredAtSubscriptionTime) {
                    self.log.debug("Offered \(alreadyRegisteredAtSubscriptionTime.actorID) to subscription \(subscription)")
                } else {
                    self.log.warning("Dropped \(alreadyRegisteredAtSubscriptionTime.actorID) on subscription \(subscription)")
                }
            }
        }
    }

    func _cancelSubscription(
        subscription: AnyDistributedReceptionListingSubscription
    ) {
        self.log.trace("Cancel subscription [\(subscription.subscriptionID)]", metadata: [
            "subscription/key": "\(subscription.key)",
        ])
        self.storage.removeSubscription(key: subscription.key, subscription: subscription)
    }

    public nonisolated func lookup<Guest>(_ key: DistributedReception.Key<Guest>) async -> Set<Guest>
        where Guest: DistributedActor, Guest.ActorSystem == ClusterSystem
    {
        await self.whenLocal { __secretlyKnownToBeLocal in
            __secretlyKnownToBeLocal._lookup(key)
        } ?? []
    }

    private func _lookup<Guest>(_ key: DistributedReception.Key<Guest>) -> Set<Guest>
        where Guest: DistributedActor, Guest.ActorSystem == ClusterSystem
    {
        guard let registrations = self.storage.registrations(forKey: key.asAnyKey) else {
            return []
        }

        // self.instrumentation.listingPublished(key: message._key, subscribers: 1, registrations: registrations.count) // TODO(distributed): make the instrumentation calls compatible with distributed actor based types
        var guests: Set<Guest> = []
        guests.reserveCapacity(registrations.count)
        for versioned in registrations {
            do {
                let guest = try Guest.resolve(id: versioned.actorID, using: self.actorSystem)
                guests.insert(guest)
            } catch is DeadLetterError {
                // This just means that this `lookup` arrived before the `terminated` of this specific actor as it terminated.
                // This specific actor is already dead, so there's no need to emit it in our listing.
                //
                // The terminated arrives asynchronously and will arrive a bit later;
                // We can also just cause the terminated eagerly over here
                self.actorTerminated(id: versioned.actorID)
                continue
            } catch {
                self.actorSystem.log.debug("Failed to resolve guest for listing key \(key)", metadata: [
                    "actor/id": "\(versioned.actorID)",
                    "actor/type": "\(Guest.self)",
                    "error": "\(error)",
                ])
            }
        }

        return guests
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Delayed (Listing Notification) Flush

extension OpLogDistributedReceptionist {
    func ensureDelayedListingFlush(of key: AnyDistributedReceptionKey) {
        if self.storage.registrations(forKey: key)?.isEmpty ?? true {
            self.log.debug("notify now, no need to schedule delayed flush")
            self.notifySubscribers(of: key)
            return // no need to schedule, there are no registered actors at all, we eagerly emit this info
        }

        let timerTaskKey = key.hashValue
        guard self.flushTimerTasks[timerTaskKey] == nil else {
            self.log.trace("Delayed listing flush timer task already exists (key: \(key))")
            return // timer exists nothing to do
        }

        // TODO: also flush when a key has seen e.g. 100 changes?
        let flushDelay = actorSystem.settings.receptionist.listingFlushDelay
        self.log.debug("schedule delayed flush")
        self.flushTimerTasks[timerTaskKey] = Task { [weak self] in
            defer {
                if let __secretlyKnownToBeLocal = self {
                    __secretlyKnownToBeLocal.flushTimerTasks.removeValue(forKey: timerTaskKey)
                }
            }

            try await Task.sleep(until: .now + flushDelay, clock: .continuous)
            guard let __secretlyKnownToBeLocal = self else { return }
            __secretlyKnownToBeLocal.onDelayedListingFlushTick(key: key)
        }
    }

    func onDelayedListingFlushTick(key: AnyDistributedReceptionKey) {
        self.log.trace("Run delayed listing flush, key: \(key)")
        self.notifySubscribers(of: key)
    }

    private func notifySubscribers(of key: AnyDistributedReceptionKey) {
        guard let subscriptions = self.storage.subscriptions(forKey: key) else {
            // self.instrumentation.listingPublished(key: key, subscribers: 0, registrations: registrations.count) // TODO(distributed): make the instrumentation calls compatible with distributed actor based types
            self.log.debug("No one is listening for key \(key)")
            return // ok, no-one to notify
        }

        // Sort registrations by version from oldest to newest so that they are processed in order.
        // Otherwise, if we process a newer version (i.e., with bigger sequence number) first, older
        // versions will be dropped because they are considered "seen".
        let registrations = (self.storage.registrations(forKey: key) ?? []).sorted { l, r in l.version < r.version } // FIXME: use ordered set or Deque now that we have them
        self.log.notice(
            "Registrations to flush: \(registrations.count)",
            metadata: [
                "registrations": Logger.MetadataValue.array(
                    registrations.map { Logger.MetadataValue.string("\($0)") }
                ),
            ]
        )

        // self.instrumentation.listingPublished(key: key, subscribers: subscriptions.count, registrations: registrations.count) // TODO(distributed): make the instrumentation calls compatible with distributed actor based types
        for subscription in subscriptions {
            self.log.notice("Offering registrations to subscription: \(subscription))", metadata: [
                "registrations": "\(subscription.seenActorRegistrations)",
            ])

            for registration in registrations {
                if subscription.tryOffer(registration: registration) {
                    self.log.notice("OFFERED \(registration.actorID) TO \(subscription)")
                } else {
                    self.log.notice("DROPPED \(registration.actorID) TO \(subscription)")
                }
            }
        }
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
        let peerReplicaId: ReplicaID = .actorID(push.peer.id)
        let lastAppliedSeqNrAtPeer = self.appliedSequenceNrs[peerReplicaId]

        // De-duplicate
        // In case we got re-sends (the other node sent us some data twice, yet we already have it, we do not replay the already known data),
        // we do not want to apply the same ops twice, so we skip the already known ones
        let opsToApply = push.sequencedOps.drop(while: { op in
            op.sequenceRange.max <= lastAppliedSeqNrAtPeer
        })

        self.log.trace(
            "Received \(push.sequencedOps.count) ops",
            metadata: [
                "receptionist/peer": "\(push.peer.id)",
                "receptionist/lastKnownSeqNrAtPeer": "\(lastAppliedSeqNrAtPeer)",
                "receptionist/opsToApply": Logger.Metadata.Value.array(opsToApply.map { Logger.Metadata.Value.string("\($0)") }),
            ]
        )

        /// Collect which keys have been updated during this push, so we can publish updated listings for them.
        var keysToPublish: Set<AnyDistributedReceptionKey> = []
        for op in opsToApply {
            keysToPublish.insert(self.applyIncomingOp(from: peer, op))
        }

        self.log.trace("Keys to publish: \(keysToPublish)")

        // 1.2) update our observed version of `pushed.peer` to the incoming
        self.observedSequenceNrs.merge(other: push.observedSeqNrs)
        self.appliedSequenceNrs.merge(other: .init(push.findMaxSequenceNr(), at: peerReplicaId))

        // 2) check for all peers if we are "behind", and should pull information from them
        //    if this message indicated "end" of the push, then we assume we are up to date with it
        //    and will only pull again from it on the SlowACK
        let myselfReplicaID: ReplicaID = .actorID(self.id)
        // Note that we purposefully also skip replying to the peer (sender) to the sender of this push yet,
        // we will do so below in any case, regardless if we are behind or not; See (4) for ACKing the peer
        for replica in push.observedSeqNrs.replicaIDs
            where replica != peerReplicaId && replica != myselfReplicaID &&
            self.observedSequenceNrs[replica] < push.observedSeqNrs[replica]
        {
            switch replica.storage {
            case .actorID(let id):
                self.sendAckOps(receptionistID: id)
            default:
                fatalError("Only .actorID supported as replica ID, was: \(replica.storage)")
            }
        }

        // 3) Push listings for any keys that we have updated during this batch
        keysToPublish.forEach { key in
            self.publishListings(forKey: key)
        }

        // 4) ACK that we processed the ops, if there's any more to be replayed
        //    the peer will then send us another chunk of data.
        //    IMPORTANT: We want to confirm until the _latest_ number we know about
        self.sendAckOps(receptionistID: peer.id, maybeReceptionistRef: peer)

        // 5) Since we just received ops from `peer` AND also sent it an `AckOps`,
        //    there is no need to send it another _periodic_ AckOps potentially right after.
        //    We DO want to send the Ack directly here as potentially the peer still has some more
        //    ops it might want to send, so we want to allow it to get those over to us as quickly as possible,
        //    without waiting for our Ack ticks to trigger (which could be configured pretty slow).
        let nextPeriodicAckAllowedIn: Duration = actorSystem.settings.receptionist.ackPullReplicationIntervalSlow * 2
        self.nextPeriodicAckPermittedDeadline[peer.id] = .fromNow(nextPeriodicAckAllowedIn) // TODO: system.timeSource
    }

    /// Apply incoming operation from `peer` and update the associated applied sequenceNumber tracking
    ///
    /// - Returns: Set of keys which have been updated during this
    func applyIncomingOp(
        from peer: OpLogDistributedReceptionist,
        _ sequenced: OpLog<ReceptionistOp>.SequencedOp
    ) -> AnyDistributedReceptionKey {
        let op = sequenced.op

        // apply operation to storage
        switch op {
        case .register(let anyKey, let identity):
            // We resolve a stub that we cannot really ever send messages to, but we can "watch" it
            let resolved = actorSystem._resolveStub(id: identity)

            watchTermination(of: resolved)
            if self.storage.addRegistration(sequenced: sequenced, key: anyKey, guest: resolved) {
                // self.instrumentation.actorRegistered(key: key, id: id) // TODO(distributed): make the instrumentation calls compatible with distributed actor based types
            }

        case .remove(let anyKey, let id):
            let resolved = actorSystem._resolveStub(id: id)

            unwatchTermination(of: resolved)
            if self.storage.removeRegistration(key: anyKey, guest: resolved) != nil {
                // self.instrumentation.actorRemoved(key: key, id: id) // TODO(distributed): make the instrumentation calls compatible with distributed actor based types
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
        receptionistID: ID,
        maybeReceptionistRef: ReceptionistRef? = nil
    ) {
        assert(
            maybeReceptionistRef == nil || maybeReceptionistRef?.id == receptionistID,
            "Provided receptionistRef does NOT match passed Address, this is a bug in receptionist."
        )
        guard case .remote = receptionistID._location else {
            return // this would mean we tried to pull from a "local" receptionist, bail out
        }

        guard self.membership.contains(receptionistID.uniqueNode) else {
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
                peerReceptionistRef = try ReceptionistRef.resolve(id: receptionistID, using: actorSystem)
            } catch {
                return fatalErrorBacktrace("Unable to resolve receptionist: \(receptionistID)")
            }
        }

        // Get the latest seqNr of the op that we have applied to our state
        // If we never applied anything, this automatically is `0`, and by sending an `ack(0)`,
        // we effectively initiate the "first pull"
        let latestAppliedSeqNrFromPeer = self.appliedSequenceNrs[.actorID(receptionistID)]

        Task { [weak self] in
            do {
                guard let __secretlyKnownToBeLocal = self else { return } // FIXME: we need `local`
                try await peerReceptionistRef.ackOps(until: latestAppliedSeqNrFromPeer, by: __secretlyKnownToBeLocal)
            } catch {
                switch error {
                case let remoteCallError as RemoteCallError where isIgnorable(remoteCallError):
                    // ignore silently; clusterAlreadyShutDown often happens during tests when we terminate systems
                    // while interacting with them. timedOut is also expected to happen sometimes.
                    ()
                default:
                    log.error("Error: \(error)")
                }
            }

            func isIgnorable(_ error: RemoteCallError) -> Bool {
                switch error.underlying.error {
                case .clusterAlreadyShutDown, .timedOut:
                    return true
                default:
                    return false
                }
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

    private func publishListings(
        forKey key: AnyDistributedReceptionKey,
        to subscriptions: Set<AnyDistributedReceptionListingSubscription>
    ) {
        let registrations = self.storage.registrations(forKey: key) ?? []

        self.log.trace(
            "Publishing listing [\(key)]",
            metadata: [
                "receptionist/key": "\(key.id)",
                "receptionist/registrations": "\(registrations.count)",
                "receptionist/subscribers": "\(subscriptions.count)",
            ]
        )

        for subscription in subscriptions {
            for registration in registrations {
                if subscription.tryOffer(registration: registration) {
                    self.log.notice("OFFERED \(registration.actorID) TO \(subscription)")
                } else {
                    self.log.notice("DROPPED \(registration.actorID) TO \(subscription)")
                }
            }
        }
    }

    /// Send `AckOps` to to peers (unless prevented to by silence period because we're already conversing/streaming with one)
    // TODO: This should pick a few at random rather than ping everyone
    func periodicAckTick() {
        self.log.trace("Periodic ack tick")

        for peer in self.peerReceptionistReplayers.keys {
            /// In order to avoid sending spurious acks which would cause the peer to start delivering from the acknowledged `until`,
            /// e.g. while it is still in the middle of sending us more ops, we avoid sending more acks earlier than a regular "tick"
            /// from the point in time we last received ops from this peer. In practice this means:
            /// - if we are in the middle of an ack/ops exchange between us and the peer, we will not send another ack here -- an eager one (not timer based) was already sent
            ///   - if the eager ack would has been lost, this timer will soon enough trigger again, and we'll deliver the ack this way
            /// - if we are NOT in the middle of receiving ops, we share our observed versions and ack as means of spreading information about the seen SeqNrs
            ///   - this may cause the other peer to pull (ack) from any other peer receptionist, if it notices it is "behind" with regards to any of them. // FIXME: what if a peer notices "twice" so we also need to prevent a timer from resending that ack?
            if let periodicAckAllowedAgainDeadline = self.nextPeriodicAckPermittedDeadline[peer.id],
               periodicAckAllowedAgainDeadline.hasTimeLeft()
            {
                // we still cannot send acks to this peer, it is in the middle of a message exchange with us already
                continue
            }

            // the deadline is clearly overdue, so we remove the value completely to avoid them piling up in there even as peers terminate
            _ = self.nextPeriodicAckPermittedDeadline.removeValue(forKey: peer.id)

            self.sendAckOps(receptionistID: peer.id, maybeReceptionistRef: peer)
        }
    }

    /// Receive an Ack and potentially continue streaming ops to peer if still pending operations available.
    distributed func ackOps(until: UInt64, by peer: ReceptionistRef) {
        var replayer = self.peerReceptionistReplayers[peer]

        if replayer == nil, until == 0 {
            self.log.debug("Received message from \(peer), but no replayer available, create one ad-hoc now", metadata: [
                "peer": "\(peer.id.uniqueNode)",
            ])
            // TODO: Generally we should trigger a `onNewClusterMember` but seems we got a message before that triggered
            // Seems ordering became less strict here with DA unfortunately...?
            replayer = self.ops.replay(from: .beginning)
        }

        guard var replayer = replayer else {
            self.log.trace("Received a confirmation until \(until) from \(peer) but no replayer available for it, ignoring", metadata: [
                "receptionist/peer/confirmed": "\(until)",
                "receptionist/peer": "\(peer.id)",
                "replayers": "\(self.peerReceptionistReplayers)",
            ])
            return
        }

        replayer.confirm(until: until)
        self.peerReceptionistReplayers[peer] = replayer

        self.replicateOpsBatch(to: peer)
    }

    private func replicateOpsBatch(to peer: ReceptionistRef) {
        self.log.trace("Replicate ops to: \(peer.id)")
        guard peer.id != self.id else {
            self.log.trace("No need to replicate to myself: \(peer.id)")
            return // no reason to stream updates to myself
        }

        guard let replayer = self.peerReceptionistReplayers[peer] else {
            self.log.trace("Attempting to continue replay but no replayer available for it, ignoring", metadata: [
                "receptionist/peer": "\(peer.id)",
            ])
            return
        }

        let sequencedOps = replayer.nextOpsChunk()
        guard !sequencedOps.isEmpty else {
            self.log.trace("No ops to replay", metadata: [
                "receptionist/peer": "\(peer.id)",
                "receptionist/ops/replay/atSeqNr": "\(replayer.atSeqNr)",
            ])
            return // nothing to stream, done
        }

        self.log.debug(
            "Streaming \(sequencedOps.count) ops: from [\(replayer.atSeqNr)]",
            metadata: [
                "receptionist/peer": "\(peer.id)",
                "receptionist/ops/replay/atSeqNr": "\(replayer.atSeqNr)",
                "receptionist/ops/maxSeqNr": "\(self.ops.maxSeqNr)",
            ]
        ) // TODO: metadata pattern

        let pushOps = PushOps(
            peer: self,
            observedSeqNrs: self.observedSequenceNrs,
            sequencedOps: Array(sequencedOps)
        )

        Task {
            do {
                log.debug("Push operations: \(pushOps)", metadata: [
                    "receptionist/peer": "\(peer.id)",
                ])
                try await peer.pushOps(pushOps)
            } catch {
                log.error("Failed to pushOps: \(pushOps)", metadata: [
                    "receptionist/peer": "\(peer.id)",
                    "error": "\(error)",
                ])
            }
        }
    }

    private func addOperation(_ op: ReceptionistOp) -> OpLog<ReceptionistOp>.SequencedOp {
        let sequenced = self.ops.add(op)
        switch op {
        case .register:
            actorSystem.metrics._receptionist_registrations.increment()
        case .remove:
            actorSystem.metrics._receptionist_registrations.decrement()
        }

        let latestSelfSeqNr = VersionVector(self.ops.maxSeqNr, at: .actorID(self.id))
        self.observedSequenceNrs.merge(other: latestSelfSeqNr)
        self.appliedSequenceNrs.merge(other: latestSelfSeqNr)

        actorSystem.metrics._receptionist_oplog_size.record(self.ops.count)
        return sequenced
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Termination handling

extension OpLogDistributedReceptionist {
    public func terminated(actor id: ID) {
        if id == ActorID._receptionist(on: id.uniqueNode, for: .distributedActors) {
            self.log.debug("Watched receptionist terminated: \(id)")
            self.receptionistTerminated(identity: id)
        } else {
            self.log.debug("Watched actor terminated: \(id)")
            self.actorTerminated(id: id)
        }
    }

    private func receptionistTerminated(identity id: ID) {
        self.pruneClusterMember(removedNode: id.uniqueNode)
    }

    private func actorTerminated(id: ID) {
        let wasRegisteredWithKeys = self.storage.removeFromKeyMappings(id)

        // In case we manually caused an `actorTerminated` already, or if the actor
        // just was never registered to begin with, just ignore it completely and don't
        // even log this removal attempt; Can't remove something that wasn't added.
        guard !wasRegisteredWithKeys.registeredUnderKeys.isEmpty else {
            return
        }

        for key in wasRegisteredWithKeys.registeredUnderKeys {
            _ = self.addOperation(.remove(key: key, identity: id))
            self.publishListings(forKey: key)
        }

        self.log.trace("Actor terminated \(id), and removed from receptionist.")
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
            self.log.debug(
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

        case ._PLEASE_DO_NOT_EXHAUSTIVELY_MATCH_THIS_ENUM_NEW_CASES_MIGHT_BE_ADDED_IN_THE_FUTURE:
            self.log.error("Received Cluster.Event [\(event)]. This should not happen, please file an issue.")
        }
    }

    private func onNewClusterMember(change: Cluster.MembershipChange) {
        guard change.previousStatus == nil else {
            return // not a new member
        }

        guard change.node != actorSystem.cluster.uniqueNode else {
            return // no need to contact our own node, this would be "us"
        }

        self.log.debug("New member, contacting its receptionist: \(change.node)")

        // resolve receptionist on the other node, so we can stream our registrations to it
        let remoteReceptionistAddress = ActorID._receptionist(on: change.node, for: .distributedActors)
        let remoteReceptionist = try! Self.resolve(id: remoteReceptionistAddress, using: actorSystem) // try!-safe: we know this resolve won't throw, the identity is known to be correct

        // ==== "push" replication -----------------------------
        // we noticed a new member, and want to offer it our information right away

        // store the remote receptionist and replayer, it shall always use the same replayer
        let replayer = self.ops.replay(from: .beginning)
        self.peerReceptionistReplayers[remoteReceptionist] = replayer

        self.replicateOpsBatch(to: remoteReceptionist)
    }

    func pruneClusterMember(removedNode: UniqueNode) {
        self.log.trace("Pruning cluster member: \(removedNode)")
        let terminatedReceptionistID = ActorID._receptionist(on: removedNode, for: .distributedActors)
        let equalityHackPeer = try! Self.resolve(id: terminatedReceptionistID, using: actorSystem) // try!-safe because we know the address is correct and remote

        guard self.peerReceptionistReplayers.removeValue(forKey: equalityHackPeer) != nil else {
            // we already removed it, so no need to keep scanning for it.
            // this could be because we received a receptionist termination before a node down or vice versa.
            //
            // although this should not happen and may indicate we got a Terminated for an address twice?
            return
        }

        // clear observations; we only get them directly from the origin node, so since it has been downed
        // we will never receive more observations from it.
        _ = self.observedSequenceNrs.pruneReplica(.actorID(terminatedReceptionistID))
        _ = self.appliedSequenceNrs.pruneReplica(.actorID(terminatedReceptionistID))

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

        init(
            peer: OpLogDistributedReceptionist,
            observedSeqNrs: VersionVector,
            sequencedOps: [OpLog<ReceptionistOp>.SequencedOp]
        ) {
            precondition(
                observedSeqNrs.replicaIDs.allSatisfy(\.storage.isActorID),
                "All observed IDs must be keyed with actor address replica IDs (of the receptionists), was: \(observedSeqNrs)"
            )
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

        required init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.peer = try container.decode(OpLogDistributedReceptionist.self, forKey: .peer)
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
            let peer = try container.decode(OpLogDistributedReceptionist.self, forKey: .peer)

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

    final class PublishLocalListingsTrigger: Receptionist.Message, _NotActuallyCodableMessage, CustomStringConvertible {
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
