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
internal struct SWIMMembershipShell {

    let swim: SWIM.Instance
    let observer: FailureObserver?

    var settings: SWIM.Settings {
        return self.swim.settings
    }

    internal init(_ swim: SWIM.Instance, observer: FailureObserver? = nil) {
        self.swim = swim
        self.observer = observer
    }
    internal init(settings: SWIM.Settings, observer: FailureObserver? = nil) {
        self.init(SWIM.Instance(settings), observer: observer)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Behaviors

    /// Initial behavior, kicks off timers and becomes `ready`.
    // FIXME: utilize FailureObserver
    var behavior: Behavior<SWIM.Message> {
        return .setup { context in

            let probeInterval = self.swim.settings.gossip.probeInterval
            context.timers.startPeriodic(key: SWIM.Shell.periodicPingKey, message: .local(.pingRandomMember), interval: probeInterval)

            self.swim.addMyself(context.myself)

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
            }
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Receiving messages

    func receiveRemoteMessage(context: ActorContext<SWIM.Message>, message: SWIM.RemoteMessage) {
        switch message {
        case .ping(let lastKnownStatus, let replyTo, let payload):
            self.tracelog(context, .receive, message: message)

            switch swim.onPing(lastKnownStatus: lastKnownStatus) {
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
                self.ensureConnected(context, remoteNode: target.address.node?.node) { _ in
                    self.swim.addMember(target, status: lastKnownStatus) // TODO push into SWIM?
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

        case .join(let node):
            self.handleJoin(context, node: node)

        case .getMembershipState(let replyTo): // TODO could it be a "testing" message?
            // NOT tracelogging it on purpose, it is a testing message
            replyTo.tell(SWIM.MembershipState(membershipStatus: swim._allMembersDict))
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Sending ping, ping-req and friends

    /// - parameter pingReqOrigin: is set only when the ping that this is a reply to was originated as a `pingReq`.
    func sendPing(
        context: ActorContext<SWIM.Message>,
        to target: ActorRef<SWIM.Message>,
        lastKnownStatus: SWIM.Status,
        pingReqOrigin: ActorRef<SWIM.Ack>?) {
        let payload = swim.makeGossipPayload()
        context.log.trace("Sending ping to [\(target)] with payload [\(payload)]")

        let response = target.ask(for: SWIM.Ack.self, timeout: swim.settings.failureDetector.pingTimeout) {
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

        // TODO also push much of this down into SWIM.Instance

        // select random members to send ping requests to
        let membersToPingRequest = self.swim.membersToPingRequest(target: toPing)

        guard !membersToPingRequest.isEmpty else {
            // no nodes available to ping, so we have to assume the node suspect right away
            if let lastIncarnation = lastKnownStatus.incarnation {
                context.log.info("No members to ping-req through, marking [\(toPing)] immediately as [.suspect].")
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
            let payload = swim.makeGossipPayload()

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
        pingReqOrigin: ActorRef<SWIM.Ack>?) {
        self.tracelog(context, .receive(pinged: pingedMember), message: result)

        switch result {
        case .failure(let err):
            if let timeoutError = err.extractUnderlying(as: TimeoutError.self) {
                context.log.warning("Did not receive ack from [\(pingedMember)] within [\(timeoutError.timeout.prettyDescription)]. Sending ping requests to other members.") // TODO: add timeout to log
            } else {
                context.log.warning("\(err) Did not receive ack from [\(pingedMember)] within configured timeout. Sending ping requests to other members.") // TODO: add timeout to log
            }
            // TODO: when adding lifeguard extensions, reply with .nack
            let originOfPingWasPingRequest = pingReqOrigin != nil
            if !originOfPingWasPingRequest {
                self.sendPingRequests(context: context, toPing: pingedMember)
            }
        case .success(let ack):
            context.log.trace("Received ack from [\(ack.pinged)] with incarnation [\(ack.incarnation)] and payload [\(ack.payload)]")
            self.swim.mark(ack.pinged, as: .alive(incarnation: ack.incarnation)) // TODO log ?
            pingReqOrigin?.tell(ack)
            self.processGossipPayload(context: context, payload: ack.payload)
        }
    }

    func handlePingRequestResult(context: ActorContext<SWIM.Message>, result: Result<SWIM.Ack, ExecutionError>, pingedMember: ActorRef<SWIM.Message>) {
        self.tracelog(context, .receive(pinged: pingedMember), message: result)
        // TODO do we know here WHO replied to us actually? We know who they told us about (with the ping-req), could be useful to know

        switch self.swim.onPingRequestResponse(result, pingedMember: pingedMember) {
        case .alive(_, let payloadToProcess):
            self.processGossipPayload(context: context, payload: payloadToProcess)
        case .newlySuspect:
            context.log.debug("Member [\(pingedMember)] marked as suspect")
        default:
            () // TODO revisit logging more details here
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
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

    func handleJoin(_ context: ActorContext<SWIM.Message>, node: Node) {
        self.ensureConnected(context, remoteNode: node) { uniqueNode in
            guard let uniqueNode = uniqueNode else {
                fatalError("This is guaranteed to run with an unique node address")
            }

            assert(uniqueNode.node == node, "We received a successful connection for other node than we asked to. This is a bug in the ClusterShell.")
            self.sendFirstRemotePing(context, on: uniqueNode)
        }
    }

    func checkSuspicionTimeouts(context: ActorContext<SWIM.Message>) {
        // TODO: push more of logic into SWIM instance, the calculating
        // FIXME: use decaying timeout as proposed in lifeguard paper
        let timeoutPeriods = (self.swim.protocolPeriod - self.swim.settings.failureDetector.suspicionTimeoutPeriodsMax)
        for member in self.swim.suspects where member.protocolPeriod <= timeoutPeriods {
            // We are diverging from teh SWIM paper here in that we store the `.dead` state, instead
            // of removing the node from the member list. We do that in order to prevent dead nodes
            // from being re-added to the cluster.
            // TODO: add time of death to the status
            switch self.swim.mark(member.ref, as: .dead) {
            case .applied:
                // TODO marking is more about "marking a node as dead" should we rather log addresses and not actor paths?
                context.log.warning("Marked [\(member)] as dead. Was marked suspect in protocol period [\(member.protocolPeriod)], current period [\(swim.protocolPeriod)].")
                // TODO: add tracelog about marking a node dead here?
            case .ignoredDueToOlderStatus:
                // TODO make sure a fatal error in SWIM.Shell causes a system shutdown?
                fatalError("Marking [\(member)] as dead failed! This should never happen, dead is the terminal status. SWIM instance: \(self.swim)")
            }
        }
    }

    // TODO since this is applying payload to SWIM... can we do this in SWIM itself rather?
    func processGossipPayload(context: ActorContext<SWIM.Message>, payload: SWIM.Payload) {
        switch payload {
        case .membership(let members):
            for member in members {
                switch self.swim.onGossipPayload(about: member) {
                case .applied:
                    ()
                case .connect(let address, let continueAddingMember):
                    // ensuring a connection is asynchronous, but executes callback in actor context
                    self.ensureConnected(context, remoteNode: address) { uniqueAddress in
                        // it COULD happen that we kick off connecting to a node based on this connection
                        // TODO test for this
                        if let uniqueRemoteAddress = uniqueAddress {
                            continueAddingMember(uniqueRemoteAddress)
                            return
                        } else {
                            // was a local address... weird
                            context.log.warning("Attempted to connect to local address....? nonsense!") // TODO fixme, not optional param here
                            return
                        }
                    }
                case .ignored(let warning):
                    if let warning = warning {
                        context.log.warning("Warning while processing SWIM membership gossip: \(warning)")
                    }
                    return

                case .selfDeterminedDead:
                    // TODO: handle shutdown differently?
                    context.system.shutdown()
                    return
                }
            }

        case .none:
            () // ok
        }
    }

    func ensureConnected(_ context: ActorContext<SWIM.Message>, remoteNode: Node?, onSuccess: @escaping (UniqueNode?) -> Void) {
        // this is a local node, so we don't need to connect first
        guard let remoteNode = remoteNode else {
            onSuccess(nil)
            return
        }

        // FIXME: use reasonable timeout, depends on https://github.com/apple/swift-distributed-actors/issues/724
        let handshakeResultAnswer = context.system.clusterShell.ask(for: ClusterShell.HandshakeResult.self, timeout: .seconds(3)) {
            .command(.handshakeWith(remoteNode, replyTo: $0))
        }
        context.onResultAsync(of: handshakeResultAnswer, timeout: .effectivelyInfinite) { handshakeResultResult in
            switch handshakeResultResult {
            case .success(.success(let remoteUniqueAddress)):
                onSuccess(remoteUniqueAddress)
            case .success(.failure):
                context.log.warning("Failed to connect to remote node [\(remoteNode)]")
            case .failure:
                context.log.warning("Connecting to remote node [\(remoteNode)] timed out")
            }

            return .same
        }
    }

    /// This is effectively joining the SWIM membership of the other member.
    func sendFirstRemotePing(_ context: ActorContext<SWIM.Message>, on node: UniqueNode) {
        let remoteSwimAddress = SWIMMembershipShell.address(on: node)

        pprint("String(reflecting: remoteSwimAddress) = \(String(reflecting: remoteSwimAddress))")

        let resolveContext = ResolveContext<SWIM.Message>(address: remoteSwimAddress, system: context.system)
        let remoteSwimRef = context.system._resolve(context: resolveContext)
        pprint("String(reflecting: remoteSwimRef) = \(String(reflecting: remoteSwimRef))")

        // TODO: we are sending the ping here to initiate cluster membership. Once available this should do a state sync instead
        self.sendPing(context: context, to: remoteSwimRef, lastKnownStatus: .alive(incarnation: 0), pingReqOrigin: nil)
    }
}

extension SWIMMembershipShell {
    static let name: String = "membership-swim" // TODO String -> ActorName

    static func address(on node: UniqueNode) -> ActorAddress {
        return try! ActorPath._system.appending(SWIMMembershipShell.name).makeRemoteAddress(on: node, incarnation: .perpetual)
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

extension SWIMMembershipShell {
    /// Optional "dump all messages" logging.
    /// Enabled by `SWIM.Settings.traceLogLevel`
    func tracelog(_ context: ActorContext<SWIM.Message>, _ type: TraceLogType, message: Any,
                  file: String = #file, function: String = #function, line: UInt = #line) {
        if let level = self.settings.traceLogLevel {
            context.log.log(
                level: level,
                "[tracelog:SWIM] \(type.description): \(message)",
                metadata: self.swim.metadata,
                file: file, function: function, line: line
            )
        }
    }

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
                return "RECV(pinged:\(pinged.path))"
            case .reply(let to):
                return "REPL(to:\(to.path))"
            case .ask(let who):
                return "ASK(\(who.path))"
            }
        }
    }

}
