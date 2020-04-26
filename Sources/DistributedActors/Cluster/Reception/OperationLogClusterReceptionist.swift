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

import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster (OpLog) Receptionist

/// ClusterReceptionist namespace
public enum ClusterReceptionist {}

/// Cluster-aware (atomic broadcast style, push/pull-gossip) Receptionist implementation.
///
/// ### Intended usage / Optimization choices
/// This Receptionist implementation is optimized towards small to medium clusters clusters (many tens of nodes) with much actor churn,
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
// TODO: compact the log whenever we know all members of the cluster have seen
// TODO: Optimization: gap collapsing: [+a,+b,+c,-c] -> [+a,+b,gap(until:4)]
// TODO: Optimization: head collapsing: [+a,+b,+c,-b,-a] -> [gap(until:2),+c,-b]
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
// TODO: slow/fast ticks: When we know there's nothing new to share with others, we use the slow tick (which should be increased to 5 seconds or less)
///       when we received a register() or observed an "ahead" receptionist, we should schedule a "fast tick" in order to more quickly spread this information
///       This should still be done on a delay, e.g. if we are receiving many registrations, we want to get the benefit of batching them up before sending after all
///       The fast tick could be 1s or 0.5s for example as a default.
///
/// #### Optimization: "Blip" Registration Replication Avoidance TODO: This is done "automatically" once we do log compaction
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
/// _very large_ Dictionary<Key: Set<ActorRef<T>>).
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
public class OperationLogClusterReceptionist {
    typealias Message = Receptionist.Message
    typealias ReceptionistRef = ActorRef<Message>

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Timer Keys

    static let slowACKReplicationTick: TimerKey = "slow-ack-replication-tick"
    static let fastACKReplicationTick: TimerKey = "fast-ack-replication-tick"

    static let localPublishLocalListingsTick: TimerKey = "publish-local-listings-tick"

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: State

    /// Stores the actual mappings of keys to actors.
    let storage = Receptionist.Storage()

    internal enum ReceptionistOp: OpLogStreamOp, Codable {
        case register(key: AnyRegistrationKey, address: ActorAddress)
        case remove(key: AnyRegistrationKey, address: ActorAddress)

        var key: AnyRegistrationKey {
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
    var peerReceptionistReplayers: [ActorRef<Message>: OpLog<ReceptionistOp>.Replayer]

    /// Local operations log; Replaying events in it results in restoring the key:actor mappings known to this actor locally.
    let ops: OpLog<ReceptionistOp>

    var membership: Cluster.Membership

    /// Important: This safeguards us from the following write amplification scenario:
    ///
    /// Since:
    /// - `AckOps` serves both as an ACK and "poll", and
    /// - `AckOps` is used to periodically spread information
    var nextPeriodicAckPermittedDeadline: [ActorRef<Message>: Deadline]

    /// Sequence numbers of op-logs that we have observed, INCLUDING our own latest op's seqNr.
    /// In other words, each receptionist has their own op-log, and we observe and store the latest seqNr we have seen from them.
    var observedSequenceNrs: VersionVector

    /// Tracks up until what SeqNr we actually have applied the operations to our `storage`.
    ///
    /// The difference between these versions at given peer and the `maxObservedSequenceNr` at given peer,
    /// gives a good idea how far "behind" we are with regards to changed performed at that peer.
    var appliedSequenceNrs: VersionVector

    internal init(settings: ClusterReceptionist.Settings) {
        self.ops = .init(batchSize: settings.syncBatchSize)
        self.membership = .empty
        self.peerReceptionistReplayers = [:]

        self.observedSequenceNrs = .empty
        self.appliedSequenceNrs = .empty

        self.nextPeriodicAckPermittedDeadline = [:]
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Behavior

    var behavior: Behavior<Message> {
        .setup { context in
            context.log.debug("Initialized receptionist")

            // === listen to cluster events ------------------
            context.system.cluster.events.subscribe(
                context.subReceive(Cluster.Event.self) { event in
                    try self.onClusterEvent(context, event: event)
                }
            )

            // === timers ------------------
            // periodically gossip to other receptionists with the last seqNr we've seen,
            // and if it happens to be outdated by then this will cause a push from that node.
            context.timers.startPeriodic(
                key: Self.slowACKReplicationTick, message: Self.PeriodicAckTick(),
                interval: context.system.settings.cluster.receptionist.ackPullReplicationIntervalSlow
            )

            // === behavior -----------
            return Behavior<Receptionist.Message>.receiveMessage {
                self.tracelog(context, .receive, message: $0)
                switch $0 {
                case let push as PushOps:
                    self.receiveOps(context, push: push)
                case let ack as AckOps:
                    self.receiveAckOps(context, until: ack.until, by: ack.peer)

                case _ as PeriodicAckTick:
                    self.onPeriodicAckTick(context)

                case let message as _Register:
                    try self.onRegister(context: context, message: message)

                case let message as _Lookup:
                    try self.onLookup(context: context, message: message)

                case let message as _Subscribe:
                    try self.onSubscribe(context: context, message: message)

                default:
                    context.log.warning("Received unexpected message: \(String(reflecting: $0)), \(type(of: $0))")
                }
                return .same
            }.receiveSpecificSignal(Signals.Terminated.self) { _, terminated in
                context.log.warning("Terminated: \(terminated)")
                if let node = terminated.address.node,
                    terminated.address == ActorAddress._receptionist(on: node) {
                    // receptionist terminated, need to prune it
                    self.onReceptionistTerminated(context, terminated: terminated)
                } else {
                    // just some actor terminated, we need to remove it from storage and spread its removal
                    self.onActorTerminated(context, terminated: terminated)
                }
                return .same
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Receptionist API impl

extension OperationLogClusterReceptionist {
    private func onSubscribe(context: ActorContext<Message>, message: _Subscribe) throws {
        let boxedMessage = message._boxed
        let key = AnyRegistrationKey(from: message._key)
        if self.storage.addSubscription(key: key, subscription: boxedMessage) {
            context.watch(message._addressableActorRef)
            context.log.info("Subscribed \(message._addressableActorRef.address) to \(key)")
            boxedMessage.replyWith(self.storage.registrations(forKey: key) ?? [])
        }
    }

    private func onLookup(context: ActorContext<Message>, message: _Lookup) throws {
        message.replyWith(self.storage.registrations(forKey: message._key.asAnyRegistrationKey) ?? [])
    }

    private func onRegister(context: ActorContext<Message>, message: _Register) throws {
        let key = message._key.asAnyRegistrationKey
        let ref = message._addressableActorRef

        guard ref.address.isLocal || (ref.address.node == context.system.cluster.node) else {
            context.log.warning("""
            Actor [\(ref)] attempted to register under key [\(key)], with NOT-local receptionist! \
            Actors MUST register with their local receptionist in today's Receptionist implementation.
            """)
            return // TODO: This restriction could be lifted; perhaps we can direct the register to the right node?
        }

        if self.storage.addRegistration(key: key, ref: ref) {
            context.watch(ref)

            var addressWithNode = ref.address
            addressWithNode.node = context.system.cluster.node

            self.addOperation(context, .register(key: key, address: addressWithNode))

            context.log.debug(
                "Registered [\(ref.address)] for key [\(key)]",
                metadata: [
                    "receptionist/key": "\(key)",
                    "receptionist/registered": "\(ref)",
                    "receptionist/opLog/maxSeqNr": "\(self.ops.maxSeqNr)",
                ]
            )

            if let subscribed = self.storage.subscriptions(forKey: key) {
                let registrations = self.storage.registrations(forKey: key) ?? []
                for subscription in subscribed {
                    subscription._replyWith(registrations)
                }
            }
        }

        // ---
        // Replication of is done in periodic tics, thus we do not perform a push here.
        // ---
        // TODO: enable "fast tick"

        message.replyRegistered()
    }

    private func addOperation(_ context: ActorContext<Message>, _ op: ReceptionistOp) {
        self.ops.add(op)
        switch op {
        case .register:
            context.system.metrics._receptionist_registrations.increment()
        case .remove:
            context.system.metrics._receptionist_registrations.decrement()
        }

        let latestSelfSeqNr = VersionVector(self.ops.maxSeqNr, at: .actorAddress(context.myself.address))
        self.observedSequenceNrs.merge(other: latestSelfSeqNr)
        self.appliedSequenceNrs.merge(other: latestSelfSeqNr)

        context.system.metrics._receptionist_oplog_size.record(self.ops.count)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Op replication

extension OperationLogClusterReceptionist {
    /// Received a push of ops; apply them to the local view of the key space (storage).
    ///
    /// The incoming ops will be until some max SeqNr, once we have applied them all,
    /// we send back an `ack(maxSeqNr)` to both confirm the receipt, as well as potentially trigger
    /// more ops being delivered
    func receiveOps(_ context: ActorContext<Message>, push: PushOps) {
        let peer = push.peer

        // 1.1) apply the pushed ops to our state
        let peerReplicaId: ReplicaID = .actorAddress(push.peer.address)
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
                "receptionist/peer": "\(push.peer.address)",
                "receptionist/lastKnownSeqNrAtPeer": "\(lastAppliedSeqNrAtPeer)",
                "receptionist/opsToApply": Logger.Metadata.Value.array(opsToApply.map { Logger.Metadata.Value.string("\($0)") }),
            ]
        )

        /// Collect which keys have been updated during this push, so we can publish updated listings for them.
        var keysToPublish: Set<AnyRegistrationKey> = []
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
        let myselfReplicaID: ReplicaID = .actorAddress(context.myself.address)
        // Note that we purposefully also skip replying to the peer (sender) to the sender of this push yet,
        // we will do so below in any case, regardless if we are behind or not; See (4) for ACKing the peer
        for replica in push.observedSeqNrs.replicaIDs
            where replica != peerReplicaId && replica != myselfReplicaID &&
            self.observedSequenceNrs[replica] < push.observedSeqNrs[replica] {
            switch replica {
            case .actorAddress(let address):
                self.sendAckOps(context, receptionistAddress: address)
            default:
                fatalError("Only .actorAddress supported as replica ID")
            }
        }

        // 3) Push listings for any keys that we have updated during this batch
        keysToPublish.forEach { key in
            self.publishListings(context, forKey: key)
        }

        // 4) ACK that we processed the ops, if there's any more to be replayed
        //    the peer will then send us another chunk of data.
        //    IMPORTANT: We want to confirm until the _latest_ number we know about
        self.sendAckOps(context, receptionistAddress: peer.address, maybeReceptionistRef: peer)

        // 5) Since we just received ops from `peer` AND also sent it an `AckOps`,
        //    there is no need to send it another _periodic_ AckOps potentially right after.
        //    We DO want to send the Ack directly here as potentially the peer still has some more
        //    ops it might want to send, so we want to allow it to get those over to us as quickly as possible,
        //    without waiting for our Ack ticks to trigger (which could be configured pretty slow).
        let nextPeriodicAckAllowedIn: TimeAmount = context.system.settings.cluster.receptionist.ackPullReplicationIntervalSlow * 2
        self.nextPeriodicAckPermittedDeadline[peer] = Deadline.fromNow(nextPeriodicAckAllowedIn) // TODO: context.system.timeSource
    }

    /// Apply incoming operation from `peer` and update the associated applied sequenceNumber tracking
    ///
    /// - Returns: Set of keys which have been updated during this
    func applyIncomingOp(_ context: ActorContext<Message>, from peer: ActorRef<Message>, _ sequenced: OpLog<ReceptionistOp>.SequencedOp) -> AnyRegistrationKey {
        let op = sequenced.op

        // apply operation to storage
        switch op {
        case .register(let key, let address):
            let resolved = context.system._resolveUntyped(context: .init(address: address, system: context.system))
            context.watch(resolved)
            _ = self.storage.addRegistration(key: key, ref: resolved)

        case .remove(let key, let address):
            let resolved = context.system._resolveUntyped(context: .init(address: address, system: context.system))
            context.unwatch(resolved)
            _ = self.storage.removeRegistration(key: key, ref: resolved)
        }

        // update the version up until which we updated the state
        self.appliedSequenceNrs.merge(other: VersionVector(sequenced.sequenceRange.max, at: .actorAddress(peer.address)))

        return op.key
    }

    /// Acknowledge the latest applied sequence number we have from the passed in receptionist.
    ///
    /// This simultaneously acts as a "pull" conceptually, since we send an `AckOps` which confirms the latest we've applied
    /// as well as potentially causing further data to be sent.
    private func sendAckOps(
        _ context: ActorContext<Message>,
        receptionistAddress: ActorAddress,
        maybeReceptionistRef: ReceptionistRef? = nil
    ) {
        assert(maybeReceptionistRef == nil || maybeReceptionistRef?.address == receptionistAddress, "Provided receptionistRef does NOT match passed Address, this is a bug in receptionist.")
        guard let receptionistNode = receptionistAddress.node else {
            return // this would mean we tried to pull from a "local" receptionist, bail out
        }

        guard self.membership.contains(receptionistNode) else {
            // node is either not known to us yet, OR has been downed and removed
            // avoid talking to it until we see it in membership.
            return
        }

        let peerReceptionistRef: ReceptionistRef
        if let ref = maybeReceptionistRef {
            peerReceptionistRef = ref // allows avoiding to have to perform a resolve here
        } else {
            peerReceptionistRef = context.system._resolve(context: .init(address: receptionistAddress, system: context.system))
        }

        // Get the latest seqNr of the op that we have applied to our state
        // If we never applied anything, this automatically is `0`, and by sending an `ack(0)`,
        // we effectively initiate the "first pull"
        let latestAppliedSeqNrFromPeer = self.appliedSequenceNrs[.actorAddress(receptionistAddress)]

        let ack = AckOps(
            appliedUntil: latestAppliedSeqNrFromPeer,
            observedSeqNrs: self.observedSequenceNrs,
            peer: context.myself
        )

        tracelog(context, .push(to: peerReceptionistRef), message: ack)
        peerReceptionistRef.tell(ack)
    }

    /// Listings have changed for this key, thus we need to publish them to all subscribers
    private func publishListings(_ context: ActorContext<Message>, forKey key: AnyRegistrationKey) {
        guard let subscribers = self.storage.subscriptions(forKey: key) else {
            return // no subscribers for this key
        }

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
    private func onPeriodicAckTick(_ context: ActorContext<Message>) {
        for peer in self.peerReceptionistReplayers.keys {
            /// In order to avoid sending spurious acks which would cause the peer to start delivering from the acknowledged `until`,
            /// e.g. while it is still in the middle of sending us more ops, we avoid sending more acks earlier than a regular "tick"
            /// from the point in time we last received ops from this peer. In practice this means:
            /// - if we are in the middle of an ack/ops exchange between us and the peer, we will not send another ack here -- an eager one (not timer based) was already sent
            ///   - if the eager ack would has been lost, this timer will soon enough trigger again, and we'll deliver the ack this way
            /// - if we are NOT in the middle of receiving ops, we share our observed versions and ack as means of spreading information about the seen SeqNrs
            ///   - this may cause the other peer to pull (ack) from any other peer receptionist, if it notices it is "behind" with regards to any of them. // FIXME: what if a peer notices "twice" so we also need to prevent a timer from resending that ack?
            if let periodicAckAllowedAgainDeadline = self.nextPeriodicAckPermittedDeadline[peer],
                periodicAckAllowedAgainDeadline.hasTimeLeft() {
                // we still cannot send acks to this peer, it is in the middle of a message exchange with us already
                continue
            }

            // the deadline is clearly overdue, so we remove the value completely to avoid them piling up in there even as peers terminate
            _ = self.nextPeriodicAckPermittedDeadline.removeValue(forKey: peer)

            self.sendAckOps(context, receptionistAddress: peer.address, maybeReceptionistRef: peer)
        }
    }

    /// Receive an Ack and potentially continue streaming ops to peer if still pending operations available.
    private func receiveAckOps(_ context: ActorContext<Message>, until: UInt64, by peer: ActorRef<OperationLogClusterReceptionist.Message>) {
        guard var replayer = self.peerReceptionistReplayers[peer] else {
            context.log.trace("Received a confirmation until \(until) from \(peer) but no replayer available for it, ignoring")
            return
        }

        replayer.confirm(until: until)
        self.peerReceptionistReplayers[peer] = replayer

        self.replicateOpsBatch(context, to: peer)
    }

    private func replicateOpsBatch(_ context: ActorContext<Message>, to peer: ActorRef<Receptionist.Message>) {
        guard peer.address != context.address else {
            return // no reason to stream updates to myself
        }

        guard let replayer = self.peerReceptionistReplayers[peer] else {
            context.log.trace("Attempting to continue replay for \(peer) but no replayer available for it, ignoring")
            return
        }

        let sequencedOps = replayer.nextOpsChunk()
        guard !sequencedOps.isEmpty else {
            return // nothing to stream, done
        }

        context.log.debug(
            "Streaming \(sequencedOps.count) ops: from [\(replayer.atSeqNr)]",
            metadata: [
                "receptionist/peer": "\(peer.address)",
                "receptionist/ops/replay/atSeqNr": "\(replayer.atSeqNr)",
                "receptionist/ops/maxSeqNr": "\(self.ops.maxSeqNr)",
            ]
        ) // TODO: metadata pattern

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
            fatalError("Remote receptionists MUST be of .remote personality, was: \(peer.personality), \(peer.address)")
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Termination handling

extension OperationLogClusterReceptionist {
    private func onReceptionistTerminated(_ context: ActorContext<Message>, terminated: Signals.Terminated) {
        if let node = terminated.address.node {
            self.pruneClusterMember(context, removedNode: node)
        } else {
            context.log.warning("Receptionist [\(terminated.address)] terminated however has no `node` set, this is highly suspect. It would mean this is 'us', but that cannot be.")
        }
    }

    private func onActorTerminated(_ context: ActorContext<Message>, terminated: Signals.Terminated) {
        self.onActorTerminated(context, address: terminated.address)
    }

    private func onActorTerminated(_ context: ActorContext<Message>, address: ActorAddress) {
        let equalityHackRef = ActorRef<Never>(.deadLetters(.init(context.log, address: address, system: nil)))
        let wasRegisteredWithKeys = self.storage.removeFromKeyMappings(equalityHackRef.asAddressable())

        for key in wasRegisteredWithKeys {
            self.addOperation(context, .remove(key: key, address: address))
            self.publishListings(context, forKey: key)
        }

        context.log.trace("Actor terminated \(address), and removed from receptionist.")
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Handle Cluster Events

extension OperationLogClusterReceptionist {
    private func onClusterEvent(_ context: ActorContext<Message>, event: Cluster.Event) throws {
        switch event {
        case .snapshot(let snapshot):
            let diff = Cluster.Membership._diff(from: .empty, to: snapshot)
            guard !diff.changes.isEmpty else {
                return // empty changes, nothing to act on
            }
            context.log.debug(
                "Changes from initial snapshot, applying one by one",
                metadata: [
                    "membership/changes": "\(diff.changes)",
                ]
            )
            try diff.changes.forEach { change in
                try self.onClusterEvent(context, event: .membershipChange(change))
            }

        case .membershipChange(let change):
            guard let effectiveChange = self.membership.applyMembershipChange(change) else {
                return
            }

            if effectiveChange.fromStatus == nil {
                // a new member joined, let's store and contact its receptionist
                self.onNewClusterMember(context, change: effectiveChange)
            } else if effectiveChange.toStatus.isAtLeastDown {
                // a member was removed, we should prune it from our observations
                self.pruneClusterMember(context, removedNode: effectiveChange.node)
            }

        case .leadershipChange, .reachabilityChange:
            return // we ignore those
        }
    }

    private func onNewClusterMember(_ context: ActorContext<OperationLogClusterReceptionist.Message>, change: Cluster.MembershipChange) {
        guard change.fromStatus == nil else {
            return // not a new member
        }

        guard change.node != context.system.cluster.node else {
            return // no need to contact our own node, this would be "us"
        }

        context.log.debug("New member, contacting its receptionist: \(change.node)")

        // resolve receptionist on the other node, so we can stream our registrations to it
        let remoteReceptionistAddress = ActorAddress._receptionist(on: change.node)
        let remoteReceptionist: ActorRef<Message> = context.system._resolve(context: .init(address: remoteReceptionistAddress, system: context.system))

        // ==== "push" replication -----------------------------
        // we noticed a new member, and want to offer it our information right away

        // store the remote receptionist and replayer, it shall always use the same replayer
        let replayer = self.ops.replay(from: .beginning)
        self.peerReceptionistReplayers[remoteReceptionist] = replayer

        self.replicateOpsBatch(context, to: remoteReceptionist)
    }

    private func pruneClusterMember(_ context: ActorContext<OperationLogClusterReceptionist.Message>, removedNode: UniqueNode) {
        let terminatedReceptionistAddress = ActorAddress._receptionist(on: removedNode)
        let equalityHackPeerRef = ActorRef<Message>(.deadLetters(.init(context.log, address: terminatedReceptionistAddress, system: nil)))

        guard self.peerReceptionistReplayers.removeValue(forKey: equalityHackPeerRef) != nil else {
            // we already removed it, so no need to keep scanning for it.
            // this could be because we received a receptionist termination before a node down or vice versa.
            //
            // although this should not happen and may indicate we got a Terminated for an address twice?
            return
        }

        // clear observations; we only get them directly from the origin node, so since it has been downed
        // we will never receive more observations from it.
        _ = self.observedSequenceNrs.pruneReplica(.actorAddress(terminatedReceptionistAddress))
        _ = self.appliedSequenceNrs.pruneReplica(.actorAddress(terminatedReceptionistAddress))

        // clear state any registrations still lingering about the now-known-to-be-down node
        self.storage.pruneNode(removedNode)
    }
}

// ==== ------------------------------------------------------------------------------------------------------------
// MARK: Extra Messages

extension OperationLogClusterReceptionist {
    /// Confirms that the remote peer receptionist has received Ops up until the given element,
    /// allows us to push more elements
    class PushOps: Receptionist.Message {
        // the "sender" of the push
        let peer: ActorRef<Receptionist.Message>

        /// Overview of all receptionist's latest SeqNr the `peer` receptionist was aware of at time of pushing.
        /// Recipient shall compare these versions and pull from appropriate nodes.
        ///
        /// Guaranteed to be keyed with `.actorAddress`. // FIXME ensure this
        // Yes, we're somewhat abusing the VV for our "container of sequence numbers",
        // but its merge() facility is quite handy here.
        let observedSeqNrs: VersionVector

        let sequencedOps: [OpLog<ReceptionistOp>.SequencedOp]

        init(peer: ActorRef<Receptionist.Message>, observedSeqNrs: VersionVector, sequencedOps: [OpLog<ReceptionistOp>.SequencedOp]) {
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

        // TODO: annoyance; init MUST be defined here rather than in extension since it is required
        public required init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.peer = try container.decode(ActorRef<Receptionist.Message>.self, forKey: .peer)
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
    class AckOps: Receptionist.Message, CustomStringConvertible {
        /// Cumulative ACK of all ops until (and including) this one.
        ///
        /// If a recipient has more ops than the `confirmedUntil` confirms seeing, it shall offer
        /// those to the `peer` which initiated this `ConfirmOps`
        let until: UInt64 // inclusive

        let otherObservedSeqNrs: VersionVector

        /// Reference of the sender of this ConfirmOps message,
        /// if more ops are available on the targets op stream, they shall be pushed to this actor.
        let peer: ActorRef<Receptionist.Message>

        init(appliedUntil: UInt64, observedSeqNrs: VersionVector, peer: ActorRef<Receptionist.Message>) {
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
            let peer = try container.decode(ActorRef<Receptionist.Message>.self, forKey: .peer)

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

    internal class PeriodicAckTick: Receptionist.Message, NonTransportableActorMessage, CustomStringConvertible {
        override init() {
            super.init()
        }

        public required init(from decoder: Decoder) throws {
            throw SerializationError.nonTransportableMessage(type: "\(Self.self)")
        }

        var description: String {
            "Receptionist.PeriodicAckTick()"
        }
    }

    internal class PublishLocalListingsTrigger: Receptionist.Message, NonTransportableActorMessage, CustomStringConvertible {
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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Tracelog

extension OperationLogClusterReceptionist {
    /// Optional "dump all messages" logging.
    ///
    /// Enabled by `Settings.traceLogLevel` or `-DSACT_TRACELOG_RECEPTIONIST`
    func tracelog(
        _ context: ActorContext<Message>, _ type: TraceLogType, message: Any,
        file: String = #file, function: String = #function, line: UInt = #line
    ) {
        if let level = context.system.settings.cluster.receptionist.traceLogLevel {
            context.log.log(
                level: level,
                "[tracelog:receptionist] \(type.description): \(message)",
                file: file, function: function, line: line
            )
        }
    }

    internal enum TraceLogType: CustomStringConvertible {
        case receive(from: ActorRef<Message>?)
        case push(to: ActorRef<Message>)

        static var receive: TraceLogType {
            .receive(from: nil)
        }

        var description: String {
            switch self {
            case .receive(nil):
                return "RECV"
            case .push(let to):
                return "PUSH(to:\(to.address))"
            case .receive(let .some(from)):
                return "RECV(from:\(from.address))"
            }
        }
    }
}
