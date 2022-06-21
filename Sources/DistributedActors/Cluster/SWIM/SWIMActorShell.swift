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

import ClusterMembership
import struct Dispatch.DispatchTime
import enum Dispatch.DispatchTimeInterval
import Distributed
import Logging
import NIOCore
import SWIM

/// The SWIM shell is responsible for driving all interactions of the `SWIM.Instance` with the outside world.
///
/// - SeeAlso: `SWIM.Instance` for detailed documentation about the SWIM protocol implementation.
internal distributed actor SWIMActorShell {
    typealias ActorSystem = ClusterSystem

    private let _settings: SWIM.Settings
    private let clusterRef: ClusterShell.Ref
    
    private lazy var swim = SWIM.Instance(settings: self.customizeSWIMSettings(self._settings), myself: self)

    private lazy var timers = ActorTimers<SWIMActorShell>(self)
    
    private lazy var log: Logger = {
        var log = Logger(actor: self)
        log.logLevel = self._settings.logger.logLevel
        return log
    }()
    
    var settings: SWIM.Settings {
        self.swim.settings
    }

    var metrics: SWIM.Metrics {
        self.swim.metrics
    }

    init(settings: SWIM.Settings, clusterRef: ClusterShell.Ref, system: ActorSystem) async {
        self._settings = settings
        self.clusterRef = clusterRef
        self.actorSystem = system
        
        self.onStart()
    }
    
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Initialization helpers
    
    /// Applies some default changes to the SWIM settings.
    private func customizeSWIMSettings(_ settings: SWIM.Settings) -> SWIM.Settings {
        var settings = settings
        settings.logger = self.log
        settings.metrics.systemName = self.actorSystem.settings.metrics.systemName
        return settings
    }
    
    /// Initialize timers and other after-initialized tasks
    private func onStart() {
        guard self.settings.initialContactPoints.isEmpty else {
            fatalError(
                """
                swim.initialContactPoints was not empty! Please use `settings.discovery` settings to discover peers,
                rather than the internal swim instances configuration settings!
                """)
        }
        self.handlePeriodicProtocolPeriodTick()
    }
    
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Periodic Protocol Ticks

    /// Scheduling a new protocol period and performing the actions for the current protocol period
    private func handlePeriodicProtocolPeriodTick() {
        self.swim.onPeriodicPingTick().forEach { directive in
            switch directive {
            case .membershipChanged(let change):
                self.tryAnnounceMemberReachability(change: change)

            case .sendPing(let target, let payload, let timeout, let sequenceNumber):
                self.log.trace("Periodic ping random member, among: \(self.swim.otherMemberCount)", metadata: self.swim.metadata)
                Task {
                    await self.sendPing(
                        to: target,
                        payload: payload,
                        pingRequestOrigin: nil,
                        pingRequestSequenceNumber: nil,
                        timeout: timeout,
                        sequenceNumber: sequenceNumber
                    )
                }

            case .scheduleNextTick(let delay):
                self.timers.startSingle(key: SWIM.Shell.protocolPeriodTimerKey, delay: .nanoseconds(delay.nanoseconds)) {
                    self.handlePeriodicProtocolPeriodTick()
                }
            }
        }
    }
    
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Sending ping, ping-req and friends

    @discardableResult
    private func sendPing(
        to target: SWIMPeer,
        payload: SWIM.GossipPayload,
        pingRequestOrigin: SWIMPingRequestOriginPeer?,
        pingRequestSequenceNumber: SWIM.SequenceNumber?,
        timeout: DispatchTimeInterval,
        sequenceNumber: SWIM.SequenceNumber
    ) async -> SWIM.PingResponse {
        let payload = self.swim.makeGossipPayload(to: target)

        self.log.debug("Sending ping", metadata: self.swim.metadata([
            "swim/target": "\(target)",
            "swim/gossip/payload": "\(payload)",
            "swim/timeout": "\(timeout)",
        ]))

        let pingSentAt = DispatchTime.now()
        self.metrics.shell.messageOutboundCount.increment()
        
        do {
            let response = try await target.ping(payload: payload, from: self, timeout: timeout, sequenceNumber: sequenceNumber)
            self.metrics.shell.pingResponseTime.recordInterval(since: pingSentAt)
            return self.handlePingResponse(
                response: response,
                pingRequestOrigin: pingRequestOrigin,
                pingRequestSequenceNumber: pingRequestSequenceNumber
            )
        } catch {
            self.log.debug(".ping resulted in error", metadata: self.swim.metadata([
                "swim/ping/target": "\(target)",
                "swim/ping/sequenceNumber": "\(sequenceNumber)",
                "error": "\(error)",
            ]))
            return self.handlePingResponse(
                response: .timeout(
                    target: target,
                    pingRequestOrigin: pingRequestOrigin,
                    timeout: timeout,
                    sequenceNumber: sequenceNumber
                ),
                pingRequestOrigin: pingRequestOrigin,
                pingRequestSequenceNumber: pingRequestSequenceNumber
            )
        }
    }
    
    private func sendPingRequests(_ directive: SWIM.Instance.SendPingRequestDirective) async {
        // We are only interested in successful pings, as a single success tells us the node is
        // still alive. Therefore we propagate only the first success, but no failures.
        // The failure case is handled through the timeout of the whole operation.
        let eventLoop = self.actorSystem._eventLoopGroup.next()
        let firstSuccessful = eventLoop.makePromise(of: SWIM.PingResponse.self)
        let pingTimeout = directive.timeout
        let peerToPing = directive.target

        let startedSendingPingRequestsSentAt: DispatchTime = .now()
        let pingRequestResponseTimeFirstTimer = self.swim.metrics.shell.pingRequestResponseTimeFirst
        firstSuccessful.futureResult.whenComplete { result in
            switch result {
            case .success: pingRequestResponseTimeFirstTimer.recordInterval(since: startedSendingPingRequestsSentAt)
            case .failure: ()
            }
        }

        for pingRequest in directive.requestDetails {
            let peerToPingRequestThrough = pingRequest.peerToPingRequestThrough
            let payload = pingRequest.payload
            let sequenceNumber = pingRequest.sequenceNumber

            self.log.trace("Sending ping request for [\(peerToPing)] to [\(peerToPingRequestThrough)] with payload: \(payload)")

            let pingRequestSentAt: DispatchTime = .now()
            self.metrics.shell.messageOutboundCount.increment()
            
            do {
                let response = try await peerToPingRequestThrough.pingRequest(
                    target: peerToPing,
                    payload: payload,
                    from: self,
                    timeout: pingTimeout,
                    sequenceNumber: sequenceNumber
                )
                
                self.metrics.shell.pingRequestResponseTimeAll.recordInterval(since: pingRequestSentAt)
                self.handleEveryPingRequestResponse(response: response, pinged: peerToPing)
                
                if case .ack = response {
                    // We only cascade successful ping responses (i.e. `ack`s);
                    //
                    // While this has a slight timing implication on time timeout of the pings -- the node that is last
                    // in the list that we ping, has slightly less time to fulfil the "total ping timeout"; as we set a total timeout on the entire `firstSuccess`.
                    // In practice those timeouts will be relatively large (seconds) and the few millis here should not have a large impact on correctness.
                    firstSuccessful.succeed(response)
                }
            } catch {
                self.log.debug(".pingRequest resulted in error", metadata: self.swim.metadata([
                    "swim/pingRequest/target": "\(peerToPing)",
                    "swim/pingRequest/peerToPingRequestThrough": "\(peerToPingRequestThrough)",
                    "swim/pingRequest/sequenceNumber": "\(sequenceNumber)",
                    "error": "\(error)",
                ]))
                self.handleEveryPingRequestResponse(
                    response: .timeout(
                        target: peerToPing,
                        pingRequestOrigin: self,
                        timeout: pingTimeout,
                        sequenceNumber: sequenceNumber
                    ),
                    pinged: peerToPing
                )
                // these are generally harmless thus we do not want to log them on higher levels
                self.log.trace("Failed pingRequest", metadata: [
                    "swim/target": "\(peerToPing)",
                    "swim/payload": "\(payload)",
                    "swim/pingTimeout": "\(pingTimeout)",
                    "error": "\(error)",
                ])
            }
        }
        
        do {
            let response = try await firstSuccessful.futureResult.get()
            self.handlePingRequestResponse(response: response, pinged: peerToPing)
        } catch {
            self.log.debug("Failed to sendPingRequests", metadata: [
                "error": "\(error)",
            ])
            self.handlePingRequestResponse(
                response: .timeout(target: peerToPing, pingRequestOrigin: self, timeout: pingTimeout, sequenceNumber: 0),
                pinged: peerToPing
            ) // FIXME: that sequence number...
        }
    }
    
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Message handlers and helpers
    
    // If `sendPing` is invoked without `pingRequestOrigin`, the result of this response handler can be ignored.
    // Otherwise, we might need to send ack/nack response to `pingRequestOrigin`, so it is the result of this
    // method that should be propagated, not the original ping response.
    private func handlePingResponse(
        response: SWIM.PingResponse,
        pingRequestOrigin: SWIMPingRequestOriginPeer?,
        pingRequestSequenceNumber: SWIM.SequenceNumber?
    ) -> SWIM.PingResponse {
        var pingRequestOriginResponse: SWIM.PingResponse?

        self.swim.onPingResponse(
            response: response,
            pingRequestOrigin: pingRequestOrigin,
            pingRequestSequenceNumber: pingRequestSequenceNumber
        ).forEach { directive in
            switch directive {
            case .gossipProcessed(let gossipDirective):
                self.handleGossipPayloadProcessedDirective(gossipDirective)

            case .sendAck(_, let acknowledging, let target, let incarnation, let payload): // only if pingRequestOrigin != nil
                pingRequestOriginResponse = .ack(target: target, incarnation: incarnation, payload: payload, sequenceNumber: acknowledging)

            case .sendNack(_, let acknowledging, let target): // only if pingRequestOrigin != nil
                pingRequestOriginResponse = .nack(target: target, sequenceNumber: acknowledging)

            case .sendPingRequests(let pingRequestDirective):
                Task {
                    await self.sendPingRequests(pingRequestDirective)
                }
            }
        }
        
        return pingRequestOriginResponse ?? response
    }
    
    private func handlePingRequestResponse(response: SWIM.PingResponse, pinged: SWIMPeer) {
        // self.tracelog(context, .receive(pinged: pinged), message: response)
        self.swim.onPingRequestResponse(
            response,
            pinged: pinged
        ).forEach { directive in
            switch directive {
            case .gossipProcessed(let gossipDirective):
                self.handleGossipPayloadProcessedDirective(gossipDirective)

            case .alive(let previousStatus):
                self.log.debug("Member [\(pinged)] is alive")
                if previousStatus.isUnreachable, let member = swim.member(for: pinged) {
                    // member was unreachable but now is alive, we should emit an event
                    let event = SWIM.MemberStatusChangedEvent(previousStatus: previousStatus, member: member) // FIXME: make SWIM emit an option of the event
                    self.tryAnnounceMemberReachability(change: event)
                }

            case .newlySuspect:
                self.log.debug("Member [\(pinged)] marked as suspect")

            case .nackReceived:
                self.log.debug("Received `nack` from indirect probing of [\(pinged)]")
            default:
                () // TODO: revisit logging more details here
            }
        }
    }
    
    /// Announce to the `ClusterShell` a change in reachability of a member.
    private func tryAnnounceMemberReachability(change: SWIM.MemberStatusChangedEvent?) {
        guard let change = change else {
            // this means it likely was a change to the same status or it was about us, so we do not need to announce anything
            return
        }

        guard change.isReachabilityChange else {
            // the change is from a reachable to another reachable (or an unreachable to another unreachable-like (e.g. dead) state),
            // and thus we must not act on it, as the shell was already notified before about the change into the current status.
            //
            // if this is a move from unreachable -> down, then the downing subsystem will have already sent out the down event,
            // and we should not duplicate it.
            return
        }

        // Log the transition
        switch change.status {
        case .unreachable:
            self.log.info(
                """
                Node \(change.member.node) determined [.unreachable]! \
                The node is not yet marked [.down], a downing strategy or other Cluster.Event subscriber may act upon this information.
                """, metadata: [
                    "swim/member": "\(change.member)",
                ]
            )
        default:
            self.log.info(
                "Node \(change.member.node) determined [.\(change.status)] (was \(optional: change.previousStatus)).",
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
            self.log.warning("Unable to emit failureDetectorReachabilityChanged, for event: \(change), since can't represent member as uniqueNode!")
            return
        }

        self.clusterRef.tell(.command(.failureDetectorReachabilityChanged(uniqueNode, reachability)))
    }
    
    private func handleGossipPayloadProcessedDirective(_ directive: SWIM.Instance.GossipProcessedDirective) {
        switch directive {
        case .applied(let change):
            self.tryAnnounceMemberReachability(change: change)
        }
    }
    
    /// We have to handle *every* response, because they adjust the value of the timeouts we'll be using in future probes.
    private func handleEveryPingRequestResponse(response: SWIM.PingResponse, pinged: SWIMPeer) {
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
    
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Distributed functions

    distributed func ping(
        origin: SWIMActorShell,
        payload: SWIM.GossipPayload,
        sequenceNumber: SWIM.SequenceNumber
    ) async -> SWIM.PingResponse {
        await withCheckedContinuation { continuation in
            self.log.trace("Received ping@\(sequenceNumber)", metadata: self.swim.metadata([
                "swim/ping/origin": "\(origin.id)",
                "swim/ping/payload": "\(payload)",
                "swim/ping/seqNr": "\(sequenceNumber)",
            ]))

            self.swim.onPing(
                pingOrigin: origin,
                payload: payload,
                sequenceNumber: sequenceNumber
            ).forEach { directive in
                switch directive {
                case .gossipProcessed(let gossipDirective):
                    self.handleGossipPayloadProcessedDirective(gossipDirective)

                case .sendAck(_, let pingedTarget, let incarnation, let payload, let sequenceNumber):
                    continuation.resume(returning: .ack(target: pingedTarget, incarnation: incarnation, payload: payload, sequenceNumber: sequenceNumber))
                }
            }
        }
    }
    
    distributed func pingRequest(
        target: SWIMActorShell,
        pingRequestOrigin: SWIMActorShell,
        payload: SWIM.GossipPayload,
        sequenceNumber pingRequestSequenceNumber: SWIM.SequenceNumber
    ) async -> SWIM.PingResponse {
        await withCheckedContinuation { continuation in
            self.log.trace("Received pingRequest@\(pingRequestSequenceNumber) [\(target)] from [\(pingRequestOrigin)]", metadata: self.swim.metadata([
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
                    self.handleGossipPayloadProcessedDirective(gossipDirective)

                case .sendPing(let target, let payload, let pingRequestOrigin, let pingRequestSequenceNumber, let timeout, let pingSequenceNumber):
                    Task {
                        let response = await self.sendPing(
                            to: target,
                            payload: payload,
                            pingRequestOrigin: pingRequestOrigin,
                            pingRequestSequenceNumber: pingRequestSequenceNumber,
                            timeout: timeout,
                            sequenceNumber: pingSequenceNumber
                        )
                        continuation.resume(returning: response)
                    }
                }
            }
        }
    }
    
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Local functions

    func monitor(node: UniqueNode) {
        guard self.actorSystem.cluster.uniqueNode.node != node.node else {
            return // no need to monitor ourselves, nor a replacement of us (if node is our replacement, we should have been dead already)
        }

        self.sendFirstRemotePing(on: node)
    }

    func confirmDead(node: UniqueNode) {
        let directive = self.swim.confirmDead(peer: node.asSWIMNode.swimShell(self.actorSystem))
        switch directive {
        case .applied(let change):
            self.log.warning("Confirmed node .dead: \(change)", metadata: self.swim.metadata(["swim/change": "\(change)"]))
        case .ignored:
            return
        }
    }

    /// This is effectively joining the SWIM membership of the other member.
    private func sendFirstRemotePing(on targetUniqueNode: UniqueNode) {
        let targetNode = ClusterMembership.Node(uniqueNode: targetUniqueNode)
        let targetPeer = targetNode.swimShell(self.actorSystem)

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

        Task {
            // TODO: we are sending the ping here to initiate cluster membership. Once available this should do a state sync instead
            await self.sendPing(
                to: targetPeer,
                payload: swim.makeGossipPayload(to: nil),
                pingRequestOrigin: nil,
                pingRequestSequenceNumber: nil,
                timeout: .seconds(1),
                sequenceNumber: self.swim.nextSequenceNumber()
            )
        }
    }
    
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: For testing only
        
    func _getMembershipState() -> [SWIM.Member] {
        Array(self.swim.members)
    }
}

/*

/// The SWIM shell is responsible for driving all interactions of the `SWIM.Instance` with the outside world.
///
/// - SeeAlso: `SWIM.Instance` for detailed documentation about the SWIM protocol implementation.
internal struct SWIMActorShell {
    typealias MyselfContext = _ActorContext<SWIM.Message>

    let swim: SWIM.Instance
    let clusterRef: ClusterShell.Ref

    var settings: SWIM.Settings {
        self.swim.settings
    }

    var metrics: SWIM.Metrics {
        self.swim.metrics
    }

    internal init(_ swim: SWIM.Instance, clusterRef: ClusterShell.Ref) {
        self.swim = swim
        self.clusterRef = clusterRef
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: _Behaviors

    /// Initial behavior, kicks off timers and becomes `ready`.
    static func behavior(settings: SWIM.Settings, clusterRef: ClusterShell.Ref) -> _Behavior<SWIM.Message> {
        .setup { context in
            let swim = SWIM.Instance(
                settings: Self.customizeSWIMSettings(settings: settings, context: context),
                myself: context.myself
            )
            let shell = SWIMActorShell(swim, clusterRef: clusterRef)
            shell.onStart(context: context)

            return SWIMActorShell.ready(shell: shell)
        }
    }

    /// Applies some default changes to the SWIM settings.
    private static func customizeSWIMSettings(settings: SWIM.Settings, context: _ActorContext<SWIM.Message>) -> SWIM.Settings {
        // A bit weird dance, but this way we make the instance use the actor's logger;
        // This is always what we want inside an actor system anyway;
        // And at the same time we do use the configured log level for the entire actor: instance and shell
        var settings = settings
        context.log.logLevel = settings.logger.logLevel
        settings.logger = context.log
        settings.metrics.systemName = context.system.settings.metrics.systemName
        return settings
    }

    static func ready(shell: SWIMActorShell) -> _Behavior<SWIM.Message> {
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
                    replyTo.tell(Array(shell.swim.members))
                    return .same
                }
            }
        }
    }

    /// Initialize timers and other after-initialized tasks
    private func onStart(context: MyselfContext) {
        guard self.settings.initialContactPoints.isEmpty else {
            fatalError(
                """
                swim.initialContactPoints was not empty! Please use `settings.discovery settings to discover peers,
                rather than the internal swim instances configuration settings!
                """)
        }
        self.handlePeriodicProtocolPeriodTick(context: context)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Periodic Protocol Ticks

    /// Scheduling a new protocol period and performing the actions for the current protocol period
    func handlePeriodicProtocolPeriodTick(context: MyselfContext) {
        self.swim.onPeriodicPingTick().forEach { directive in
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
        self.metrics.shell.messageInboundCount.increment()

        switch message {
        case .ping(let replyTo, let payload, let sequenceNumber):
            self.handlePing(context: context, replyTo: replyTo, payload: payload, sequenceNumber: sequenceNumber)

        case .pingRequest(let target, let replyTo, let payload, let sequenceNumber):
            self.handlePingRequest(target: target, pingRequestOrigin: replyTo, payload: payload, sequenceNumber: sequenceNumber, context: context)

        case .pingResponse(let response):
            context.log.warning(".pingResponse received in non-ask actor; this is wrong, please report a bug.", metadata: self.swim.metadata([
                "message": "\(response)",
            ]))
        }
    }

    private func handlePing(context: MyselfContext, replyTo pingOrigin: SWIM.PingOriginRef, payload: SWIM.GossipPayload, sequenceNumber: SWIM.SequenceNumber) {
        context.log.trace("Received ping@\(sequenceNumber)", metadata: self.swim.metadata([
            "swim/ping/origin": "\(pingOrigin.id)",
            "swim/ping/payload": "\(payload)",
            "swim/ping/seqNr": "\(sequenceNumber)",
        ]))

        self.swim.onPing(
            pingOrigin: pingOrigin,
            payload: payload,
            sequenceNumber: sequenceNumber
        ).forEach { directive in
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

        context.log.debug("Sending ping", metadata: self.swim.metadata([
            "swim/target": "\(target)",
            "swim/gossip/payload": "\(payload)",
            "swim/timeout": "\(timeout)",
        ]))

        let pingSentAt = DispatchTime.now()
        self.metrics.shell.messageOutboundCount.increment()
        target.ping(payload: payload, timeout: timeout, sequenceNumber: sequenceNumber, context: context) { result in
            switch result {
            case .success(let pingResponse):
                self.metrics.shell.pingResponseTime.recordInterval(since: pingSentAt)
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

        let startedSendingPingRequestsSentAt: DispatchTime = .now()
        let pingRequestResponseTimeFirstTimer = self.swim.metrics.shell.pingRequestResponseTimeFirst
        firstSuccessful.futureResult.whenComplete { result in
            switch result {
            case .success: pingRequestResponseTimeFirstTimer.recordInterval(since: startedSendingPingRequestsSentAt)
            case .failure: ()
            }
        }

        for pingRequest in directive.requestDetails {
            let peerToPingRequestThrough = pingRequest.peerToPingRequestThrough
            let payload = pingRequest.payload
            let sequenceNumber = pingRequest.sequenceNumber

            context.log.trace("Sending ping request for [\(peerToPing)] to [\(peerToPingRequestThrough)] with payload: \(payload)")

            let pingRequestSentAt: DispatchTime = .now()
            let eachReplyPromise = eventLoop.makePromise(of: SWIM.PingResponse.self)

            self.metrics.shell.messageOutboundCount.increment()
            peerToPingRequestThrough.pingRequest(target: peerToPing, payload: payload, timeout: pingTimeout, sequenceNumber: sequenceNumber, context: context) { result in
                eachReplyPromise.completeWith(result)
            }
            context.onResultAsync(of: eachReplyPromise.futureResult, timeout: .effectivelyInfinite) { result in
                switch result {
                case .success(let response):
                    self.metrics.shell.pingRequestResponseTimeAll.recordInterval(since: pingRequestSentAt)
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

    func handlePingResponse(
        response: SWIM.PingResponse,
        pingRequestOrigin: SWIMPingRequestOriginPeer?,
        pingRequestSequenceNumber: SWIM.SequenceNumber?,
        context: MyselfContext
    ) {
        self.swim.onPingResponse(
            response: response,
            pingRequestOrigin: pingRequestOrigin,
            pingRequestSequenceNumber: pingRequestSequenceNumber
        ).forEach { directive in
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
        self.swim.onPingRequestResponse(
            response,
            pinged: pinged
        ).forEach { directive in
            switch directive {
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
        let directive = self.swim.confirmDead(peer: uniqueNode.asSWIMNode.swimRef(context))
        switch directive {
        case .applied(let change):
            context.log.warning("Confirmed node .dead: \(change)", metadata: self.swim.metadata(["swim/change": "\(change)"]))
        case .ignored:
            return
        }
    }

    func handleGossipPayloadProcessedDirective(_ directive: SWIM.Instance.GossipProcessedDirective, context: MyselfContext) {
        switch directive {
        case .applied(let change):
            self.tryAnnounceMemberReachability(change: change, context: context)
        }
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
            //
            // if this is a move from unreachable -> down, then the downing subsystem will have already sent out the down event,
            // and we should not duplicate it.
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
                "Node \(change.member.node) determined [.\(change.status)] (was \(optional: change.previousStatus)).",
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
*/

extension SWIMActorShell {
    static let name: String = "swim"
    static let naming: _ActorNaming = .unique(SWIMActorShell.name)

    static var props: _Props {
        var ps = _Props()
        ps._knownActorName = ActorPath._swim.name
        ps._wellKnown = true
        return ps.metrics(group: "swim.shell", measure: [.serialization, .deserialization])
    }
    
//    static var props: _Props {
//        _Props
//            ._wellKnown
//            .metrics(group: "swim.shell", measure: [.serialization, .deserialization])
//    }

    static let protocolPeriodTimerKey = _TimerKey("\(SWIMActorShell.name)/periodic-ping")
}

extension ActorID {
    static func _swim(on node: UniqueNode) -> ActorID {
        .init(remote: node, path: ActorPath._swim, incarnation: .wellKnown)
    }
}

extension ActorPath {
    static let _swim: ActorPath = try! ActorPath._clusterShell.appending(SWIMActorShell.name)
}

//// ==== ----------------------------------------------------------------------------------------------------------------
//// MARK: Internal "trace-logging" for debugging purposes
//
//internal enum TraceLogType: CustomStringConvertible {
//    case reply(to: _ActorRef<SWIM.PingResponse>)
//    case receive(pinged: _ActorRef<SWIM.Message>?)
//    case ask(_ActorRef<SWIM.Message>)
//
//    static var receive: TraceLogType {
//        .receive(pinged: nil)
//    }
//
//    var description: String {
//        switch self {
//        case .receive(nil):
//            return "RECV"
//        case .receive(let .some(pinged)):
//            return "RECV(pinged:\(pinged.id))"
//        case .reply(let to):
//            return "REPL(to:\(to.id))"
//        case .ask(let who):
//            return "ASK(\(who.id))"
//        }
//    }
//}
