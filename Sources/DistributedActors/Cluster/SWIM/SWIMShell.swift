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

import Logging

/// The SWIM shell is responsible for driving all interactions of the `SWIM.Instance` with the outside world.
///
/// - SeeAlso: `SWIM.Instance` for detailed documentation about the SWIM protocol implementation.
internal struct SWIMShell {
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

            // TODO: install an .cluster.down(my node) with context.defer in case we crash? Or crash system when this crashes: issue #926

            let probeInterval = settings.probeInterval
            context.timers.startSingle(key: SWIM.Shell.periodicPingKey, message: .local(.pingRandomMember), delay: probeInterval)
            let shell = SWIMShell(SWIMInstance(settings, myShellMyself: context.myself, myNode: context.system.cluster.node), clusterRef: clusterRef)

            return SWIMShell.ready(shell: shell)
        }
    }

    static func ready(shell: SWIMShell) -> Behavior<SWIM.Message> {
        .receive { context, wrappedMessage in
            switch wrappedMessage {
            case .remote(let message):
                shell.receiveRemoteMessage(context: context, message: message)
                return .same

            case .local(let message):
                shell.receiveLocalMessage(context: context, message: message)
                return .same

            case ._testing(let message):
                switch message {
                case .getMembershipState(let replyTo):
                    context.log.trace("getMembershipState from \(replyTo), state: \(shell.swim._allMembersDict)")
                    replyTo.tell(SWIM.MembershipState(membershipState: shell.swim._allMembersDict))
                    return .same
                }
            }
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Receiving messages

    func receiveRemoteMessage(context: ActorContext<SWIM.Message>, message: SWIM.RemoteMessage) {
        switch message {
        case .ping(let replyTo, let payload):
            self.tracelog(context, .receive, message: message)
            self.handlePing(context: context, replyTo: replyTo, payload: payload)

        case .pingReq(let target, let replyTo, let payload):
            self.tracelog(context, .receive, message: message)
            self.handlePingReq(context: context, target: target, replyTo: replyTo, payload: payload)
        }
    }

    private func handlePing(context: ActorContext<SWIM.Message>, replyTo: ActorRef<SWIM.PingResponse>, payload: SWIM.Payload) {
        self.processGossipPayload(context: context, payload: payload)
        switch self.swim.onPing() {
        case .reply(let ack):
            self.tracelog(context, .reply(to: replyTo), message: ack)
            replyTo.tell(ack)

            // TODO: push the process gossip into SWIM as well?
            // TODO: the payloadToProcess is the same as `payload` here... but showcasing
            self.processGossipPayload(context: context, payload: payload)
        }
    }

    private func handlePingReq(context: ActorContext<SWIM.Message>, target: ActorRef<SWIM.Message>, replyTo: ActorRef<SWIM.PingResponse>, payload: SWIM.Payload) {
        context.log.trace("Received request to ping [\(target)] from [\(replyTo)] with payload [\(payload)]")
        self.processGossipPayload(context: context, payload: payload)

        if !self.swim.isMember(target) {
            self.ensureAssociated(context, remoteNode: target.address.node) { result in
                switch result {
                case .success:
                    // The case when member is a suspect is already handled in `processGossipPayload`, since
                    // payload will always contain suspicion about target member
                    self.swim.addMember(target, status: .alive(incarnation: 0)) // TODO: push into SWIM?
                    self.sendPing(context: context, to: target, pingReqOrigin: replyTo)
                case .failure(let error):
                    context.log.warning("Unable to obtain association for remote \(target.address)... Maybe it was tombstoned? Error: \(error)")
                }
            }
        } else {
            self.sendPing(context: context, to: target, pingReqOrigin: replyTo)
        }
    }

    func receiveLocalMessage(context: ActorContext<SWIM.Message>, message: SWIM.LocalMessage) {
        switch message {
        case .pingRandomMember:
            self.handleNewProtocolPeriod(context)

        case .monitor(let node):
            self.handleMonitor(context, node: node)

        case .confirmDead(let node):
            self.handleConfirmDead(context, deadNode: node)
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Sending ping, ping-req and friends

    /// - parameter pingReqOrigin: is set only when the ping that this is a reply to was originated as a `pingReq`.
    func sendPing(
        context: ActorContext<SWIM.Message>,
        to target: ActorRef<SWIM.Message>,
        pingReqOrigin: ActorRef<SWIM.PingResponse>?
    ) {
        let payload = self.swim.makeGossipPayload(to: target)

        context.log.trace("Sending ping to [\(target)] with payload [\(payload)]")

        let startPing = context.system.metrics.uptimeNanoseconds()
        let response = target.ask(for: SWIM.PingResponse.self, timeout: self.swim.dynamicLHMPingTimeout) {
            let ping = SWIM.RemoteMessage.ping(replyTo: $0, payload: payload)
            self.tracelog(context, .ask(target), message: ping)
            return SWIM.Message.remote(ping)
        }
        response._onComplete { _ in context.system.metrics.recordSWIMPingPingResponseTime(since: startPing) }

        // timeout is already handled by the ask, so we can set it to infinite here to not have two timeouts
        context.onResultAsync(of: response, timeout: .effectivelyInfinite) { res in
            self.handlePingResponse(context: context, result: res, pingedMember: target, pingReqOrigin: pingReqOrigin)
            return .same
        }
    }

    func sendPingRequests(context: ActorContext<SWIM.Message>, toPing: ActorRef<SWIM.Message>) {
        guard let lastKnownStatus = self.swim.status(of: toPing) else {
            context.log.info("Skipping ping requests after failed ping to [\(toPing)] because node has been removed from member list")
            return
        }

        // TODO: also push much of this down into SWIM.Instance

        // select random members to send ping requests to
        let membersToPingRequest = self.swim.membersToPingRequest(target: toPing)

        guard !membersToPingRequest.isEmpty else {
            // no nodes available to ping, so we have to assume the node suspect right away
            if let lastIncarnation = lastKnownStatus.incarnation {
                switch self.swim.mark(toPing, as: self.swim.makeSuspicion(incarnation: lastIncarnation)) {
                case .applied(_, let currentStatus):
                    context.log.info("No members to ping-req through, marked [\(toPing)] immediately as [\(currentStatus)].")
                    return
                case .ignoredDueToOlderStatus(let currentStatus):
                    context.log.info("No members to ping-req through to [\(toPing)], was already [\(currentStatus)].")
                    return
                }
            } else {
                context.log.trace("Not marking .suspect, as [\(toPing)] is already dead.") // "You are already dead!"
                return
            }
        }

        // We are only interested in successful pings, as a single success tells us the node is
        // still alive. Therefore we propagate only the first success, but no failures.
        // The failure case is handled through the timeout of the whole operation.
        let firstSuccess = context.system._eventLoopGroup.next().makePromise(of: SWIM.PingResponse.self)
        let pingTimeout = self.swim.dynamicLHMPingTimeout
        for member in membersToPingRequest {
            let payload = self.swim.makeGossipPayload(to: toPing)

            context.log.trace("Sending ping request for [\(toPing)] to [\(member)] with payload: \(payload)")

            let startPingReq = context.system.metrics.uptimeNanoseconds()
            let answer = member.ref.ask(for: SWIM.PingResponse.self, timeout: pingTimeout) {
                let pingReq = SWIM.RemoteMessage.pingReq(target: toPing, replyTo: $0, payload: payload)
                self.tracelog(context, .ask(member.ref), message: pingReq)
                return SWIM.Message.remote(pingReq)
            }

            answer._onComplete { result in
                context.system.metrics.recordSWIMPingPingResponseTime(since: startPingReq)

                // We choose to cascade only successes;
                // While this has a slight timing implication on time timeout of the pings -- the node that is last
                // in the list that we ping, has slightly less time to fulfil the "total ping timeout"; as we set a total timeout on the entire `firstSuccess`.
                // In practice those timeouts will be relatively large (seconds) and the few millis here should not have a large impact on correctness.
                if case .success(let response) = result {
                    firstSuccess.succeed(response)
                }
            }
        }

        context.onResultAsync(of: firstSuccess.futureResult, timeout: pingTimeout) { result in
            self.handlePingRequestResult(context: context, result: result, pingedMember: toPing)
            return .same
        }
    }

    /// - parameter pingReqOrigin: is set only when the ping that this is a reply to was originated as a `pingReq`.
    func handlePingResponse(
        context: ActorContext<SWIM.Message>,
        result: Result<SWIM.PingResponse, Error>,
        pingedMember: ActorRef<SWIM.Message>,
        pingReqOrigin: ActorRef<SWIM.PingResponse>?
    ) {
        self.tracelog(context, .receive(pinged: pingedMember), message: result)

        switch result {
        case .failure(let err):
            if let timeoutError = err as? TimeoutError {
                context.log.debug(
                    """
                    Did not receive ack from \(reflecting: pingedMember.address) within [\(timeoutError.timeout.prettyDescription)]. \
                    Sending ping requests to other members.
                    """,
                    metadata: [
                        "swim/target": "\(self.swim.member(for: pingedMember), orElse: "nil")",
                    ]
                )
            } else {
                context.log.warning("\(err) Did not receive ack from \(reflecting: pingedMember.address) within configured timeout. Sending ping requests to other members.")
            }
            if let pingReqOrigin = pingReqOrigin {
                self.swim.adjustLHMultiplier(.probeWithMissedNack)
                pingReqOrigin.tell(.nack(target: pingedMember))
            } else {
                self.swim.adjustLHMultiplier(.failedProbe)
                self.sendPingRequests(context: context, toPing: pingedMember)
            }

        case .success(.ack(let pinged, let incarnation, let payload)):
            // We're proxying an ack payload from ping target back to ping source.
            // If ping target was a suspect, there'll be a refutation in a payload
            // and we probably want to process it asap. And since the data is already here,
            // processing this payload will just make gossip convergence faster.
            self.processGossipPayload(context: context, payload: payload)
            context.log.debug("Received ack from [\(pinged)] with incarnation [\(incarnation)] and payload [\(payload)]", metadata: self.swim.metadata)
            self.markMember(context, latest: SWIMMember(ref: pinged, status: .alive(incarnation: incarnation), protocolPeriod: self.swim.protocolPeriod))
            if let pingReqOrigin = pingReqOrigin {
                pingReqOrigin.tell(.ack(target: pinged, incarnation: incarnation, payload: payload))
            } else {
                // LHA-probe multiplier for pingReq responses is hanled separately `handlePingRequestResult`
                self.swim.adjustLHMultiplier(.successfulProbe)
            }
        case .success(.nack):
            break
        }
    }

    func handlePingRequestResult(context: ActorContext<SWIM.Message>, result: Result<SWIM.PingResponse, Error>, pingedMember: ActorRef<SWIM.Message>) {
        self.tracelog(context, .receive(pinged: pingedMember), message: result)
        // TODO: do we know here WHO replied to us actually? We know who they told us about (with the ping-req), could be useful to know

        switch self.swim.onPingRequestResponse(result, pingedMember: pingedMember) {
        case .alive(_, let payloadToProcess):
            self.processGossipPayload(context: context, payload: payloadToProcess)
        case .newlySuspect:
            context.log.debug("Member [\(pingedMember)] marked as suspect")
        case .nackReceived:
            context.log.debug("Received `nack` from indirect probing of [\(pingedMember)]")
        default:
            () // TODO: revisit logging more details here
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handling local messages

    /// Scheduling a new protocol period and performing the actions for the current protocol period
    func handleNewProtocolPeriod(_ context: ActorContext<SWIM.Message>) {
        context.timers.startSingle(key: SWIM.Shell.periodicPingKey, message: .local(.pingRandomMember), delay: self.swim.dynamicLHMProtocolInterval)
        self.pingRandomMember(context)
    }

    func pingRandomMember(_ context: ActorContext<SWIM.Message>) {
        context.log.trace("Periodic ping random member, among: \(self.swim._allMembersDict.count)", metadata: self.swim.metadata)

        // needs to be done first, so we can gossip out the most up to date state
        self.checkSuspicionTimeouts(context: context)

        if let toPing = swim.nextMemberToPing() {
            self.sendPing(context: context, to: toPing, pingReqOrigin: nil)
        }
        self.swim.incrementProtocolPeriod()
    }

    func handleMonitor(_ context: ActorContext<SWIM.Message>, node: UniqueNode) {
        guard context.system.cluster.node.node != node.node else {
            return // no need to monitor ourselves, nor a replacement of us (if node is our replacement, we should have been dead already)
        }

        self.sendFirstRemotePing(context, on: node)
    }

    // TODO: test in isolation
    func handleConfirmDead(_ context: ActorContext<SWIM.Message>, deadNode node: UniqueNode) {
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

            switch self.swim.mark(member.ref, as: .dead) {
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
            self.swim.addMember(context.system._resolve(context: .init(address: ._swim(on: node), system: context.system)), status: .dead)
        }
    }

    func checkSuspicionTimeouts(context: ActorContext<SWIM.Message>) {
        context.log.trace(
            "Checking suspicion timeouts...",
            metadata: [
                "swim/suspects": "\(self.swim.suspects)",
                "swim/all": "\(self.swim._allMembersDict)",
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

    private func markMember(_ context: ActorContext<SWIM.Message>, latest: SWIM.Member) {
        switch self.swim.mark(latest.ref, as: latest.status) {
        case .applied(let previousStatus, _):
            context.log.trace(
                "Marked \(latest.node) as \(latest.status), announcing reachability change",
                metadata: [
                    "swim/member": "\(latest)",
                    "swim/previousStatus": "\(previousStatus, orElse: "nil")",
                ]
            )
            let statusChange = SWIM.Instance.MemberStatusChange(fromStatus: previousStatus, member: latest)
            self.tryAnnounceMemberReachability(context, change: statusChange)
        case .ignoredDueToOlderStatus:
            () // context.log.trace("No change \(latest), currentStatus remains [\(currentStatus)]. No reachability change to announce")
        }
    }

    // TODO: since this is applying payload to SWIM... can we do this in SWIM itself rather?
    func processGossipPayload(context: ActorContext<SWIM.Message>, payload: SWIM.Payload) {
        switch payload {
        case .membership(let members):
            self.processGossipedMembership(members: members, context: context)

        case .none:
            return // ok
        }
    }

    func processGossipedMembership(members: SWIM.Members, context: ActorContext<SWIM.Message>) {
        for member in members {
            switch self.swim.onGossipPayload(about: member) {
            case .connect(let node, let continueAddingMember):
                // ensuring a connection is asynchronous, but executes callback in actor context
                self.ensureAssociated(context, remoteNode: node) { uniqueAddressResult in
                    switch uniqueAddressResult {
                    case .success(let uniqueAddress):
                        continueAddingMember(.success(uniqueAddress))
                    case .failure(let error):
                        continueAddingMember(.failure(error))
                        context.log.warning("Unable ensure association with \(node), could it have been tombstoned? Error: \(error)")
                    }
                }

            case .ignored(let level, let message):
                if let level = level, let message = message {
                    context.log.log(level: level, message, metadata: self.swim.metadata)
                }

            case .applied(let change, _, _):
                self.tryAnnounceMemberReachability(context, change: change)
            }
        }
    }

    /// Announce to the `ClusterShell` a change in reachability of a member.
    private func tryAnnounceMemberReachability(_ context: ActorContext<SWIM.Message>, change: SWIM.Instance.MemberStatusChange?) {
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
        switch change.toStatus {
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
                "Node \(change.member.node) determined [.\(change.toStatus)] (was [\(change.fromStatus, orElse: "nil")].",
                metadata: [
                    "swim/member": "\(change.member)",
                ]
            )
        }

        let reachability: Cluster.MemberReachability
        switch change.toStatus {
        case .alive, .suspect:
            reachability = .reachable
        case .unreachable, .dead:
            reachability = .unreachable
        }

        self.clusterRef.tell(.command(.failureDetectorReachabilityChanged(change.member.node, reachability)))
    }

    /// Use to ensure an association to given remote node exists; as one may not always be sure a connection has been already established,
    /// when a remote ref is discovered through other means (such as SWIM's gossiping).
    func ensureAssociated(_ context: ActorContext<SWIM.Message>, remoteNode: UniqueNode?, continueWithAssociation: @escaping (Result<UniqueNode, Error>) -> Void) {
        // this is a local node, so we don't need to connect first
        guard let remoteNode = remoteNode else {
            continueWithAssociation(.success(context.system.cluster.node))
            return
        }

        guard let clusterShell = context.system._cluster else {
            continueWithAssociation(.failure(EnsureAssociationError("ClusterShell not available when trying to ensure associated with: \(reflecting: remoteNode)")))
            return
        }

        let associationState = clusterShell.getEnsureAssociation(with: remoteNode)
        switch associationState {
        case .association(let control):
            continueWithAssociation(.success(control.remoteNode))
        case .tombstone:
            let msg = "Association target node is already .tombstoned, not associating. Node \(reflecting: remoteNode) likely to be removed from gossip shortly."
            continueWithAssociation(.failure(EnsureAssociationError(msg)))
            return // we shall not associate with this tombstoned node (!)
        }

        // ensure connection to new node ~~~
        // TODO: might need a cache in the swim shell? // actual solution being a shared concurrent hashmap...
        // FIXME: use reasonable timeout and back off? issue #141
        let ref = context.messageAdapter(from: ClusterShell.HandshakeResult.self) { (result: ClusterShell.HandshakeResult) in
            switch result {
            case .success(let uniqueNode):
                return SWIM.Message.local(.monitor(uniqueNode))
            case .failure(let error):
                context.log.debug("Did not associate with \(reflecting: remoteNode), reason: \(error)")
                return nil // drop the message
            }
        }

        context.log.trace("Requesting handshake with \(remoteNode.node)")
        self.clusterRef.tell(.command(.handshakeWith(remoteNode.node, replyTo: ref)))
    }

    struct EnsureAssociationError: Error {
        let message: String

        init(_ message: String) {
            self.message = message
        }
    }

    /// This is effectively joining the SWIM membership of the other member.
    func sendFirstRemotePing(_ context: ActorContext<SWIM.Message>, on node: UniqueNode) {
        let remoteSwimAddress = ActorAddress._swim(on: node)

        let resolveContext = ResolveContext<SWIM.Message>(address: remoteSwimAddress, system: context.system)
        let remoteSwimRef = context.system._resolve(context: resolveContext)

        // We need to include the member immediately, rather than when we have ensured the association.
        // This is because if we're not able to establish the association, we still want to re-try soon (in the next ping round),
        // and perhaps then the other node would accept the association (perhaps some transient network issues occurred OR the node was
        // already dead when we first try to ping it). In those situations, we need to continue the protocol until we're certain it is
        // suspect and unreachable, as without signalling unreachable the high-level membership would not have a chance to notice and
        // call the node [Cluster.MemberStatus.down].
        self.swim.addMember(remoteSwimRef, status: .alive(incarnation: 0))

        // TODO: we are sending the ping here to initiate cluster membership. Once available this should do a state sync instead
        self.sendPing(context: context, to: remoteSwimRef, pingReqOrigin: nil)
    }
}

extension SWIMShell {
    static let name: String = "swim"
    static let naming: ActorNaming = .unique(SWIMShell.name)

    static let periodicPingKey = TimerKey("\(SWIMShell.name)/periodic-ping")
}

extension ActorAddress {
    internal static func _swim(on node: UniqueNode) -> ActorAddress {
        .init(node: node, path: ActorPath._swim, incarnation: .wellKnown)
    }
}

extension ActorPath {
    internal static let _swim: ActorPath = try! ActorPath._clusterShell.appending(SWIMShell.name)
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
