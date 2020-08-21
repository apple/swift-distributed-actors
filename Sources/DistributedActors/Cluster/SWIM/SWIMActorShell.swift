//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ClusterMembership
import enum Dispatch.DispatchTimeInterval
import Logging
import SWIM

/// The SWIM shell is responsible for driving all interactions of the `SWIM.Instance` with the outside world.
///
/// - SeeAlso: `SWIM.Instance` for detailed documentation about the SWIM protocol implementation.
internal struct SWIMActorShell {
    typealias MyselfContext = ActorContext<SWIM.Message>

    let swim: SWIM.Instance
    let clusterRef: ClusterShell.Ref

    var settings: SWIM.Settings {
        self.swim.settings
    }

    internal init(_ swim: SWIM.Instance, clusterRef: ClusterShell.Ref) {
        self.swim = swim
        self.clusterRef = clusterRef
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Behaviors

    /// Initial behavior, kicks off timers and becomes `ready`.
    static func behavior(settings: SWIM.Settings, clusterRef: ClusterShell.Ref) -> Behavior<SWIM.Message> {
        .setup { context in
            var settings = settings
            settings.logger = context.log
            settings.logger.logLevel = .trace
            let swim = SWIM.Instance(
                settings: settings,
                myself: context.myself
            )
            let shell = SWIMActorShell(swim, clusterRef: clusterRef)
            shell.onStart(context: context)

            return SWIMActorShell.ready(shell: shell)
        }
    }

    static func ready(shell: SWIMActorShell) -> Behavior<SWIM.Message> {
        .receive { context, wrappedMessage in
            switch wrappedMessage {
            case .remote(let message):
                shell.receiveRemoteMessage(message: message, context: context)
                return .same

            case .local(let message):
                shell.receiveLocalMessage(message: message, context: context)
                return .same

            case ._testing(let message):
                switch message {
                case .getMembershipState(let replyTo):
                    replyTo.tell(SWIM._MembershipState(membershipState: shell.swim.allMembers))
                    return .same
                }
            }
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Periodic Protocol Ticks

    /// Initialize timers and other after-initialized tasks
    private func onStart(context: MyselfContext) {
        // Immediately attempt to connect to initial contact points
        self.settings.initialContactPoints.forEach { node in
            self.swim.addMember(node.swimRef(context), status: .alive(incarnation: 0)) // assume the best case; we'll find out soon enough its real status
        }

        // Kick off timer for periodically pinging random cluster member (i.e. the periodic Gossip)
        let probeInterval: TimeAmount = .nanoseconds(settings.probeInterval.nanoseconds) // convert to Actors time amount
        context.timers.startSingle(key: SWIM.Shell.periodicPingKey, message: .local(SWIM.LocalMessage.pingRandomMember), delay: probeInterval)
    }

    /// Scheduling a new protocol period and performing the actions for the current protocol period
    func handlePeriodicProtocolPeriodTick(context: MyselfContext) {
        self.handlePeriodicTick(context: context)

        let delayTimeAmount: TimeAmount = .nanoseconds(self.swim.dynamicLHMProtocolInterval.nanoseconds)
        context.timers.startSingle(key: SWIM.Shell.periodicPingKey, message: .local(.pingRandomMember), delay: delayTimeAmount)
    }

    func handlePeriodicTick(context: MyselfContext) {
        // needs to be done first, so we can gossip out the most up to date state
        self.checkSuspicionTimeouts(context: context) // FIXME: Push into SWIM

        let directive = self.swim.onPeriodicPingTick()
        switch directive {
        case .ignore:
            context.log.trace("Skipping periodic ping", metadata: self.swim.metadata)

        case .sendPing(let target, let timeout, let sequenceNumber):
            context.log.trace("Periodic ping random member, among: \(self.swim.otherMemberCount)", metadata: self.swim.metadata)
            self.sendPing(to: target, pingRequestOriginPeer: nil, timeout: timeout, sequenceNumber: sequenceNumber, context: context)
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Receiving messages

    func receiveRemoteMessage(message: SWIM.RemoteMessage, context: MyselfContext) {
        switch message {
        case .ping(let replyTo, let payload, let sequenceNumber):
            self.handlePing(context: context, replyTo: replyTo, payload: payload, sequenceNumber: sequenceNumber)

        case .pingRequest(let target, let replyTo, let payload, let sequenceNumber):
            self.handlePingRequest(target: target, replyTo: replyTo, payload: payload, sequenceNumber: sequenceNumber, context: context)
        }
    }

    private func handlePing(context: MyselfContext, replyTo: ActorRef<SWIM.PingResponse>, payload: SWIM.GossipPayload, sequenceNumber: SWIM.SequenceNumber) {
        context.log.trace("Received ping@\(sequenceNumber)", metadata: self.swim.metadata([
            "swim/ping/replyTo": "\(replyTo.address)",
            "swim/ping/payload": "\(payload)",
            "swim/ping/seqNr": "\(sequenceNumber)",
        ]))

        let directives: [SWIM.Instance.PingDirective] = self.swim.onPing(payload: payload, sequenceNumber: sequenceNumber)
        directives.forEach { directive in
            switch directive {
            case .gossipProcessed(let gossipDirective):
                self.handleGossipPayloadProcessedDirective(gossipDirective, context: context)

            case .sendAck(let myself, let incarnation, let payload, let sequenceNumber):
                replyTo.ack(acknowledging: sequenceNumber, target: myself, incarnation: incarnation, payload: payload)
            }
        }
    }

    private func handlePingRequest(
        target: SWIM.Ref,
        replyTo: SWIM.PingOriginRef,
        payload: SWIM.GossipPayload,
        sequenceNumber pingRequestSequenceNumber: SWIM.SequenceNumber,
        context: MyselfContext
    ) {
        context.log.trace("Received pingRequest@\(pingRequestSequenceNumber) [\(target)] from [\(replyTo)]", metadata: self.swim.metadata([
            "swim/pingRequest/replyTo": "\(replyTo.address)",
            "swim/pingRequest/payload": "\(payload)",
            "swim/pingRequest/seqNr": "\(pingRequestSequenceNumber)",
        ]))

        let directives: [SWIM.Instance.PingRequestDirective] = self.swim.onPingRequest(target: target, replyTo: replyTo, payload: payload)
        directives.forEach { directive in
            switch directive {
            case .gossipProcessed(let gossipDirective):
                self.handleGossipPayloadProcessedDirective(gossipDirective, context: context)

            case .sendPing(let target, let pingRequestOriginPeer, let timeout, let sequenceNumber):
                self.sendPing(to: target, pingRequestOriginPeer: pingRequestOriginPeer, timeout: timeout, sequenceNumber: sequenceNumber, context: context)

            case .ignore:
                context.log.trace("Ignoring ping request", metadata: self.swim.metadata([
                    "swim/pingReq/sequenceNumber": "\(pingRequestSequenceNumber)",
                    "swim/pingReq/target": "\(target)",
                    "swim/pingReq/replyTo": "\(replyTo)",
                ]))
            }
        }

//        if !self.swim.isMember(target) {
//            self.withEnsuredAssociation(context, remoteNode: target.address.node) { result in
//                switch result {
//                case .success:
//                    // The case when member is a suspect is already handled in `processGossipPayload`, since
//                    // payload will always contain suspicion about target member
//                    self.swim.addMember(target, status: .alive(incarnation: 0)) // TODO: push into SWIM?
//                    self.sendPing(to: target, pingRequestOriginPeer: replyTo, context: context)
//                case .failure(let error):
//                    context.log.warning("Unable to obtain association for remote \(target.address)... Maybe it was tombstoned? Error: \(error)")
//                }
//            }
//        } else {
//            self.sendPing(to: target, pingRequestOriginPeer: replyTo, context: context)
//        }
    }

    func receiveLocalMessage(message: SWIM.LocalMessage, context: MyselfContext) {
        switch message {
        case .pingRandomMember:
            self.handlePeriodicProtocolPeriodTick(context: context)

        case .monitor(let node):
            self.handleStartMonitoring(node: node, context: context)

        case .confirmDead(let node):
            self.handleConfirmDead(deadNode: node, context: context)
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Sending ping, ping-req and friends

    /// - parameter pingRequestOrigin: is set only when the ping that this is a reply to was originated as a `pingReq`.
    func sendPing(
        to target: SWIMPeer,
        pingRequestOriginPeer: SWIMPingOriginPeer?,
        timeout: DispatchTimeInterval,
        sequenceNumber: SWIM.SequenceNumber,
        context: MyselfContext
    ) {
        let payload = self.swim.makeGossipPayload(to: target)

        context.log.trace("Sending ping", metadata: self.swim.metadata([
            "swim/target": "\(target.node)",
            "swim/gossip/payload": "\(payload)",
            "swim/timeout": "\(timeout)",
        ]))

        let promise = context.system._eventLoopGroup.next().makePromise(of: SWIM.PingResponse.self)
        target.ping(payload: payload, from: context.myself, timeout: timeout, sequenceNumber: sequenceNumber) { result in
            promise.completeWith(result)
        }

        context.onResultAsync(of: promise.futureResult, timeout: .effectivelyInfinite) { result in
            switch result {
            case .success(let pingResponse):
                self.handlePingResponse(response: pingResponse, pingRequestOrigin: pingRequestOriginPeer, error: nil, context: context)
            case .failure(let error):
                self.handlePingResponse(
                    response: .timeout(
                        target: target,
                        pingRequestOrigin: pingRequestOriginPeer,
                        timeout: timeout,
                        sequenceNumber: sequenceNumber
                    ),
                    pingRequestOrigin: pingRequestOriginPeer,
                    error: error,
                    context: context
                )
            }

            return .same
        }
    }

    func sendPingRequests(_ directive: SWIM.Instance.SendPingRequestDirective, context: MyselfContext) {
        // We are only interested in successful pings, as a single success tells us the node is
        // still alive. Therefore we propagate only the first success, but no failures.
        // The failure case is handled through the timeout of the whole operation.
        let eventLoop = context.system._eventLoopGroup.next()
        let firstSuccessful = eventLoop.makePromise(of: SWIM.PingResponse.self)
        let pingTimeout = self.swim.dynamicLHMPingTimeout
        let peerToPing = directive.target
        for pingRequest in directive.requestDetails {
            let memberToPingRequestThrough = pingRequest.memberToPingRequestThrough
            let payload = pingRequest.payload
            let sequenceNumber = pingRequest.sequenceNumber

            context.log.trace("Sending ping request for [\(peerToPing)] to [\(memberToPingRequestThrough)] with payload: \(payload)")

            let peerToPingRequestThrough = memberToPingRequestThrough.node.swimRef(context)

            // self.tracelog(.send(to: peerToPingRequestThrough), message: "pingRequest(target: \(nodeToPing), replyTo: \(self.peer), payload: \(payload), sequenceNumber: \(sequenceNumber))")
            let eachReplyPromise = eventLoop.makePromise(of: SWIM.PingResponse.self)
            peerToPingRequestThrough.pingRequest(target: peerToPing, payload: payload, from: context.myself, timeout: pingTimeout, sequenceNumber: sequenceNumber) { result in
                eachReplyPromise.completeWith(result)
            }
            context.onResultAsync(of: eachReplyPromise.futureResult, timeout: .effectivelyInfinite) { result in
                switch result {
                case .success(let response):
                    self.handleEveryPingRequestResponse(response: response, pinged: peerToPing, context: context)
                    if case .ack = response {
                        // We only cascade successful ping responses (i.e. `ack`s);
                        //
                        // While this has a slight timing implication on time timeout of the pings -- the node that is last
                        // in the list that we ping, has slightly less time to fulfil the "total ping timeout"; as we set a total timeout on the entire `firstSuccess`.
                        // In practice those timeouts will be relatively large (seconds) and the few millis here should not have a large impact on correctness.
                        firstSuccessful.succeed(response)
                    }
                case .failure(let error):
                    self.handleEveryPingRequestResponse(
                        response: .timeout(
                            target: peerToPing,
                            pingRequestOrigin: context.myself,
                            timeout: pingTimeout,
                            sequenceNumber: sequenceNumber
                        ),
                        pinged: peerToPing,
                        context: context
                    )
                    // these are generally harmless thus we do not want to log them on higher levels
                    context.log.trace("Failed pingRequest", metadata: [
                        "swim/target": "\(peerToPing)",
                        "swim/payload": "\(payload)",
                        "swim/pingTimeout": "\(pingTimeout)",
                        "error": "\(error)",
                    ])
                }
                return .same
            }
        }

        context.onResultAsync(of: firstSuccessful.futureResult, timeout: .effectivelyInfinite) { result in
            switch result {
            case .success(let response):
                self.handlePingRequestResponse(response: response, pinged: peerToPing, context: context)
            case .failure(let error):
                context.log.debug("Failed to sendPingRequests", metadata: [
                    "error": "\(error)",
                ])
                self.handlePingRequestResponse(response: .timeout(target: peerToPing, pingRequestOrigin: context.myself, timeout: pingTimeout, sequenceNumber: 0), pinged: peerToPing, context: context) // FIXME: that sequence number...
            }
            return .same
        }
    }

    func handlePingResponse(
        response: SWIM.PingResponse,
        pingRequestOrigin: SWIMPingOriginPeer?,
        error: Error?,
        context: MyselfContext
    ) {
        let sequenceNumber = response.sequenceNumber
        if let error = error {
            context.log.warning("Receive failed ping response: \(response)", metadata: self.swim.metadata([
                "swim/pingRequest/origin": "\(pingRequestOrigin, orElse: "nil")",
                "swim/response/sequenceNumber": "\(sequenceNumber)",
                "error": "\(error)",
            ]))
        } else {
            context.log.warning("Receive ping response: \(response)", metadata: self.swim.metadata([
                "swim/pingRequest/origin": "\(pingRequestOrigin, orElse: "nil")",
                "swim/response/sequenceNumber": "\(sequenceNumber)",
            ]))
        }

        let directives = self.swim.onPingResponse(response: response, pingRequestOrigin: pingRequestOrigin)
        // optionally debug log all directives here
        directives.forEach { directive in
            switch directive {
            case .gossipProcessed(let gossipDirective):
                self.handleGossipPayloadProcessedDirective(gossipDirective, context: context)

            case .sendAck(let pingRequestOrigin, let acknowledging, let target, let incarnation, let payload):
                pingRequestOrigin.ack(acknowledging: acknowledging, target: target, incarnation: incarnation, payload: payload)

            case .sendNack(let pingRequestOrigin, let acknowledging, let target):
                pingRequestOrigin.nack(acknowledging: acknowledging, target: target)

            case .sendPingRequests(let pingRequestDirective):
                self.sendPingRequests(pingRequestDirective, context: context)
            }
        }
    }

    /// We have to handle *every* response, because they adjust the value of the timeouts we'll be using in future probes.
    func handleEveryPingRequestResponse(response: SWIM.PingResponse, pinged: SWIMPeer, context: MyselfContext) {
        // self.tracelog(.receive(pinged: pinged.node), message: "\(response)")
        self.swim.onEveryPingRequestResponse(response, pingedMember: pinged)
    }

    func handlePingRequestResponse(response: SWIM.PingResponse, pinged: SWIMPeer, context: MyselfContext) {
        // self.tracelog(context, .receive(pinged: pinged), message: response)

        let directives = self.swim.onPingRequestResponse(response, pingedMember: pinged)
        directives.forEach {
            switch $0 {
            case .gossipProcessed(let gossipDirective):
                self.handleGossipPayloadProcessedDirective(gossipDirective, context: context)

            case .alive(let previousStatus):
                context.log.debug("Member [\(pinged)] is alive")
                if previousStatus.isUnreachable, let member = swim.member(for: pinged) {
                    // member was unreachable but now is alive, we should emit an event
                    let event = SWIM.MemberStatusChangedEvent(previousStatus: previousStatus, member: member) // FIXME: make SWIM emit an option of the event
                    self.tryAnnounceMemberReachability(change: event, context: context)
                }

            case .newlySuspect:
                context.log.debug("Member [\(pinged)] marked as suspect")

            case .nackReceived:
                context.log.debug("Received `nack` from indirect probing of [\(pinged)]")
            default:
                () // TODO: revisit logging more details here
            }
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handling local messages

    func handleStartMonitoring(node: UniqueNode, context: MyselfContext) {
        guard context.system.cluster.uniqueNode.node != node.node else {
            return // no need to monitor ourselves, nor a replacement of us (if node is our replacement, we should have been dead already)
        }

        self.sendFirstRemotePing(on: node, context)
    }

    // TODO: test in isolation
    // FIXME: push into SWIM Instance
    func handleConfirmDead(deadNode uniqueNode: UniqueNode, context: MyselfContext) {
        let node = ClusterMembership.Node(uniqueNode: uniqueNode)
        if let member = self.swim.member(for: node) {
            // It is important to not infinitely loop cluster.down + confirmDead messages;
            // See: `.confirmDead` for more rationale
            if member.isDead {
                return // member is already dead, nothing else to do here.
            }

            context.log.trace("Confirming .dead member \(reflecting: member.node)")

            // We are diverging from the SWIM paper here in that we store the `.dead` state, instead
            // of removing the node from the member list. We do that in order to prevent dead nodes
            // from being re-added to the cluster.
            // TODO: add time of death to the status
            // TODO: GC tombstones after a day

            switch self.swim.mark(member.peer, as: .dead) {
            case .applied(let .some(previousState), _):
                if previousState.isSuspect || previousState.isUnreachable {
                    context.log.warning(
                        "Marked [\(member)] as [.dead]. Was marked \(previousState) in protocol period [\(member.protocolPeriod)]",
                        metadata: [
                            "swim/protocolPeriod": "\(self.swim.protocolPeriod)",
                            "swim/member": "\(member)", // TODO: make sure it is the latest status of it in here
                        ]
                    )
                } else {
                    context.log.warning(
                        "Marked [\(member)] as [.dead]. Node was previously [.alive], and now forced [.dead].",
                        metadata: [
                            "swim/protocolPeriod": "\(self.swim.protocolPeriod)",
                            "swim/member": "\(member)", // TODO: make sure it is the latest status of it in here
                        ]
                    )
                }
            case .applied(nil, _):
                // TODO: marking is more about "marking a node as dead" should we rather log addresses and not actor paths?
                context.log.warning("Marked [\(member)] as [.dead]. Node was not previously known to SWIM.")
                // TODO: should we not issue a escalateUnreachable here? depends how we learnt about that node...

            case .ignoredDueToOlderStatus:
                // TODO: make sure a fatal error in SWIM.Shell causes a system shutdown?
                fatalError("Marking [\(member)] as [.dead] failed! This should never happen, dead is the terminal status. SWIM instance: \(self.swim)")
            }
        } else {
            context.log.warning("Attempted to .confirmDead(\(node)), yet no such member known to \(self)!") // TODO: would want to see if this happens when we fail these tests
            // even if not known, we invent such node and store it as dead
            self.swim.addMember(node.swimRef(context), status: .dead)
        }
    }

    func checkSuspicionTimeouts(context: MyselfContext) {
        context.log.trace(
            "Checking suspicion timeouts...",
            metadata: [
                "swim/suspects": "\(self.swim.suspects)",
                "swim/all": Logger.MetadataValue.array(self.swim.allMembers.map { "\($0)" }),
                "swim/protocolPeriod": "\(self.swim.protocolPeriod)",
            ]
        )

        for suspect in self.swim.suspects {
            if case .suspect(_, let suspectedBy) = suspect.status {
                let suspicionTimeout = self.swim.suspicionTimeout(suspectedByCount: suspectedBy.count)
                context.log.trace(
                    "Checking suspicion timeout for: \(suspect)...",
                    metadata: [
                        "swim/suspect": "\(suspect)",
                        "swim/suspectedBy": "\(suspectedBy.count)",
                        "swim/suspicionTimeout": "\(suspicionTimeout)",
                    ]
                )

                // proceed with suspicion escalation to .unreachable if the timeout period has been exceeded
                // We don't use Deadline because tests can override TimeSource
                guard let startTime = suspect.suspicionStartedAt,
                    self.swim.isExpired(deadline: startTime + suspicionTimeout.nanoseconds) else {
                    continue // skip, this suspect is not timed-out yet
                }

                guard let incarnation = suspect.status.incarnation else {
                    // suspect had no incarnation number? that means it is .dead already and should be recycled soon
                    return
                }

                var unreachableSuspect = suspect
                unreachableSuspect.status = .unreachable(incarnation: incarnation)
                self.markMember(context, latest: unreachableSuspect)
            }
        }

        context.system.metrics.recordSWIMMembers(self.swim.allMembers)
    }

    private func markMember(_ context: MyselfContext, latest: SWIM.Member) {
        switch self.swim.mark(latest.peer, as: latest.status) {
        case .applied(let previousStatus, _):
            context.log.trace(
                "Marked \(latest.node) as \(latest.status), announcing reachability change",
                metadata: [
                    "swim/member": "\(latest)",
                    "swim/previousStatus": "\(previousStatus, orElse: "nil")",
                ]
            )
            let statusChange = SWIM.MemberStatusChangedEvent(previousStatus: previousStatus, member: latest)
            self.tryAnnounceMemberReachability(change: statusChange, context: context)
        case .ignoredDueToOlderStatus:
            () // context.log.trace("No change \(latest), currentStatus remains [\(currentStatus)]. No reachability change to announce")
        }
    }

    func handleGossipPayloadProcessedDirective(_ directive: SWIM.Instance.GossipProcessedDirective, context: MyselfContext) {
        switch directive {
        case .connect:
            () // we don't need connections, just starting to talk to an actor ref will cause connections

        case .ignored(let level, let message): // TODO: allow the instance to log
            if let level = level, let message = message {
                context.log.log(level: level, message, metadata: self.swim.metadata)
            }

        case .applied(let change, _, _):
            self.tryAnnounceMemberReachability(change: change, context: context)
        }
    }

    func processGossipedMembership(_ directive: SWIM.Instance.GossipProcessedDirective, context: MyselfContext) {
        switch directive {
        case .connect:
            () // we don't need connections, we'll simply establish ones the first time we talk to a remote peer actor

        case .ignored(let level, let message): // TODO: allow the instance to log
            if let level = level, let message = message {
                context.log.log(level: level, message, metadata: self.swim.metadata)
            }

        case .applied(let change, _, _):
            self.tryAnnounceMemberReachability(change: change, context: context)
        }
//        for member in members {
//            case .connect(let node, let continueAddingMember):
//            switch self.swim.onGossipPayload(about: member) {
//                // ensuring a connection is asynchronous, but executes callback in actor context
//                self.withEnsuredAssociation(context, remoteNode: node) { uniqueAddressResult in
//                    switch uniqueAddressResult {
//                    case .success(let uniqueAddress):
//                        continueAddingMember(.success(uniqueAddress))
//                    case .failure(let error):
//                        continueAddingMember(.failure(error))
//                        context.log.warning("Unable ensure association with \(node), could it have been tombstoned? Error: \(error)")
//                    }
//                }
//
//            case .ignored(let level, let message):
//                if let level = level, let message = message {
//                    context.log.log(level: level, message, metadata: self.swim.metadata)
//                }
//
//            case .applied(let change, _, _):
//                self.tryAnnounceMemberReachability(change: change, context: context)
//            }
//        }
//    }
    }

    /// Announce to the `ClusterShell` a change in reachability of a member.
    private func tryAnnounceMemberReachability(change: SWIM.MemberStatusChangedEvent?, context: MyselfContext) {
        guard let change = change else {
            // this means it likely was a change to the same status or it was about us, so we do not need to announce anything
            return
        }

        guard change.isReachabilityChange else {
            // the change is from a reachable to another reachable (or an unreachable to another unreachable-like (e.g. dead) state),
            // and thus we must not act on it, as the shell was already notified before about the change into the current status.
            return
        }

        // Log the transition
        switch change.status {
        case .unreachable:
            context.log.info(
                """
                Node \(change.member.node) determined [.unreachable]! \
                The node is not yet marked [.down], a downing strategy or other Cluster.Event subscriber may act upon this information.
                """, metadata: [
                    "swim/member": "\(change.member)",
                ]
            )
        default:
            context.log.info(
                "Node \(change.member.node) determined [.\(change.status)] (was [\(change.previousStatus, orElse: "nil")].",
                metadata: [
                    "swim/member": "\(change.member)",
                ]
            )
        }

        let reachability: Cluster.MemberReachability
        switch change.status {
        case .alive, .suspect:
            reachability = .reachable
        case .unreachable, .dead:
            reachability = .unreachable
        }

        guard let uniqueNode = change.member.node.asUniqueNode else {
            context.log.warning("Unable to emit failureDetectorReachabilityChanged, for event: \(change), since can't represent member as uniqueNode!")
            return
        }

        self.clusterRef.tell(.command(.failureDetectorReachabilityChanged(uniqueNode, reachability)))
    }

    /// This is effectively joining the SWIM membership of the other member.
    func sendFirstRemotePing(on targetUniqueNode: UniqueNode, _ context: MyselfContext) {
        let targetNode = ClusterMembership.Node(uniqueNode: targetUniqueNode)
        let targetPeer = targetNode.swimRef(context)

        // We need to include the member immediately, rather than when we have ensured the association.
        // This is because if we're not able to establish the association, we still want to re-try soon (in the next ping round),
        // and perhaps then the other node would accept the association (perhaps some transient network issues occurred OR the node was
        // already dead when we first try to ping it). In those situations, we need to continue the protocol until we're certain it is
        // suspect and unreachable, as without signalling unreachable the high-level membership would not have a chance to notice and
        // call the node [Cluster.MemberStatus.down].
        self.swim.addMember(targetPeer, status: .alive(incarnation: 0))

        // TODO: we are sending the ping here to initiate cluster membership. Once available this should do a state sync instead
        self.sendPing(to: targetPeer, pingRequestOriginPeer: nil, timeout: self.swim.dynamicLHMPingTimeout, sequenceNumber: self.swim.nextSequenceNumber(), context: context)
    }
}

extension SWIMActorShell {
    static let name: String = "swim"
    static let naming: ActorNaming = .unique(SWIMActorShell.name)

    static let periodicPingKey = TimerKey("\(SWIMActorShell.name)/periodic-ping")
}

extension ActorAddress {
    internal static func _swim(on node: UniqueNode) -> ActorAddress {
        .init(remote: node, path: ActorPath._swim, incarnation: .wellKnown)
    }
}

extension ActorPath {
    internal static let _swim: ActorPath = try! ActorPath._clusterShell.appending(SWIMActorShell.name)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Internal "trace-logging" for debugging purposes

internal enum TraceLogType: CustomStringConvertible {
    case reply(to: ActorRef<SWIM.PingResponse>)
    case receive(pinged: ActorRef<SWIM.Message>?)
    case ask(ActorRef<SWIM.Message>)

    static var receive: TraceLogType {
        .receive(pinged: nil)
    }

    var description: String {
        switch self {
        case .receive(nil):
            return "RECV"
        case .receive(let .some(pinged)):
            return "RECV(pinged:\(pinged.address))"
        case .reply(let to):
            return "REPL(to:\(to.address))"
        case .ask(let who):
            return "ASK(\(who.address))"
        }
    }
}
