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

/// TODO ...
internal enum SWIMMembershipShell {

    static let name: String = "membership-swim" // TODO String -> ActorName
    static let periodicPingKey = "periodic-ping"

    fileprivate struct Gossip: Equatable {
        let member: SWIM.Member
        var numberOfTimesGossiped: Int
    }

    final class State {
        struct MembershipInfo {
            let status: SWIM.Status
            // in which protocol period was this state set
            let protocolPeriod: Int

            var isAlive: Bool {
                return self.status.isAlive
            }

            var isSuspect: Bool {
                return self.status.isSuspect
            }

            var isDead: Bool {
                return self.status.isDead
            }
        }

        private var membershipInfos: [ActorRef<SWIM.Message>: MembershipInfo] = [:]
        private var membersToPing: [ActorRef<SWIM.Message>] = []
        // The incarnation number is used to get a sense of ordering of events, so if an `.alive` or `.suspect`
        // state with a lower incarnation than the one currently known by a node is received, it can be dropped
        // as outdated and we don't accidentally override state with older events. The incarnation can only
        // be incremented by the respective node itself and will happen if that node receives a `.suspect` for
        // itself, to which it will respond with an `.alive` with the incremented incarnation.
        private var _incarnation: SWIM.Incarnation = 0

        // The protocol period represents the number of times we have pinged a random member
        // of the cluster. At the end of every ping cycle, the number will be incremented.
        // Suspicion timeouts are based on the protocol period, e.g. if the ping interval
        // is 300ms and the suspicion timeout is set to 10 periods, a suspected node will
        // be declared `.dead` after not receiving an `.alive` for approx. 3 seconds.
        private var _protocolPeriod: Int = 0

        // We need to store the path to the owning SWIMMembershipShell to avoid adding it
        // to the `membersToPing` list
        private let localShellPath: UniqueActorPath

        private var _messagesToGossip = Heap(of: Gossip.self, comparator: {
            $0.numberOfTimesGossiped < $1.numberOfTimesGossiped
        })

        let settings: SWIM.Settings

        init(localShellPath: UniqueActorPath, settings: SWIM.Settings) {
            self.localShellPath = localShellPath
            self.settings = settings
        }

        func addMember(_ member: ActorRef<SWIM.Message>, status: SWIM.Status) {
            if let previousStatus = self.membershipStatus(of: member), previousStatus.supersedes(status) {
                // we already have a newer state for this member
                return
            }

            if self.membershipInfos[member] == nil && member.path != self.localShellPath {
                // Newly added members are inserted at a random spot in the list of members
                // to ping, to have a better distribution of messages to this node from all
                // other nodes. If for example all nodes would add it to the end of the list,
                // it would take a longer time until it would be pinged for the first time
                // and also likely receive multiple pings within a very short time frame.
                self.membersToPing.insert(member, at: Int.random(in: 0...self.membersToPing.endIndex))
            }

            self.membershipInfos[member] = MembershipInfo(status: status, protocolPeriod: self.protocolPeriod)
            self.addGossip(membership: SWIM.Member(ref: member, status: status))
        }

        func nextMemberToPing() -> ActorRef<SWIM.Message>? {
            if self.membershipInfos.isEmpty {
                return nil
            }

            if self.membersToPing.isEmpty {
                // This is a slight divergence from the original SWIM paper in that we
                // are using a round-robin on a pre-shuffled list of members, instead
                // of chosing a random member of the full membership list each time.
                // This mechanism is proposed in the SWIM paper itself and should reduce
                // the time until state is spread across the whole cluster, by guaranteeing
                // that each node will be gossiped to within N cycles (where N is the
                // cluster size).
                self.membersToPing = self.membershipInfos.filter { $0.key.path != self.localShellPath && !$0.value.isDead }.keys.shuffled()
            }

            if self.membersToPing.isEmpty {
                return nil
            }

            return self.membersToPing.removeFirst()
        }

        enum MarkResult {
            case ignoredDueToOlderStatus(currentStatus: SWIM.Status)
            case applied(previousStatus: SWIM.Status?)
        }

        func mark(_ member: ActorRef<SWIM.Message>, as status: SWIM.Status) -> MarkResult {
            let previousStatusOption = self.membershipStatus(of: member)
            if let previousStatus = previousStatusOption, previousStatus.supersedes(status) {
                // we already have a newer status for this member
                return .ignoredDueToOlderStatus(currentStatus: previousStatus)
            }

            self.membershipInfos[member] = MembershipInfo(status: status, protocolPeriod: self.protocolPeriod)
            self.addGossip(membership: SWIM.Member(ref: member, status: status))

            return .applied(previousStatus: previousStatusOption)
        }

        func incrementIncarnation() {
            self._incarnation += 1
        }

        var incarnation: SWIM.Incarnation {
            return self._incarnation
        }

        func incrementProtocolPeriod() {
            self._protocolPeriod += 1
        }

        var protocolPeriod: Int {
            return self._protocolPeriod
        }

        func membershipStatus(of member: ActorRef<SWIM.Message>) -> SWIM.Status? {
            return self.membershipInfos[member]?.status
        }

        func membershipInfo(for member: ActorRef<SWIM.Message>) -> MembershipInfo? {
            return self.membershipInfos[member]
        }

        var memberCount: Int {
            return self.membershipInfos.count
        }

        var members: [ActorRef<SWIM.Message>] {
            return [ActorRef<SWIM.Message>](self.membershipInfos.keys)
        }

        var membershipStatus: [ActorRef<SWIM.Message>: SWIM.Status] {
            return self.membershipInfos.mapValues { $0.status }
        }

        var suspects: [ActorRef<SWIM.Message>: MembershipInfo] {
            return self.membershipInfos.filter { _, info in info.isSuspect }
        }

        func isMember(_ member: ActorRef<SWIM.Message>) -> Bool {
            return self.membershipInfos[member] != nil
        }

        func makeGossipPayload() -> SWIM.Payload {
            // In order to avoid duplicates within a single gossip payload, we
            // first collect all messages we need to gossip out and only then
            // re-insert them into `messagesToGossip`. Otherwise, we may end up
            // selecting the same message multiple times, if e.g. the total number
            // of messages is smaller than the maximum gossip size, or for newer
            // messages that have a lower `numberOfTimesGossiped` counter than
            // the other messages.
            guard self._messagesToGossip.count > 0 else {
                return .none
            }

            var gossips: [Gossip] = []
            while gossips.count < self.settings.gossip.maxNumberOfMessages, let gossip = self._messagesToGossip.removeRoot() {
                gossips.append(gossip)
            }

            var messages: [SWIM.Member] = []
            messages.reserveCapacity(gossips.count)

            for var gossip in gossips {
                messages.append(gossip.member)
                gossip.numberOfTimesGossiped += 1
                if gossip.numberOfTimesGossiped < self.settings.gossip.maxGossipCountPerMessage {
                    self._messagesToGossip.append(gossip)
                }
            }

            return .membership(messages)
        }

        func randomMembersToRequestPing(target: ActorRef<SWIM.Message>) -> ArraySlice<ActorRef<SWIM.Message>> {
            return self.members.shuffled()
                .filter { $0.path != self.localShellPath && $0 != target }
                .prefix(self.settings.failureDetector.indirectProbeCount)
        }


        private func addGossip(membership: SWIM.Member) {
            // we need to remove old state before we add the new gossip, so we don't gossip out stale state
            self._messagesToGossip.remove(where: { $0.member.ref == membership.ref })
            self._messagesToGossip.append(.init(member: membership, numberOfTimesGossiped: 0))
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Behaviors

    // FIXME: utilize FailureObserver
    static func behavior(settings: SWIM.Settings, observer: FailureObserver? = nil) -> Behavior<SWIM.Message> {
        return .setup { context in

            let state = State(localShellPath: context.path, settings: settings)
            context.timers.startPeriodicTimer(key: periodicPingKey, message: .local(.pingRandomMember), interval: settings.gossip.probeInterval)

            state.addMember(context.myself, status: .alive(incarnation: 0))

            return ready(state: state)
        }
    }

    static func ready(state: State) -> Behavior<SWIM.Message> {
        return .receive { context, wrappedMessage in
            switch wrappedMessage {
            case .remote(let message):
                handleRemoteMessage(context: context, message: message, state: state)
            case .local(let message):
                handleLocalMessage(context: context, message: message, state: state)
            }

            return .same
        }
    }

    static func handleRemoteMessage(context: ActorContext<SWIM.Message>, message: SWIM.Remote, state: State) {
        switch message {
        case .ping(let lastKnownStatus, let replyTo, let payload):
            // if a node suspects us in the current incarnation, we need to increment
            // the incarnation, so the new `alive`status can properly propagate through
            // the cluster
            if case .suspect(let incarnation) = lastKnownStatus, incarnation == state.incarnation {
                state.incrementIncarnation()
            }

            context.log.trace("Received ping from [\(replyTo)] with payload [\(payload)]")
            replyTo.tell(.init(from: context.myself, incarnation: state.incarnation, payload: state.makeGossipPayload()))
            processGossip(context: context, payload: payload, state: state)

        case .pingReq(let target, let lastKnownStatus, let replyTo, let payload):
            context.log.trace("Received request to ping [\(target)] from [\(replyTo)] with payload [\(payload)]")
            if !state.isMember(target) {
                ensureConnected(context: context, remoteAddress: target.path.address?.address, state: state) {
                    state.addMember(target, status: lastKnownStatus)
                    sendPing(context: context, to: target, lastKnownStatus: lastKnownStatus, replyTo: replyTo, state: state)
                }
            } else {
                sendPing(context: context, to: target, lastKnownStatus: lastKnownStatus, replyTo: replyTo, state: state)
            }
            processGossip(context: context, payload: payload, state: state)

        case .getMembershipState(let replyTo):
            replyTo.tell(SWIM.MembershipState(membershipStatus: state.membershipStatus))
        }
    }


    static func handleLocalMessage(context: ActorContext<SWIM.Message>, message: SWIM.Local, state: State) {
        switch message {
        case .pingRandomMember:
            context.log.trace("Received periodic trigger to ping random member [protocolPeriod=\(state.protocolPeriod)]")

            // needs to be done first, so we can gossip out the most up to date state
            checkSuspicionTimeouts(context: context, state: state)

            if let toPing = state.nextMemberToPing(), let lastKnownStatus = state.membershipStatus(of: toPing) {
                sendPing(context: context, to: toPing, lastKnownStatus: lastKnownStatus, replyTo: nil, state: state)
            }
            state.incrementProtocolPeriod()
        }
    }

    static func sendPing(
        context: ActorContext<SWIM.Message>,
        to: ActorRef<SWIM.Message>,
        lastKnownStatus: SWIM.Status,
        replyTo: ActorRef<SWIM.Ack>?,
        state: State) {
        let payload = state.makeGossipPayload()
        context.log.trace("Sending ping to [\(to)] with payload [\(payload)]")

        let response = to.ask(for: SWIM.Ack.self, timeout: state.settings.failureDetector.pingTimeout) {
            SWIM.Message.remote(.ping(lastKnownStatus: lastKnownStatus, replyTo: $0, payload: payload))
        }

        // timeout is already handled by the ask, so we can set it to infinite here to not have two timeouts
        context.onResultAsync(of: response, timeout: .effectivelyInfinite) {
            handlePingResponse(context: context, result: $0, pingedMember: to, replyTo: replyTo, state: state)
            return .same
        }
    }

    static func sendPingRequests(context: ActorContext<SWIM.Message>, toPing: ActorRef<SWIM.Message>, state: State) {
        guard let lastKnownStatus = state.membershipStatus(of: toPing) else {
            context.log.trace("Skipping ping requests after failed ping to [\(toPing)] because node has been removed from member list")
            return
        }

        // select random members to send ping requests to
        let membersToRequest = state.randomMembersToRequestPing(target: toPing)

        guard !membersToRequest.isEmpty else {
            // there are no nodes available to send a ping request to, so we mark
            // `toPing` suspicious immediately
            if let currentState = state.membershipStatus(of: toPing) {
                markSuspect(context: context, member: toPing, lastKnownState: currentState, state: state)
            }
            return
        }

        // We are only interested in successful pings, as a single success tells us the node is
        // still alive. Therefore we propogate only the first success, but no failures.
        // The failure case is handled through the timeout of the whole operation.
        let firstSuccess = context.system.eventLoopGroup.next().makePromise(of: SWIM.Ack.self)
        for ref in membersToRequest {
            let payload = state.makeGossipPayload()

            context.log.trace("Sending ping request for [\(toPing)] to [\(ref)] with payload: \(payload)")
            ref.ask(for: SWIM.Ack.self, timeout: state.settings.failureDetector.pingTimeout) {
                SWIM.Message.remote(.pingReq(target: toPing, lastKnownStatus: lastKnownStatus, replyTo: $0, payload: state.makeGossipPayload()))
            }.nioFuture.cascadeSuccess(to: firstSuccess)
        }

        context.onResultAsync(of: firstSuccess.futureResult, timeout: state.settings.failureDetector.pingTimeout) {
            handlePingRequestResponse(context: context, result: $0, pingedMember: toPing, state: state)
            return .same
        }
    }

    static func handlePingResponse(
        context: ActorContext<SWIM.Message>,
        result: Result<SWIM.Ack, ExecutionError>,
        pingedMember: ActorRef<SWIM.Message>,
        replyTo: ActorRef<SWIM.Ack>?,
        state: State) {
        switch result {
        case .failure:
            // TODO: when adding lifeguard extensions, reply with .nack
            context.log.warning("Did not receive ack from [\(pingedMember)] within configured timeout. Sending ping requests to other members.") // TODO: add timeout to log
            if replyTo == nil {
                sendPingRequests(context: context, toPing: pingedMember, state: state)
            }
        case .success(let ack):
            // FIXME: process payload
            context.log.trace("Received ack from [\(ack.from)] with incarnation [\(ack.incarnation)] and payload [\(ack.payload)]")
            markMember(ack.from, as: .alive(incarnation: ack.incarnation), state: state, log: context.log)
            replyTo?.tell(ack)
            processGossip(context: context, payload: ack.payload, state: state)
        }
    }

    static func handlePingRequestResponse(
        context: ActorContext<SWIM.Message>,
        result: Result<SWIM.Ack, ExecutionError>,
        pingedMember: ActorRef<SWIM.Message>,
        state: State) {
        switch result {
        case .failure:
            guard let lastKnownState = state.membershipStatus(of: pingedMember) else {
                context.log.trace("Ignoring timed out ping request, because member [\(pingedMember)] has been removed from the member list in the meantime")
                return
            }

            markSuspect(context: context, member: pingedMember, lastKnownState: lastKnownState, state: state)

        case .success(let ack):
            // FIXME: process payload
            processGossip(context: context, payload: ack.payload, state: state)
            markMember(ack.from, as: .alive(incarnation: ack.incarnation), state: state, log: context.log)
        }
    }

    static func checkSuspicionTimeouts(context: ActorContext<SWIM.Message>, state: State) {
        // FIXME: use decaying timeout as propsed in lifeguard paper
        let timeout = (state.protocolPeriod - state.settings.failureDetector.suspicionTimeoutMax)
        for (member, membershipInfo) in state.suspects where membershipInfo.protocolPeriod <= timeout {
            // We are diverging from teh SWIM paper here in that we store the `.dead` state, instead
            // of removing the node from the member list. We do that in order to preevent dead nodes
            // from being re-added to the cluster.
            // TODO: add time of death to the status
            context.log.warning("Marking \(member) as dead. Was marked suspect in protocol period [\(membershipInfo.protocolPeriod)], current period [\(state.protocolPeriod)].")
            markMember(member, as: .dead, state: state, log: context.log)
        }
    }

    static func processGossip(
        context: ActorContext<SWIM.Message>,
        payload: SWIM.Payload,
        state: State) {
        guard case .membership(let members) = payload else {
            return
        }

        for members in members {
            if state.isMember(members.ref) {
                markMember(members.ref, as: members.status, state: state, log: context.log)
            } else {
                ensureConnected(context: context, remoteAddress: members.ref.path.address?.address, state: state) {
                    state.addMember(members.ref, status: members.status)
                }
            }
        }
    }

    static func ensureConnected(context: ActorContext<SWIM.Message>, remoteAddress address: NodeAddress?, state: State, onSuccess: @escaping () -> Void) {
        // this is a local node, so we don't need to connect first
        guard let remoteAddress = address else {
            onSuccess()
            return
        }
        // FIXME: use reasonable timeout, depends on https://github.com/apple/swift-distributed-actors/issues/724
        let result = context.system.clusterShell.ask(for: ClusterShell.HandshakeResult.self, timeout: .seconds(1)) {
            .command(.handshakeWith(remoteAddress, replyTo: $0))
        }
        context.onResultAsync(of: result, timeout: .effectivelyInfinite) {
            switch $0 {
            case .success(.success):
                onSuccess()
            default:
                context.log.warning("Failed to connect to remote node [\(remoteAddress)]")
            }
            return .same
        }
    }

    // To mark a member as `.suspect`, consider using `markSuspect` instead,
    // which extracts the incarnation number from the last known status
    static func markMember(_ member: ActorRef<SWIM.Message>, as status: SWIM.Status, state: State, log: Logger) {
        switch state.mark(member, as: status) {
        case .applied(let previousStatus):
            let previousStatusString = previousStatus.map { "\($0)" } ?? "unknown"
            log.trace("Marked member [\(member)] as [\(status)], from previous status [\(previousStatusString)]")
        case .ignoredDueToOlderStatus(let currentStatus):
            log.trace("Did not apply status update [\(status)] for member [\(member)] because newer status [\(currentStatus)] is already known")
        }
    }

    // convenience function to mark a member as suspect using the last known incarnation
    static func markSuspect(
        context: ActorContext<SWIM.Message>,
        member: ActorRef<SWIM.Message>,
        lastKnownState: SWIM.Status,
        state: State) {
        switch lastKnownState {
        case .alive(let incarnation):
            context.log.warning("Marking [\(member)] as suspect")
            markMember(member, as: .suspect(incarnation: incarnation), state: state, log: context.log)
        case .suspect:
            () // already suspect, nothing to be done
        case .dead:
            context.log.trace("Not marking [\(member)] as suspect, because it has been marked as dead already")
        }
    }
}

extension SWIM {
    typealias MembershipShell = SWIMMembershipShell
}
