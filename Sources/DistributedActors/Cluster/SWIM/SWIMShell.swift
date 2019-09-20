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
                self.ensureAssociated(context, remoteNode: target.address.node) { result in
                    switch result {
                    case .success(let remoteAddress):
                        self.swim.addMember(target, status: lastKnownStatus) // TODO: push into SWIM?
                        self.sendPing(context: context, to: target, lastKnownStatus: lastKnownStatus, pingReqOrigin: replyTo)
                    case .failure(let error):
                        context.log.warning("Unable to obtain association for remote \(target.address)... Maybe it was tombstoned?")
                    }
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
        result: Result<SWIM.Ack, Error>,
        pingedMember: ActorRef<SWIM.Message>,
        pingReqOrigin: ActorRef<SWIM.Ack>?
    ) {
        self.tracelog(context, .receive(pinged: pingedMember), message: result)

        switch result {
        case .failure(let err):
            if let timeoutError = err as? TimeoutError {
                context.log.warning("Did not receive ack from \(reflecting: pingedMember.address) within [\(timeoutError.timeout.prettyDescription)]. Sending ping requests to other members.")
            } else {
                context.log.warning("\(err) Did not receive ack from \(reflecting: pingedMember.address) within configured timeout. Sending ping requests to other members.")
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

    func handlePingRequestResult(context: ActorContext<SWIM.Message>, result: Result<SWIM.Ack, Error>, pingedMember: ActorRef<SWIM.Message>) {
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
        context.log.trace("\(context.name): Received periodic trigger to ping random member", metadata: self.swim.metadata)

        // needs to be done first, so we can gossip out the most up to date state
        self.checkSuspicionTimeouts(context: context)

        if let toPing = swim.nextMemberToPing() {
            if let lastKnownStatus = swim.status(of: toPing) {
                self.sendPing(context: context, to: toPing, lastKnownStatus: lastKnownStatus, pingReqOrigin: nil)
            }
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

            context.log.debug("Confirming .dead member \(reflecting: member.node)")

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
            case .applied(nil):
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

                case .connect(let node, let continueAddingMember):
                    // ensuring a connection is asynchronous, but executes callback in actor context
                    self.ensureAssociated(context, remoteNode: node) { uniqueAddressResult in
                        switch uniqueAddressResult {
                        case .success(let uniqueAddress):
                            continueAddingMember(uniqueAddress)
                        case .failure(let error):
                            context.log.warning("Unable ensure association with \(node), could it have been tombstoned? Error: \(error)")
                        }
                    }

                case .ignored(let level, let message):
                    if let level = level, let message = message {
                        context.log.log(level: level, message)
                    }

                case .confirmedDead(let member):
                    context.log.info("Detected [.dead] node. Information received: \(member).")
                    context.system.cluster.down(node: member.node.node)
                }
            }

        case .none:
            return // ok
        }
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

        let associationState = clusterShell.associationRemoteControl(with: remoteNode)
        switch associationState {
        case .unknown:
            // This may mean that we noticed an actor on a not yet associated node in the SWIM gossip,
            // and need to ensure we connect to that node in order to be able to monitor it; thus we need to kick off a handshake with that node.
            //
            // Note that we DO know the remote's `UniqueNode`, putting us in the interesting position that we know exactly which incarnation of a
            // node we intend to talk to -- unlike a plain "join node" command.
            () // continue
        case .associated(let control):
            continueWithAssociation(.success(control.remoteNode))
        case .tombstone:
            context.log.info("TOMBSTONE: \(remoteNode)")
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

extension ActorAddress {
    internal static func _swim(on node: UniqueNode) -> ActorAddress {
        return .init(node: node, path: ActorPath._swim, incarnation: .perpetual)
    }
}

extension ActorPath {
    internal static let _swim: ActorPath = try! ActorPath._system.appending("swim")
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
