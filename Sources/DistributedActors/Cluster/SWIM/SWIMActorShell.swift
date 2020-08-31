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
                case ._getMembershipState(let replyTo):
                    replyTo.tell(Set(shell.swim.members))
                    return .same
                }
            }
        }
    }

    /// Initialize timers and other after-initialized tasks
    private func onStart(context: MyselfContext) {
        /// We also respect swim configuration, but we simply initiate it the same way as a normal join would.
        for contactPoint in self.settings.initialContactPoints {
            self.clusterRef.tell(.command(.handshakeWith(contactPoint.asNode)))
        }

        self.handlePeriodicProtocolPeriodTick(context: context)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Periodic Protocol Ticks

    /// Scheduling a new protocol period and performing the actions for the current protocol period
    func handlePeriodicProtocolPeriodTick(context: MyselfContext) {
        let directives = self.swim.onPeriodicPingTick()
        directives.forEach { directive in
            switch directive {
            case .membershipChanged(let change):
                self.tryAnnounceMemberReachability(change: change, context: context)

            case .sendPing(let target, let payload, let timeout, let sequenceNumber):
                context.log.trace("Periodic ping random member, among: \(self.swim.otherMemberCount)", metadata: self.swim.metadata)
                self.sendPing(to: target, payload: payload, pingRequestOrigin: nil, pingRequestSequenceNumber: nil, timeout: timeout, sequenceNumber: sequenceNumber, context: context)

            case .scheduleNextTick(let delay):
                context.timers.startSingle(key: SWIM.Shell.protocolPeriodTimerKey, message: .local(.protocolPeriodTick), delay: .nanoseconds(delay.nanoseconds))
            }
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Receiving messages

    func receiveRemoteMessage(message: SWIM.RemoteMessage, context: MyselfContext) {
        switch message {
        case .ping(let replyTo, let payload, let sequenceNumber):
            self.handlePing(context: context, replyTo: replyTo, payload: payload, sequenceNumber: sequenceNumber)

        case .pingRequest(let target, let replyTo, let payload, let sequenceNumber):
            self.handlePingRequest(target: target, pingRequestOrigin: replyTo, payload: payload, sequenceNumber: sequenceNumber, context: context)

        case .pingResponse(let response):
            context.log.warning(".pingResponse received in non-ask actor; this is wrong, please report a bug.", metadata: [
                "swim/message": "\(response)",
                "swim": "\(self.swim)",
            ])
        }
    }

    private func handlePing(context: MyselfContext, replyTo pingOrigin: SWIM.PingOriginRef, payload: SWIM.GossipPayload, sequenceNumber: SWIM.SequenceNumber) {
        context.log.trace("Received ping@\(sequenceNumber)", metadata: self.swim.metadata([
            "swim/ping/origin": "\(pingOrigin.address)",
            "swim/ping/payload": "\(payload)",
            "swim/ping/seqNr": "\(sequenceNumber)",
        ]))

        let directives = self.swim.onPing(pingOrigin: pingOrigin, payload: payload, sequenceNumber: sequenceNumber)
        for directive in directives {
            switch directive {
            case .gossipProcessed(let gossipDirective):
                self.handleGossipPayloadProcessedDirective(gossipDirective, context: context)

            case .sendAck(let pingOrigin, let pingedTarget, let incarnation, let payload, let sequenceNumber):
                pingOrigin.ack(acknowledging: sequenceNumber, target: pingedTarget, incarnation: incarnation, payload: payload)
            }
        }
    }

    private func handlePingRequest(
        target: SWIM.Ref,
        pingRequestOrigin: SWIMPingRequestOriginPeer,
        payload: SWIM.GossipPayload,
        sequenceNumber pingRequestSequenceNumber: SWIM.SequenceNumber,
        context: MyselfContext
    ) {
        context.log.trace("Received pingRequest@\(pingRequestSequenceNumber) [\(target)] from [\(pingRequestOrigin)]", metadata: self.swim.metadata([
            "swim/pingRequest/origin": "\(pingRequestOrigin)",
            "swim/pingRequest/payload": "\(payload)",
            "swim/pingRequest/seqNr": "\(pingRequestSequenceNumber)",
        ]))

        self.swim.onPingRequest(
            target: target,
            pingRequestOrigin: pingRequestOrigin,
            payload: payload,
            sequenceNumber: pingRequestSequenceNumber
        ).forEach { directive in
            switch directive {
            case .gossipProcessed(let gossipDirective):
                self.handleGossipPayloadProcessedDirective(gossipDirective, context: context)

            case .sendPing(let target, let payload, let pingRequestOrigin, let pingRequestSequenceNumber, let timeout, let pingSequenceNumber):
                self.sendPing(
                    to: target,
                    payload: payload,
                    pingRequestOrigin: pingRequestOrigin,
                    pingRequestSequenceNumber: pingRequestSequenceNumber,
                    timeout: timeout,
                    sequenceNumber: pingSequenceNumber,
                    context: context
                )
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
        case .protocolPeriodTick:
            self.handlePeriodicProtocolPeriodTick(context: context)

        case .monitor(let node):
            self.handleStartMonitoring(node: node, context: context)

        case .confirmDead(let node):
            self.handleConfirmDead(deadNode: node, context: context)
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Sending ping, ping-req and friends

    func sendPing(
        to target: SWIMPeer,
        payload: SWIM.GossipPayload,
        pingRequestOrigin: SWIMPingRequestOriginPeer?,
        pingRequestSequenceNumber: SWIM.SequenceNumber?,
        timeout: DispatchTimeInterval,
        sequenceNumber: SWIM.SequenceNumber,
        context: MyselfContext
    ) {
        let payload = self.swim.makeGossipPayload(to: target)

        context.log.trace("Sending ping", metadata: self.swim.metadata([
            "swim/target": "\(target)",
            "swim/gossip/payload": "\(payload)",
            "swim/timeout": "\(timeout)",
        ]))

        target.ping(payload: payload, timeout: timeout, sequenceNumber: sequenceNumber, context: context) { result in
            switch result {
            case .success(let pingResponse):
                self.handlePingResponse(
                    response: pingResponse,
                    pingRequestOrigin: pingRequestOrigin,
                    pingRequestSequenceNumber: pingRequestSequenceNumber,
                    context: context
                )
            case .failure(let error):
                context.log.debug(".ping resulted in error", metadata: self.swim.metadata([
                    "swim/ping/target": "\(target)",
                    "swim/ping/sequenceNumber": "\(sequenceNumber)",
                    "error": "\(error)",
                ]))
                self.handlePingResponse(
                    response: .timeout(
                        target: target,
                        pingRequestOrigin: pingRequestOrigin,
                        timeout: timeout,
                        sequenceNumber: sequenceNumber
                    ),
                    pingRequestOrigin: pingRequestOrigin,
                    pingRequestSequenceNumber: pingRequestSequenceNumber,
                    context: context
                )
            }
        }
    }

    func sendPingRequests(_ directive: SWIM.Instance.SendPingRequestDirective, context: MyselfContext) {
        // We are only interested in successful pings, as a single success tells us the node is
        // still alive. Therefore we propagate only the first success, but no failures.
        // The failure case is handled through the timeout of the whole operation.
        let eventLoop = context.system._eventLoopGroup.next()
        let firstSuccessful = eventLoop.makePromise(of: SWIM.PingResponse.self)
        let pingTimeout = directive.timeout
        let peerToPing = directive.target
        for pingRequest in directive.requestDetails {
            let peerToPingRequestThrough = pingRequest.peerToPingRequestThrough
            let payload = pingRequest.payload
            let sequenceNumber = pingRequest.sequenceNumber

            context.log.trace("Sending ping request for [\(peerToPing)] to [\(peerToPingRequestThrough)] with payload: \(payload)")

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
                    context.log.debug(".pingRequest resulted in error", metadata: self.swim.metadata([
                        "swim/pingRequest/target": "\(peerToPing)",
                        "swim/pingRequest/peerToPingRequestThrough": "\(peerToPingRequestThrough)",
                        "swim/pingRequest/sequenceNumber": "\(sequenceNumber)",
                        "error": "\(error)",
                    ]))
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

//    func handlePingResponse(
//        response: SWIM.PingResponse,
//        context: MyselfContext
//    ) {
//        /// If this message is in response to an indirect ping that was caused by an
//        let pingRequest = self.inFlightPingRequestedPings.removeValue(forKey: response.sequenceNumber)
//
//        self.handlePingResponse(
//            response: response,
//            pingRequestOrigin: pingRequest?.origin,
//            pingRequestSequenceNumber: pingRequest?.sequenceNumber,
//            context: context
//        )
//    }

    func handlePingResponse(
        response: SWIM.PingResponse,
        pingRequestOrigin: SWIMPingRequestOriginPeer?,
        pingRequestSequenceNumber: SWIM.SequenceNumber?,
        context: MyselfContext
    ) {
        let directives = self.swim.onPingResponse(
            response: response,
            pingRequestOrigin: pingRequestOrigin,
            pingRequestSequenceNumber: pingRequestSequenceNumber
        )
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
        let directives = self.swim.onEveryPingRequestResponse(response, pinged: pinged)

        if !directives.isEmpty {
            fatalError("""
            Ignored directive from: onEveryPingRequestResponse! \
            This directive used to be implemented as always returning no directives. \
            Check your shell implementations if you updated the SWIM library as it seems this has changed. \
            Directive was: \(directives), swim was: \(self.swim.metadata)
            """)
        }
    }

    func handlePingRequestResponse(response: SWIM.PingResponse, pinged: SWIMPeer, context: MyselfContext) {
        // self.tracelog(context, .receive(pinged: pinged), message: response)
        let directives = self.swim.onPingRequestResponse(response, pinged: pinged)
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

    func handleConfirmDead(deadNode uniqueNode: UniqueNode, context: MyselfContext) {
        guard let member = self.swim.member(for: uniqueNode.asSWIMNode) else {
            context.log.debug("Attempted to confirm dead an already dead or removed node: \(uniqueNode)")
            return
        }

        let directive = self.swim.confirmDead(peer: member.peer)
        switch directive {
        case .applied(let change):
            context.log.debug("Confirmed node .dead: \(change)", metadata: [
                "swim/change": "\(change)",
            ])
        case .ignored:
            return
        }
//        let node = ClusterMembership.Node(uniqueNode: uniqueNode)
//        if let member = self.swim.member(for: node) {
//            // It is important to not infinitely loop cluster.down + confirmDead messages;
//            // See: `.confirmDead` for more rationale
//            if member.isDead {
//                return // member is already dead, nothing else to do here.
//            }
//
//            context.log.trace("Confirming .dead member \(reflecting: member.node)")
//
//            // We are diverging from the SWIM paper here in that we store the `.dead` state, instead
//            // of removing the node from the member list. We do that in order to prevent dead nodes
//            // from being re-added to the cluster.
//            // TODO: add time of death to the status
//            // TODO: GC tombstones after a day
//
//            switch self.swim.mark(member.peer, as: .dead) {
//            case .applied(let .some(previousState), _):
//                if previousState.isSuspect || previousState.isUnreachable {
//                    context.log.warning(
//                        "Marked [\(member)] as [.dead]. Was marked \(previousState) in protocol period [\(member.protocolPeriod)]",
//                        metadata: [
//                            "swim/protocolPeriod": "\(self.swim.protocolPeriod)",
//                            "swim/member": "\(member)", // TODO: make sure it is the latest status of it in here
//                        ]
//                    )
//                } else {
//                    context.log.warning(
//                        "Marked [\(member)] as [.dead]. Node was previously [.alive], and now forced [.dead].",
//                        metadata: [
//                            "swim/protocolPeriod": "\(self.swim.protocolPeriod)",
//                            "swim/member": "\(member)", // TODO: make sure it is the latest status of it in here
//                        ]
//                    )
//                }
//            case .applied(nil, _):
//                // TODO: marking is more about "marking a node as dead" should we rather log addresses and not actor paths?
//                context.log.warning("Marked [\(member)] as [.dead]. Node was not previously known to SWIM.")
//                // TODO: should we not issue a escalateUnreachable here? depends how we learnt about that node...
//
//            case .ignoredDueToOlderStatus:
//                // TODO: make sure a fatal error in SWIM.Shell causes a system shutdown?
//                fatalError("Marking [\(member)] as [.dead] failed! This should never happen, dead is the terminal status. SWIM instance: \(self.swim)")
//            }
//        } else {
//            context.log.warning("Attempted to .confirmDead(\(node)), yet no such member known to \(self)!") // TODO: would want to see if this happens when we fail these tests
//            // even if not known, we invent such node and store it as dead
//            self.swim.addMember(node.swimRef(context), status: .dead)
//        }
    }

//    func checkSuspicionTimeouts(context: MyselfContext) {
//        for suspect in self.swim.suspects {
//            if case .suspect(_, let suspectedBy) = suspect.status {
//                let suspicionTimeout = self.swim.suspicionTimeout(suspectedByCount: suspectedBy.count)
//                context.log.trace(
//                    "Checking suspicion timeout for: \(suspect)...",
//                    metadata: [
//                        "swim/suspect": "\(suspect)",
//                        "swim/suspectedBy": "\(suspectedBy.count)",
//                        "swim/suspicionTimeout": "\(suspicionTimeout)",
//                    ]
//                )
//
//                // proceed with suspicion escalation to .unreachable if the timeout period has been exceeded
//                // We don't use Deadline because tests can override TimeSource
//                guard let startTime = suspect.suspicionStartedAt,
//                    self.swim.isExpired(deadline: startTime + suspicionTimeout.nanoseconds) else {
//                    continue // skip, this suspect is not timed-out yet
//                }
//
//                guard let incarnation = suspect.status.incarnation else {
//                    // suspect had no incarnation number? that means it is .dead already and should be recycled soon
//                    return
//                }
//
//                var unreachableSuspect = suspect
//                unreachableSuspect.status = .unreachable(incarnation: incarnation)
//                self.markMember(context, latest: unreachableSuspect)
//            }
//        }
//
//        context.system.metrics.recordSWIMMembers(self.swim.allMembers)
//    }

//    private func markMember(_ context: MyselfContext, latest: SWIM.Member) {
//        switch self.swim.mark(latest.peer, as: latest.status) {
//        case .applied(let previousStatus, _):
//            context.log.trace(
//                "Marked \(latest.node) as \(latest.status), announcing reachability change",
//                metadata: [
//                    "swim/member": "\(latest)",
//                    "swim/previousStatus": "\(previousStatus, orElse: "nil")",
//                ]
//            )
//            let statusChange = SWIM.MemberStatusChangedEvent(previousStatus: previousStatus, member: latest)
//            self.tryAnnounceMemberReachability(change: statusChange, context: context)
//        case .ignoredDueToOlderStatus:
//            () // context.log.trace("No change \(latest), currentStatus remains [\(currentStatus)]. No reachability change to announce")
//        }
//    }

    func handleGossipPayloadProcessedDirective(_ directive: SWIM.Instance.GossipProcessedDirective, context: MyselfContext) {
        switch directive {
        case .applied(let change):
            self.tryAnnounceMemberReachability(change: change, context: context)
        }
    }

    func processGossipedMembership(_ directive: SWIM.Instance.GossipProcessedDirective, context: MyselfContext) {
        switch directive {
        case .applied(let change):
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

        // FIXME: expose addMember after all
        let fakeGossip = SWIM.GossipPayload.membership([
            SWIM.Member(peer: targetPeer, status: .alive(incarnation: 0), protocolPeriod: 0),
        ])
        _ = self.swim.onPingResponse(
            response: .ack(target: targetPeer, incarnation: 0, payload: fakeGossip, sequenceNumber: 0),
            pingRequestOrigin: nil,
            pingRequestSequenceNumber: nil
        )

//        // We need to include the member immediately, rather than when we have ensured the association.
//        // This is because if we're not able to establish the association, we still want to re-try soon (in the next ping round),
//        // and perhaps then the other node would accept the association (perhaps some transient network issues occurred OR the node was
//        // already dead when we first try to ping it). In those situations, we need to continue the protocol until we're certain it is
//        // suspect and unreachable, as without signalling unreachable the high-level membership would not have a chance to notice and
//        // call the node [Cluster.MemberStatus.down].
//        self.swim.addMember(targetPeer, status: .alive(incarnation: 0))

        // TODO: we are sending the ping here to initiate cluster membership. Once available this should do a state sync instead
        self.sendPing(
            to: targetPeer,
            payload: swim.makeGossipPayload(to: nil),
            pingRequestOrigin: nil,
            pingRequestSequenceNumber: nil,
            timeout: .seconds(1),
            sequenceNumber: self.swim.nextSequenceNumber(),
            context: context
        )
    }
}

extension SWIMActorShell {
    static let name: String = "swim"
    static let naming: ActorNaming = .unique(SWIMActorShell.name)

    static let protocolPeriodTimerKey = TimerKey("\(SWIMActorShell.name)/periodic-ping")
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
