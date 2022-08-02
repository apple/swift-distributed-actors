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
import Distributed
import Logging
import NIOCore
import SWIM

/// The SWIM shell is responsible for driving all interactions of the `SWIM.Instance` with the outside world.
///
/// - SeeAlso: `SWIM.Instance` for detailed documentation about the SWIM protocol implementation.
internal distributed actor SWIMActorShell: SWIMPeer, SWIMAddressablePeer, CustomStringConvertible {
    typealias ActorSystem = ClusterSystem
    typealias SWIMInstance = SWIM.Instance<SWIMActorShell, SWIMActorShell, SWIMActorShell>
    
    private let settings: SWIM.Settings
    private let clusterRef: ClusterShell.Ref

    // !-safe since we initialize this during init() right after the actor becomes ready;
    // The reason for this is that the instance needs our `self` in order to use it as a `SWIMPeer`
    private var swim: SWIM.Instance<SWIMActorShell, SWIMActorShell, SWIMActorShell>!

    nonisolated var swimNode: ClusterMembership.Node {
        .init(
            protocol: self.id.uniqueNode.node.protocol,
            host: self.id.uniqueNode.host,
            port: self.id.uniqueNode.port,
            uid: self.id.uniqueNode.nid.value)
    }
    
    private lazy var log: Logger = {
        var log = Logger(actor: self)
        log.logLevel = self.settings.logger.logLevel
        return log
    }()

    var metrics: SWIM.Metrics {
        self.swim.metrics
    }

    init(settings: SWIM.Settings, clusterRef: ClusterShell.Ref, system: ActorSystem) async {
        self.settings = settings
        self.clusterRef = clusterRef
        self.actorSystem = system

        self.swim = SWIMInstance(settings: self.customizeSWIMSettings(self.settings), myself: self)

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
    internal func handlePeriodicProtocolPeriodTick() {
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
                // Keep scheduling the timer so that it fires for each tick
                Task {
                    try await Task.sleep(until: .now + .nanoseconds(delay.nanoseconds), clock: .continuous)
                    self.handlePeriodicProtocolPeriodTick()
                }
            }
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Send ping, ping-req

    @discardableResult
    internal func sendPing(
        to target: SWIMActorShell,
        payload: SWIM.GossipPayload<SWIMActorShell>,
        pingRequestOrigin: SWIMActorShell?,
        pingRequestSequenceNumber: SWIM.SequenceNumber?,
        timeout: Duration,
        sequenceNumber: SWIM.SequenceNumber
    ) async -> SWIM.PingResponse<SWIMActorShell, SWIMActorShell> {
        let payload = self.swim.makeGossipPayload(to: target)

        self.log.debug("Sending ping", metadata: self.swim.metadata([
            "swim/target": "\(target)",
            "swim/gossip/payload": "\(payload)",
            "swim/timeout": "\(timeout)",
        ]))

        let pingSentAt = DispatchTime.now()
        self.metrics.shell.messageOutboundCount.increment()

        do {
            let pingResponse = try await target.ping(payload: payload, from: self, timeout: timeout, sequenceNumber: sequenceNumber)
            self.metrics.shell.pingResponseTime.recordInterval(since: pingSentAt)
            return self.handlePingResponse(
                response: pingResponse,
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

    internal func sendPingRequests(_ directive: SWIMInstance.SendPingRequestDirective) async {
        // We are only interested in successful pings, as a single success tells us the node is
        // still alive. Therefore we propagate only the first success, but no failures.
        // The failure case is handled through the timeout of the whole operation.
        let eventLoop = self.actorSystem._eventLoopGroup.next()
        let firstSuccessful = eventLoop.makePromise(of: SWIM.PingResponse<SWIMActorShell, SWIMActorShell>.self)
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
            let pingRequestResponse = try await firstSuccessful.futureResult.get()
            self.handlePingRequestResponse(response: pingRequestResponse, pinged: peerToPing)
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
    internal func handlePingResponse(
        response: SWIM.PingResponse<SWIMActorShell, SWIMActorShell>,
        pingRequestOrigin: SWIMActorShell?,
        pingRequestSequenceNumber: SWIM.SequenceNumber?
    ) -> SWIM.PingResponse<SWIMActorShell, SWIMActorShell> {
        var pingRequestOriginResponse: SWIM.PingResponse<SWIMActorShell, SWIMActorShell>?

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

    internal func handlePingRequestResponse(response: SWIM.PingResponse<SWIMActorShell, SWIMActorShell>, pinged: SWIMActorShell) {
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
    private func tryAnnounceMemberReachability(change: SWIM.MemberStatusChangedEvent<SWIMActorShell>?) {
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

    private func handleGossipPayloadProcessedDirective(_ directive: SWIM.Instance<SWIMActorShell, SWIMActorShell, SWIMActorShell>.GossipProcessedDirective) {
        switch directive {
        case .applied(let change):
            self.tryAnnounceMemberReachability(change: change)
        }
    }

    /// We have to handle *every* response, because they adjust the value of the timeouts we'll be using in future probes.
    private func handleEveryPingRequestResponse(response: SWIM.PingResponse<SWIMActorShell, SWIMActorShell>, pinged: SWIMActorShell) {
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

    /// ``SWIMPeer`` conformance; turn this call into a ``ping(origin:payload:sequenceNumber)`` distributed call with a ``timeout``.
    nonisolated func ping(
        payload: SWIM.GossipPayload<SWIMActorShell>,
        from pingOrigin: SWIMActorShell,
        timeout: Duration,
        sequenceNumber: SWIM.SequenceNumber
    ) async throws -> SWIM.PingResponse<SWIMActorShell, SWIMActorShell> {
        return try await RemoteCall.with(timeout: .nanoseconds(timeout.nanoseconds)) {
            let response = try await self.ping(origin: pingOrigin, payload: payload, sequenceNumber: sequenceNumber)
            if case .nack = response {
                throw SWIMActorError.illegalMessageType("Unexpected .nack reply to .ping message! Was: \(response)")
            }
            return response
        }
    }

    distributed func ping(
        origin: SWIMActorShell,
        payload: SWIM.GossipPayload<SWIMActorShell>,
        sequenceNumber: SWIM.SequenceNumber
    ) async throws -> SWIM.PingResponse<SWIMActorShell, SWIMActorShell> {
        self.log.trace("Received ping@\(sequenceNumber)", metadata: self.swim.metadata([
            "swim/ping/origin": "\(origin.id)",
            "swim/ping/payload": "\(payload)",
            "swim/ping/seqNr": "\(sequenceNumber)",
        ]))
        self.metrics.shell.messageInboundCount.increment()

        for directive in self.swim.onPing(
            pingOrigin: origin,
            payload: payload,
            sequenceNumber: sequenceNumber
        ) {
            switch directive {
            case .gossipProcessed(let gossipDirective):
                self.handleGossipPayloadProcessedDirective(gossipDirective)

            case .sendAck(_, let pingedTarget, let incarnation, let payload, let sequenceNumber):
                return .ack(target: pingedTarget, incarnation: incarnation, payload: payload, sequenceNumber: sequenceNumber)
            }
        }

        assertionFailure("ping should always return ack")

        throw SWIMActorError.noResponse
    }
    
    nonisolated func pingRequest(
        target: SWIMActorShell,
        payload: SWIM.GossipPayload<SWIMActorShell>,
        from pingRequestOrigin: SWIMActorShell,
        timeout: Duration,
        sequenceNumber: SWIM.SequenceNumber
    ) async throws -> SWIM.PingResponse<SWIMActorShell, SWIMActorShell> {
        try await RemoteCall.with(timeout: .nanoseconds(timeout.nanoseconds)) {
            try await self.pingRequest(
                target: target,
                pingRequestOrigin: pingRequestOrigin,
                payload: payload,
                sequenceNumber: sequenceNumber
            )
        }
    }


    distributed func pingRequest(
        target: SWIMActorShell,
        pingRequestOrigin: SWIMActorShell,
        payload: SWIM.GossipPayload<SWIMActorShell>,
        sequenceNumber pingRequestSequenceNumber: SWIM.SequenceNumber
    ) async throws -> SWIM.PingResponse<SWIMActorShell, SWIMActorShell> {
        self.log.trace("Received pingRequest@\(pingRequestSequenceNumber) [\(target)] from [\(pingRequestOrigin)]", metadata: self.swim.metadata([
            "swim/pingRequest/origin": "\(pingRequestOrigin)",
            "swim/pingRequest/payload": "\(payload)",
            "swim/pingRequest/seqNr": "\(pingRequestSequenceNumber)",
        ]))
        self.metrics.shell.messageInboundCount.increment()

        for directive in self.swim.onPingRequest(
            target: target,
            pingRequestOrigin: pingRequestOrigin,
            payload: payload,
            sequenceNumber: pingRequestSequenceNumber
        ) {
            switch directive {
            case .gossipProcessed(let gossipDirective):
                self.handleGossipPayloadProcessedDirective(gossipDirective)

            case .sendPing(let target, let payload, let pingRequestOrigin, let pingRequestSequenceNumber, let timeout, let pingSequenceNumber):
                return await self.sendPing(
                    to: target,
                    payload: payload,
                    pingRequestOrigin: pingRequestOrigin,
                    pingRequestSequenceNumber: pingRequestSequenceNumber,
                    timeout: timeout,
                    sequenceNumber: pingSequenceNumber
                )
            }
        }

        assertionFailure("pingRequest should always return ack/nack from sendPing")

        throw SWIMActorError.noResponse
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Local functions

    func monitor(node: UniqueNode) {
        guard self.actorSystem.cluster.uniqueNode.node != node.node else {
            return // no need to monitor ourselves, nor a replacement of us (if node is our replacement, we should have been dead already)
        }

        self.sendFirstRemotePing(on: node)
    }

    nonisolated func confirmDead(node: UniqueNode) {
        Task {
            await self.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): rename once https://github.com/apple/swift/pull/42098 is implemented
                let directive = __secretlyKnownToBeLocal.swim.confirmDead(peer: node.asSWIMNode.swimShell(__secretlyKnownToBeLocal.actorSystem))
                switch directive {
                case .applied(let change):
                    __secretlyKnownToBeLocal.log.warning("Confirmed node .dead: \(change)", metadata: __secretlyKnownToBeLocal.swim.metadata(["swim/change": "\(change)"]))
                case .ignored:
                    return
                }
            }
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

    func _getMembershipState() -> [SWIM.Member<SWIMActorShell>] {
        Array(self.swim.members)
    }

    func _configureSWIM(_ configure: (inout SWIM.Instance<SWIMActorShell, SWIMActorShell, SWIMActorShell>) throws -> Void) rethrows {
        try configure(&self.swim)
    }

    nonisolated var description: String {
        "\(Self.self)(\(self.id))"
    }
}

extension SWIMActorShell {
    static let name: String = "swim"

    static var props: _Props {
        var ps = _Props()
        ps._knownActorName = ActorPath._swim.name
        ps._wellKnown = true
        return ps.metrics(group: "swim.shell", measure: [.serialization, .deserialization])
    }
}

extension ActorID {
    static func _swim(on node: UniqueNode) -> ActorID {
        .init(remote: node, path: ActorPath._swim, incarnation: .wellKnown)
    }
}

extension ActorPath {
    static let _swim: ActorPath = try! ActorPath._user.appending(SWIMActorShell.name)
}
