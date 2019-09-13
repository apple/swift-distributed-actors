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

import Logging

/// The SWIM shell is responsible for driving all interactions of the `SWIM.Instance` with the outside world.
///
/// - SeeAlso: `SWIM.Instance` for detailed documentation about the SWIM protocol implementation.
internal struct SWIMShell {
    let swim: SWIM.Instance
    let clusterRef: ClusterShell.Ref

    var settings: SWIM.Settings {
        return self.swim.settings
    }

    internal init(_ swim: SWIM.Instance, clusterRef: ClusterShell.Ref) {
        self.swim = swim
        self.clusterRef = clusterRef
    }

    internal init(settings: SWIM.Settings, clusterRef: ClusterShell.Ref) {
        self.init(SWIM.Instance(settings), clusterRef: clusterRef)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Behaviors

    /// Initial behavior, kicks off timers and becomes `ready`.
    // FIXME: utilize FailureObserver
    var behavior: Behavior<SWIM.Message> {
        return .setup { context in

            // TODO: install an .cluster.down(my node) with context.defer in case we crash? Or crash system when this crashes: issue #926

            let probeInterval = self.swim.settings.gossip.probeInterval
            context.timers.startPeriodic(key: SWIM.Shell.periodicPingKey, message: .local(.pingRandomMember), interval: probeInterval)

            self.swim.addMyself(context.myself, node: context.system.cluster.node)

            return self.ready
        }
    }

    var ready: Behavior<SWIM.Message> {
        return .receive { context, wrappedMessage in
            switch wrappedMessage {
            case .remote(let message):
                self.receiveRemoteMessage(context: context, message: message)
                return .same

            case .local(let message):
                self.receiveLocalMessage(context: context, message: message)
                return .same

            case .testing(let message):
                switch message {
                case .getMembershipState(let replyTo):
                    // NOT tracelogging it on purpose, it is a testing message
                    replyTo.tell(SWIM.MembershipState(membershipState: self.swim._allMembersDict))
                    return .same
                }
            }
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Receiving messages

    func receiveRemoteMessage(context: ActorContext<SWIM.Message>, message: SWIM.RemoteMessage) {
        switch message {
        case .ping(let lastKnownStatus, let replyTo, let payload):
            self.tracelog(context, .receive, message: message)

            switch self.swim.onPing(lastKnownStatus: lastKnownStatus) {
            case .reply(let ack, let warning):
                self.tracelog(context, .reply(to: replyTo), message: ack)
                replyTo.tell(ack)

                if let warning = warning {
                    context.log.warning("\(warning)")
                }

                // TODO: push the process gossip into SWIM as well?
                // TODO: the payloadToProcess is the same as `payload` here... but showcasing
                self.processGossipPayload(context: context, payload: payload)
            }

        case .pingReq(let target, let lastKnownStatus, let replyTo, let payload):
            self.tracelog(context, .receive, message: message)
            context.log.trace("Received request to ping [\(target)] from [\(replyTo)] with payload [\(payload)]")

            if !self.swim.isMember(target) {
                self.ensureAssociated(context, remoteNode: target.address.node?.node) { _ in
                    self.swim.addMember(target, status: lastKnownStatus) // TODO: push into SWIM?
                    self.sendPing(context: context, to: target, lastKnownStatus: lastKnownStatus, pingReqOrigin: replyTo)
                }
            } else {
                self.sendPing(context: context, to: target, lastKnownStatus: lastKnownStatus, pingReqOrigin: replyTo)
            }
            self.processGossipPayload(context: context, payload: payload)
        }
    }

    func receiveLocalMessage(context: ActorContext<SWIM.Message>, message: SWIM.LocalMessage) {
        switch message {
        case .pingRandomMember:
            self.handlePingRandomMember(context)

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
        lastKnownStatus: SWIM.Status,
        pingReqOrigin: ActorRef<SWIM.Ack>?
    ) {
        let payload = self.swim.makeGossipPayload()
        context.log.trace("Sending ping to [\(target)] with payload [\(payload)]")

        let response = target.ask(for: SWIM.Ack.self, timeout: self.swim.settings.failureDetector.pingTimeout) {
            let ping = SWIM.RemoteMessage.ping(lastKnownStatus: lastKnownStatus, replyTo: $0, payload: payload)
            self.tracelog(context, .ask(target), message: ping)
            return SWIM.Message.remote(ping)
        }

        // timeout is already handled by the ask, so we can set it to infinite here to not have two timeouts
        context.onResultAsync(of: response, timeout: .effectivelyInfinite) {
            self.handlePingResponse(context: context, result: $0, pingedMember: target, pingReqOrigin: pingReqOrigin)
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
                context.log.info("No members to ping-req through, marking [\(toPing)] immediately as [.suspect]. Members: [\(self.swim._allMembersDict)]")
                self.swim.mark(toPing, as: .suspect(incarnation: lastIncarnation))
                return
            } else {
                context.log.debug("Not marking .suspect, as [\(toPing)] is already dead.") // "You are already dead!"
                return
            }
        }

        // We are only interested in successful pings, as a single success tells us the node is
        // still alive. Therefore we propagate only the first success, but no failures.
        // The failure case is handled through the timeout of the whole operation.
        let firstSuccess = context.system.eventLoopGroup.next().makePromise(of: SWIM.Ack.self)
        let pingTimeout = self.swim.settings.failureDetector.pingTimeout
        for member in membersToPingRequest {
            let payload = self.swim.makeGossipPayload()

            context.log.trace("Sending ping request for [\(toPing)] to [\(member)] with payload: \(payload)")

            let answer = member.ref.ask(for: SWIM.Ack.self, timeout: pingTimeout) {
                let pingReq = SWIM.RemoteMessage.pingReq(target: toPing, lastKnownStatus: lastKnownStatus, replyTo: $0, payload: payload)
                self.tracelog(context, .ask(member.ref), message: pingReq)
                return SWIM.Message.remote(pingReq)
            }

            // We choose to cascade only successes;
            // While this has a slight timing implication on time timeout of the pings -- the node that is last
            // in the list that we ping, has slightly less time to fulfil the "total ping timeout"; as we set a total timeout on the entire `firstSuccess`.
            // In practice those timeouts will be relatively large (seconds) and the few millis here should not have a large impact on correctness.
            answer.nioFuture.cascadeSuccess(to: firstSuccess)
        }

        context.onResultAsync(of: firstSuccess.futureResult, timeout: pingTimeout) { result in
            self.handlePingRequestResult(context: context, result: result, pingedMember: toPing)
            return .same
        }
    }

    /// - parameter pingReqOrigin: is set only when the ping that this is a reply to was originated as a `pingReq`.
    func handlePingResponse(
        context: ActorContext<SWIM.Message>,
        result: Result<SWIM.Ack, ExecutionError>,
        pingedMember: ActorRef<SWIM.Message>,
        pingReqOrigin: ActorRef<SWIM.Ack>?
    ) {
        self.tracelog(context, .receive(pinged: pingedMember), message: result)

        switch result {
        case .failure(let err):
            if let timeoutError = err.extractUnderlying(as: TimeoutError.self) {
                context.log.warning("Did not receive ack from [\(pingedMember)] within [\(timeoutError.timeout.prettyDescription)]. Sending ping requests to other members.")
            } else {
                context.log.warning("\(err) Did not receive ack from [\(pingedMember)] within configured timeout. Sending ping requests to other members.")
            }
            // TODO: when adding lifeguard extensions, reply with .nack
            let originOfPingWasPingRequest = pingReqOrigin != nil
            if !originOfPingWasPingRequest {
                self.sendPingRequests(context: context, toPing: pingedMember)
            }
        case .success(let ack):
            context.log.trace("Received ack from [\(ack.pinged)] with incarnation [\(ack.incarnation)] and payload [\(ack.payload)]")
            self.swim.mark(ack.pinged, as: .alive(incarnation: ack.incarnation)) // TODO: log ?
            pingReqOrigin?.tell(ack)
            self.processGossipPayload(context: context, payload: ack.payload)
        }
    }

    func handlePingRequestResult(context: ActorContext<SWIM.Message>, result: Result<SWIM.Ack, ExecutionError>, pingedMember: ActorRef<SWIM.Message>) {
        self.tracelog(context, .receive(pinged: pingedMember), message: result)
        // TODO: do we know here WHO replied to us actually? We know who they told us about (with the ping-req), could be useful to know

        switch self.swim.onPingRequestResponse(result, pingedMember: pingedMember) {
        case .alive(_, let payloadToProcess):
            self.processGossipPayload(context: context, payload: payloadToProcess)
        case .newlySuspect:
            context.log.debug("Member [\(pingedMember)] marked as suspect")
        default:
            () // TODO: revisit logging more details here
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handling local messages

    func handlePingRandomMember(_ context: ActorContext<SWIM.Message>) {
        context.log.trace("Received periodic trigger to ping random member", metadata: self.swim.metadata)

        // needs to be done first, so we can gossip out the most up to date state
        self.checkSuspicionTimeouts(context: context)

        if let toPing = swim.nextMemberToPing() {
            if let lastKnownStatus = swim.status(of: toPing) {
                self.sendPing(context: context, to: toPing, lastKnownStatus: lastKnownStatus, pingReqOrigin: nil)
            }
        }
        self.swim.incrementProtocolPeriod()
    }

    func handleMonitor(_ context: ActorContext<SWIM.Message>, node: Node) {
        self.ensureAssociated(context, remoteNode: node) { uniqueNode in
            guard let uniqueNode = uniqueNode else {
                return // seems we were about to handleJoin to our own node, thus: nothing to do
            }

            assert(uniqueNode.node == node, "We received a successful connection for other node than we asked to. This is a bug in the ClusterShell.")
            self.sendFirstRemotePing(context, on: uniqueNode)
        }
    }

    // TODO: test in isolation
    func handleConfirmDead(_ context: ActorContext<SWIM.Message>, deadNode node: UniqueNode) {
        if let member = self.swim.member(for: node) {
            context.log.info("Confirming .dead member [\(member)]")
            // It is important to not infinitely loop cluster.down + confirmDead messages;
            // See: `.confirmDead` for more rationale
            if member.isDead {
                return // member is already dead, nothing else to do here.
            }

            // We are diverging from the SWIM paper here in that we store the `.dead` state, instead
            // of removing the node from the member list. We do that in order to prevent dead nodes
            // from being re-added to the cluster.
            // TODO: add time of death to the status
            // TODO: GC tombstones after a day

            switch self.swim.mark(member.ref, as: .dead) {
            case .applied(let .some(previousState)):
                if previousState.isSuspect || previousState.isUnreachable {
                    context.log.warning("""
                    Marked [\(member)] as DEAD. \
                    Was marked \(previousState) in protocol period [\(member.protocolPeriod)], current period [\(self.swim.protocolPeriod)].
                    """)
                } else {
                    context.log.warning("""
                    Marked [\(member)] as DEAD. \
                    Node was previously alive, and now forced DEAD. Current period [\(self.swim.protocolPeriod)].
                    """)
                }
            case .applied:
                // TODO: marking is more about "marking a node as dead" should we rather log addresses and not actor paths?
                context.log.warning("Marked [\(member)] as dead. Node was not previously known to SWIM.")
                // TODO: add tracelog about marking a node dead here?

            case .ignoredDueToOlderStatus:
                // TODO: make sure a fatal error in SWIM.Shell causes a system shutdown?
                fatalError("Marking [\(member)] as DEAD failed! This should never happen, dead is the terminal status. SWIM instance: \(self.swim)")
            }
        } else {
            context.log.warning("Attempted to .confirmDead(\(node)), yet no such member known to \(self)!") // TODO: would want to see if this happens when we fail these tests
            // even if not known, we invent such node and store it as dead
            self.swim.addMember(context.system._resolve(context: .init(address: SWIMShell.address(on: node), system: context.system)), status: .dead)
        }
    }

    func checkSuspicionTimeouts(context: ActorContext<SWIM.Message>) {
        // TODO: push more of logic into SWIM instance, the calculating
        // FIXME: use decaying timeout as proposed in lifeguard paper
        let timeoutPeriods = (self.swim.protocolPeriod - self.swim.settings.failureDetector.suspicionTimeoutPeriodsMax)
        for member in self.swim.suspects where member.protocolPeriod <= timeoutPeriods {
            if let node = member.ref.address.node {
                if let incarnation = member.status.incarnation {
                    self.swim.mark(member.ref, as: .unreachable(incarnation: incarnation))
                }
                // if unreachable or dead, we don't need to notify the clusterRef
                if member.status.isUnreachable || member.status.isDead {
                    continue
                }
                self.clusterRef.tell(.command(.reachabilityChanged(node, .unreachable)))
            }
        }
    }

    // TODO: since this is applying payload to SWIM... can we do this in SWIM itself rather?
    func processGossipPayload(context: ActorContext<SWIM.Message>, payload: SWIM.Payload) {
        switch payload {
        case .membership(let members):
            for member in members {
                switch self.swim.onGossipPayload(about: member) {
                case .applied:
                    () // ok, nothing to do

                case .connect(let address, let continueAddingMember):
                    // ensuring a connection is asynchronous, but executes callback in actor context
                    self.ensureAssociated(context, remoteNode: address) { uniqueAddress in
                        // it COULD happen that we kick off connecting to a node based on this connection
                        // TODO: test for this
                        if let uniqueRemoteAddress = uniqueAddress {
                            continueAddingMember(uniqueRemoteAddress)
                            return
                        } else {
                            // was a local address... weird
                            continueAddingMember(context.system.cluster.node)
                            return
                        }
                    }

                case .ignored(let level, let message):
                    if let level = level, let message = message {
                        context.log.log(level: level, message)
                    }
                    return

                case .confirmedDead(let member):
                    context.log.info("Detected [DEAD] node. Information received: \(member).")
                    context.system.cluster.down(node: member.node.node)
                    return
                }
            }

        case .none:
            return // ok
        }
    }

    func ensureAssociated(_ context: ActorContext<SWIM.Message>, remoteNode: Node?, onceConnected: @escaping (UniqueNode?) -> Void) {
        // this is a local node, so we don't need to connect first
        guard let remoteNode = remoteNode else {
            onceConnected(nil)
            return
        }

        guard remoteNode != context.system.settings.cluster.node else {
            // TODO: handle old incarnations of self properly?
            onceConnected(nil)
            return
        }

        let handshakeTimeout = TimeAmount.seconds(3)
        // FIXME: use reasonable timeout and back off? issue #724
        let handshakeResultAnswer = context.system.cluster._shell.ask(for: ClusterShell.HandshakeResult.self, timeout: handshakeTimeout) {
            .command(.handshakeWith(remoteNode, replyTo: $0))
        }
        context.onResultAsync(of: handshakeResultAnswer, timeout: .effectivelyInfinite) { handshakeResultResult in
            switch handshakeResultResult {
            case .success(.success(let remoteUniqueAddress)):
                onceConnected(remoteUniqueAddress)
            case .success(.failure):
                context.log.warning("Failed to connect to remote node [\(remoteNode)]")
            case .failure:
                context.log.warning("Connecting to remote node [\(remoteNode)] timed out after [\(handshakeTimeout)]")
            }

            return .same
        }
    }

    /// This is effectively joining the SWIM membership of the other member.
    func sendFirstRemotePing(_ context: ActorContext<SWIM.Message>, on node: UniqueNode) {
        let remoteSwimAddress = SWIMShell.address(on: node)

        let resolveContext = ResolveContext<SWIM.Message>(address: remoteSwimAddress, system: context.system)
        let remoteSwimRef = context.system._resolve(context: resolveContext)

        // TODO: we are sending the ping here to initiate cluster membership. Once available this should do a state sync instead
        self.sendPing(context: context, to: remoteSwimRef, lastKnownStatus: .alive(incarnation: 0), pingReqOrigin: nil)
    }
}

extension SWIMShell {
    static let name: String = "swim" // TODO: String -> ActorName
    static let naming: ActorNaming = .unique(SWIMShell.name)

    static func address(on node: UniqueNode) -> ActorAddress {
        return try! ActorPath._system.appending(SWIMShell.name).makeRemoteAddress(on: node, incarnation: .perpetual)
    }

    static let periodicPingKey = TimerKey("swim/periodic-ping")
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Internal "trace-logging" for debugging purposes

internal enum TraceLogType: CustomStringConvertible {
    case reply(to: ActorRef<SWIM.Ack>)
    case receive(pinged: ActorRef<SWIM.Message>?)
    case ask(ActorRef<SWIM.Message>)

    static var receive: TraceLogType {
        return .receive(pinged: nil)
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
