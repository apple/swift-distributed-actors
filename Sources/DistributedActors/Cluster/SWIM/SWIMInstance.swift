////===----------------------------------------------------------------------===//
////
//// This source file is part of the Swift Distributed Actors open source project
////
//// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
//// Licensed under Apache License v2.0
////
//// See LICENSE.txt for license information
//// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
////
//// SPDX-License-Identifier: Apache-2.0
////
////===----------------------------------------------------------------------===//
//
//import Foundation // for natural logarithm
//import Logging
//
///// # SWIM (Scalable Weakly-consistent Infection-style Process Group Membership Protocol).
/////
///// Implementation of the SWIM protocol in abstract terms, see [SWIMShell] for the actor acting upon directives issued by this instance.
/////
///// > As you swim lazily through the milieu,
///// > The secrets of the world will infect you.
/////
///// ### Modifications
///// - Random, stable order members to ping selection: Unlike the completely random selection in the original paper.
/////
///// See the reference documentation of this swim implementation in the reference documentation.
/////
///// ### Related Papers
///// - SeeAlso: [SWIM: Scalable Weakly-consistent Infection-style Process Group Membership Protocol](https://www.cs.cornell.edu/projects/Quicksilver/public_pdfs/SWIM.pdf)
///// - SeeAlso: [Lifeguard: Local Health Awareness for More Accurate Failure Detection](https://arxiv.org/abs/1707.00788)
//
//final class SWIMInstance {
//    let settings: SWIM.Settings
//
//    /// Main members storage, map to values to obtain current members.
//    internal var members: [ActorRef<SWIM.Message>: SWIMMember]
//
//    /// List of members maintained in random yet stable order, see `addMember` for details.
//    internal var membersToPing: [SWIMMember]
//    /// Constantly mutated by `nextMemberToPing` in an effort to keep the order in which we ping nodes evenly distributed.
//    private var _membersToPingIndex: Int = 0
//    private var membersToPingIndex: Int {
//        self._membersToPingIndex
//    }
//
//    private var timeSourceNanos: () -> Int64 {
//        self.settings.lifeguard.timeSourceNanos
//    }
//
//    /// Lifeguard IV.A. Local Health Multiplier (LHM)
//    /// > These different sources of feedback are combined in a Local Health Multiplier (LHM).
//    /// > LHM is a saturating counter, with a max value S and min value zero, meaning it will not
//    /// > increase above S or decrease below zero.
//    ///
//    /// Local health multiplier is designed to relax the probeInterval and pingTimeout.
//    /// The multiplier will be increased in a following cases:
//    /// - When local node needs to refute a suspicion about itself
//    /// - When ping-req is missing nack
//    /// - When probe is failed
//    ///  Each of the above may indicate that local instance is not processing incoming messages in timely order.
//    /// The multiplier will be decreased when:
//    /// - Ping succeeded with an ack.
//    /// Events which cause the specified changes to the LHM counter are defined as `SWIM.LHModifierEvent`
//    var localHealthMultiplier = 0
//
//    var dynamicLHMProtocolInterval: TimeAmount {
//        TimeAmount.nanoseconds(self.settings.probeInterval.nanoseconds * Int64(1 + self.localHealthMultiplier))
//    }
//
//    var dynamicLHMPingTimeout: TimeAmount {
//        TimeAmount.nanoseconds(self.settings.pingTimeout.nanoseconds * Int64(1 + self.localHealthMultiplier))
//    }
//
//    /// The incarnation number is used to get a sense of ordering of events, so if an `.alive` or `.suspect`
//    /// state with a lower incarnation than the one currently known by a node is received, it can be dropped
//    /// as outdated and we don't accidentally override state with older events. The incarnation can only
//    /// be incremented by the respective node itself and will happen if that node receives a `.suspect` for
//    /// itself, to which it will respond with an `.alive` with the incremented incarnation.
//    var incarnation: SWIM.Incarnation {
//        self._incarnation
//    }
//
//    func makeSuspicion(incarnation: SWIM.Incarnation) -> SWIM.Status {
//        .suspect(incarnation: incarnation, suspectedBy: [self.myNode])
//    }
//
//    func mergeSuspicions(suspectedBy: Set<UniqueNode>, previouslySuspectedBy: Set<UniqueNode>) -> Set<UniqueNode> {
//        var newSuspectedBy = previouslySuspectedBy
//        for suspectedBy in suspectedBy.sorted() where newSuspectedBy.count < self.settings.lifeguard.maxIndependentSuspicions {
//            newSuspectedBy.update(with: suspectedBy)
//        }
//        return newSuspectedBy
//    }
//
//    func adjustLHMultiplier(_ event: LHModifierEvent) {
//        switch event {
//        case .successfulProbe:
//            if self.localHealthMultiplier > 0 {
//                self.localHealthMultiplier -= 1
//            }
//        case .failedProbe, .refutingSuspectMessageAboutSelf, .probeWithMissedNack:
//            if self.localHealthMultiplier < self.settings.lifeguard.maxLocalHealthMultiplier {
//                self.localHealthMultiplier += 1
//            }
//        }
//    }
//
//    private var _incarnation: SWIM.Incarnation = 0
//
//    // The protocol period represents the number of times we have pinged a random member
//    // of the cluster. At the end of every ping cycle, the number will be incremented.
//    // Suspicion timeouts are based on the protocol period, i.e. if a probe did not
//    // reply within any of the `suspicionTimeoutPeriodsMax` rounds, it would be marked as `.suspect`.
//    private var _protocolPeriod: Int = 0
//
//    // We store the owning SWIMShell ref in order avoid adding it to the `membersToPing` list
//    private let myShellMyself: ActorRef<SWIM.Message>
//    private var myShellAddress: ActorAddress {
//        self.myShellMyself.address
//    }
//
//    private let myNode: UniqueNode
//
//    private var _messagesToGossip = Heap(
//        of: SWIM.Gossip.self,
//        comparator: {
//            $0.numberOfTimesGossiped < $1.numberOfTimesGossiped
//        }
//    )
//
//    init(_ settings: SWIM.Settings, myShellMyself: ActorRef<SWIM.Message>, myNode: UniqueNode) {
//        self.settings = settings
//        self.myNode = myNode
//        self.myShellMyself = myShellMyself
//        self.members = [:]
//        self.membersToPing = []
//        self.addMember(myShellMyself, status: .alive(incarnation: 0))
//    }
//
//    @discardableResult
//    func addMember(_ ref: ActorRef<SWIM.Message>, status: SWIM.Status) -> AddMemberDirective {
//        let maybeExistingMember = self.member(for: ref)
//        if let existingMember = maybeExistingMember, existingMember.status.supersedes(status) {
//            // we already have a newer state for this member
//            return .newerMemberAlreadyPresent(existingMember)
//        }
//
//        let member = SWIMMember(ref: ref, status: status, protocolPeriod: self.protocolPeriod, suspicionStartedAt: self.timeSourceNanos())
//        self.members[ref] = member
//
//        if maybeExistingMember == nil, self.notMyself(member) {
//            // Newly added members are inserted at a random spot in the list of members
//            // to ping, to have a better distribution of messages to this node from all
//            // other nodes. If for example all nodes would add it to the end of the list,
//            // it would take a longer time until it would be pinged for the first time
//            // and also likely receive multiple pings within a very short time frame.
//            let insertIndex = Int.random(in: self.membersToPing.startIndex ... self.membersToPing.endIndex)
//            self.membersToPing.insert(member, at: insertIndex)
//            if insertIndex <= self.membersToPingIndex {
//                // If we inserted the new member before the current `membersToPingIndex`,
//                // we need to advance the index to avoid pinging the same member multiple
//                // times in a row. This is especially critical when inserting a larger
//                // number of members, e.g. when the cluster is just being formed, or
//                // on a rolling restart.
//                self.advanceMembersToPingIndex()
//            }
//        }
//
//        self.addToGossip(member: member)
//
//        return .added(member)
//    }
//
//    enum AddMemberDirective {
//        case added(SWIM.Member)
//        case newerMemberAlreadyPresent(SWIM.Member)
//    }
//
//    /// Implements the round-robin yet shuffled member to probe selection as proposed in the SWIM paper.
//    ///
//    /// This mechanism should reduce the time until state is spread across the whole cluster,
//    /// by guaranteeing that each node will be gossiped to within N cycles (where N is the cluster size).
//    ///
//    /// - Note:
//    ///   SWIM 4.3: [...] The failure detection protocol at member works by maintaining a list (intuitively, an array) of the known
//    ///   elements of the current membership list, and select-ing ping targets not randomly from this list,
//    ///   but in a round-robin fashion. Instead, a newly joining member is inserted in the membership list at
//    ///   a position that is chosen uniformly at random. On completing a traversal of the entire list,
//    ///   rearranges the membership list to a random reordering.
//    func nextMemberToPing() -> ActorRef<SWIM.Message>? {
//        if self.membersToPing.isEmpty {
//            return nil
//        }
//
//        defer { self.advanceMembersToPingIndex() }
//        return self.membersToPing[self.membersToPingIndex].ref
//    }
//
//    /// Selects `settings.indirectProbeCount` members to send a `ping-req` to.
//    func membersToPingRequest(target: ActorRef<SWIM.Message>) -> ArraySlice<SWIM.Member> {
//        func notTarget(_ ref: ActorRef<SWIM.Message>) -> Bool {
//            ref.address != target.address
//        }
//        func isReachable(_ status: SWIM.Status) -> Bool {
//            status.isAlive || status.isSuspect
//        }
//        let candidates = self.members
//            .values
//            .filter { notTarget($0.ref) && notMyself($0.ref) && isReachable($0.status) }
//            .shuffled()
//
//        return candidates.prefix(self.settings.indirectProbeCount)
//    }
//
//    func notMyself(_ member: SWIM.Member) -> Bool {
//        self.notMyself(member.ref)
//    }
//
//    func notMyself(_ ref: ActorRef<SWIM.Message>) -> Bool {
//        self.notMyself(ref.address)
//    }
//
//    func notMyself(_ memberAddress: ActorAddress) -> Bool {
//        !self.isMyself(memberAddress)
//    }
//
//    func isMyself(_ member: SWIM.Member) -> Bool {
//        self.isMyself(member.ref.address)
//    }
//
//    func isMyself(_ memberAddress: ActorAddress) -> Bool {
//        self.myShellAddress == memberAddress
//    }
//
//    @discardableResult
//    func mark(_ ref: ActorRef<SWIM.Message>, as status: SWIM.Status) -> MarkedDirective {
//        let previousStatusOption = self.status(of: ref)
//
//        var status = status
//        var protocolPeriod = self.protocolPeriod
//        var suspicionStartedAt: Int64?
//        if case .suspect(let incomingIncarnation, let incomingSuspectedBy) = status,
//            case .suspect(let previousIncarnation, let previousSuspectedBy)? = previousStatusOption,
//            let member = self.member(for: ref),
//            incomingIncarnation == previousIncarnation {
//            let suspicions = self.mergeSuspicions(suspectedBy: incomingSuspectedBy, previouslySuspectedBy: previousSuspectedBy)
//            status = .suspect(incarnation: incomingIncarnation, suspectedBy: suspicions)
//            // we should keep old protocol period when member is already a suspect
//            protocolPeriod = member.protocolPeriod
//            suspicionStartedAt = member.suspicionStartedAt
//        } else if case .suspect = status {
//            suspicionStartedAt = self.timeSourceNanos()
//        }
//
//        if let previousStatus = previousStatusOption, previousStatus.supersedes(status) {
//            // we already have a newer status for this member
//            return .ignoredDueToOlderStatus(currentStatus: previousStatus)
//        }
//
//        let member = SWIM.Member(ref: ref, status: status, protocolPeriod: protocolPeriod, suspicionStartedAt: suspicionStartedAt)
//        self.members[ref] = member
//        self.addToGossip(member: member)
//
//        if status.isDead {
//            self.removeFromMembersToPing(member)
//        }
//
//        return .applied(previousStatus: previousStatusOption, currentStatus: status)
//    }
//
//    enum MarkedDirective: Equatable {
//        case ignoredDueToOlderStatus(currentStatus: SWIM.Status)
//        case applied(previousStatus: SWIM.Status?, currentStatus: SWIM.Status)
//    }
//
//    func incrementProtocolPeriod() {
//        self._protocolPeriod += 1
//    }
//
//    func advanceMembersToPingIndex() {
//        self._membersToPingIndex = (self._membersToPingIndex + 1) % self.membersToPing.count
//    }
//
//    func removeFromMembersToPing(_ member: SWIM.Member) {
//        if let index = self.membersToPing.firstIndex(where: { $0.ref == member.ref }) {
//            self.membersToPing.remove(at: index)
//            if index < self.membersToPingIndex {
//                self._membersToPingIndex -= 1
//            }
//
//            if self.membersToPingIndex >= self.membersToPing.count {
//                self._membersToPingIndex = self.membersToPing.startIndex
//            }
//        }
//    }
//
//    var protocolPeriod: Int {
//        self._protocolPeriod
//    }
//
//    /// Debug only. Actual suspicion timeout depends on number of suspicions and calculated in `suspicionTimeout`
//    /// This will only show current estimate of how many intervals should pass before suspicion is reached. May change when more data is coming
//    var timeoutSuspectsBeforePeriodMax: Int64 {
//        self.settings.lifeguard.suspicionTimeoutMax.nanoseconds / self.dynamicLHMProtocolInterval.nanoseconds + 1
//    }
//
//    /// Debug only. Actual suspicion timeout depends on number of suspicions and calculated in `suspicionTimeout`
//    /// This will only show current estimate of how many intervals should pass before suspicion is reached. May change when more data is coming
//    var timeoutSuspectsBeforePeriodMin: Int64 {
//        self.settings.lifeguard.suspicionTimeoutMin.nanoseconds / self.dynamicLHMProtocolInterval.nanoseconds + 1
//    }
//
//    /// The suspicion timeout is calculated as defined in Lifeguard Section IV.B https://arxiv.org/abs/1707.00788
//    /// According to it, suspicion timeout is logarithmically decaying from `suspicionTimeoutPeriodsMax` to `suspicionTimeoutPeriodsMin`
//    /// depending on a number of suspicion confirmations.
//    ///
//    /// Suspicion timeout adjusted according to number of known independent suspicions of given member.
//    ///
//    /// See: Lifeguard IV-B: Local Health Aware Suspicion
//    ///
//    /// The timeout for a given suspicion is calculated as follows:
//    ///
//    /// ```
//    ///                                             log(C + 1) 􏰁
//    /// SuspicionTimeout =􏰀 max(Min, Max − (Max−Min) ----------)
//    ///                                             log(K + 1)
//    /// ```
//    ///
//    /// where:
//    /// - `Min` and `Max` are the minimum and maximum Suspicion timeout.
//    ///   See Section `V-C` for discussion of their configuration.
//    /// - `K` is the number of independent suspicions required to be received before setting the suspicion timeout to `Min`.
//    ///   We default `K` to `3`.
//    /// - `C` is the number of independent suspicions about that member received since the local suspicion was raised.
//    func suspicionTimeout(suspectedByCount: Int) -> TimeAmount {
//        let minTimeout = self.settings.lifeguard.suspicionTimeoutMin
//        let maxTimeout = self.settings.lifeguard.suspicionTimeoutMax
//        return max(minTimeout, .nanoseconds(maxTimeout.nanoseconds - Int64(round(Double(maxTimeout.nanoseconds - minTimeout.nanoseconds) * (log2(Double(suspectedByCount + 1)) / log2(Double(self.settings.lifeguard.maxIndependentSuspicions + 1)))))))
//    }
//
//    /// Checks if a deadline is expired (relating to current time).
//    func isExpired(deadline: Int64) -> Bool {
//        deadline < self.timeSourceNanos()
//    }
//
//    func status(of ref: ActorRef<SWIM.Message>) -> SWIM.Status? {
//        if self.notMyself(ref) {
//            return self.members[ref]?.status
//        } else {
//            return .alive(incarnation: self.incarnation)
//        }
//    }
//
//    func member(for ref: ActorRef<SWIM.Message>) -> SWIM.Member? {
//        self.members[ref]
//    }
//
//    func member(for node: UniqueNode) -> SWIM.Member? {
//        if self.myNode == node {
//            return self.member(for: self.myShellMyself)
//        }
//
//        return self.members.first(where: { key, _ in key.address.node == node })?.value
//    }
//
//    /// Counts non-dead members.
//    var memberCount: Int {
//        self.members.filter { !$0.value.isDead }.count
//    }
//
//    // for testing; used to implement the data for the testing message in the shell: .getMembershipState
//    var _allMembersDict: [ActorRef<SWIM.Message>: SWIM.Status] {
//        self.members.mapValues { $0.status }
//    }
//
//    /// Lists all suspect members.
//    var suspects: SWIM.Members {
//        self.members
//            .lazy
//            .map { $0.value }
//            .filter { $0.isSuspect }
//    }
//
//    /// Lists all members known to SWIM right now
//    var allMembers: SWIM.MembersValues {
//        self.members.values
//    }
//
//    func isMember(_ ref: ActorRef<SWIM.Message>) -> Bool {
//        // the ref could be either:
//        // - "us" (i.e. the actor which hosts this SWIM instance, or
//        // - a "known member"
//        ref.address == self.myShellAddress || self.members[ref] != nil
//    }
//
//    func makeGossipPayload(to target: ActorRef<SWIM.Message>?) -> SWIM.GossipPayload {
//        var members: [SWIM.Member] = []
//        // buddy system will always send to a suspect its suspicion.
//        // The reason for that to ensure the suspect will be notified it is being suspected,
//        // even if the suspicion has already been disseminated more than `numberOfTimesGossiped` times.
//        let targetIsSuspect: Bool
//        if let target = target, let member = self.member(for: target), member.isSuspect {
//            // the member is suspect, and we must inform it about this, thus including in gossip payload:
//            members.append(member)
//            targetIsSuspect = true
//        } else {
//            targetIsSuspect = false
//        }
//
//        // In order to avoid duplicates within a single gossip payload, we
//        // first collect all messages we need to gossip out and only then
//        // re-insert them into `messagesToGossip`. Otherwise, we may end up
//        // selecting the same message multiple times, if e.g. the total number
//        // of messages is smaller than the maximum gossip size, or for newer
//        // messages that have a lower `numberOfTimesGossiped` counter than
//        // the other messages.
//        guard self._messagesToGossip.count > 0 else {
//            if members.isEmpty {
//                return .none
//            } else {
//                return .membership(members)
//            }
//        }
//
//        var gossipMessages: [SWIM.Gossip] = []
//        gossipMessages.reserveCapacity(min(self.settings.gossip.maxGossipCountPerMessage, self._messagesToGossip.count))
//        while gossipMessages.count < self.settings.gossip.maxNumberOfMessages,
//            let gossip = self._messagesToGossip.removeRoot() {
//            gossipMessages.append(gossip)
//        }
//
//        members.reserveCapacity(gossipMessages.count)
//
//        for var gossip in gossipMessages {
//            // We do NOT add gossip to payload if it's a gossip about self and self is a suspect,
//            // this case was handled earlier and doing it here will lead to duplicate messages
//            if !(target == gossip.member.ref && targetIsSuspect) {
//                members.append(gossip.member)
//            }
//            gossip.numberOfTimesGossiped += 1
//            if gossip.numberOfTimesGossiped < self.settings.gossip.maxGossipCountPerMessage {
//                self._messagesToGossip.append(gossip)
//            }
//        }
//
//        return .membership(members)
//    }
//
//    private func addToGossip(member: SWIM.Member) {
//        // we need to remove old state before we add the new gossip, so we don't gossip out stale state
//        self._messagesToGossip.remove(where: { $0.member.ref == member.ref })
//        self._messagesToGossip.append(.init(member: member, numberOfTimesGossiped: 0))
//    }
//}
//
//// ==== ----------------------------------------------------------------------------------------------------------------
//// MARK: Handling SWIM protocol interactions
//
//extension SWIM.Instance {
//    func onPing() -> OnPingDirective {
//        .reply(.ack(target: self.myShellMyself, incarnation: self._incarnation, payload: self.makeGossipPayload(to: nil)))
//    }
//
//    enum OnPingDirective {
//        case reply(SWIM.PingResponse)
//    }
//
//    /// React to an `Ack` (or lack thereof within timeout)
//    func onPingRequestResponse(_ result: Result<SWIM.PingResponse, Error>, pingedMember member: ActorRef<SWIM.Message>) -> OnPingRequestResponseDirective {
//        guard let lastKnownStatus = self.status(of: member) else {
//            return .unknownMember
//        }
//
//        switch result {
//        case .failure:
//            // missed pingReq's nack may indicate a problem with local health
//            self.adjustLHMultiplier(.probeWithMissedNack)
//
//            switch lastKnownStatus {
//            case .alive(let incarnation), .suspect(let incarnation, _):
//                switch self.mark(member, as: self.makeSuspicion(incarnation: incarnation)) {
//                case .applied:
//                    return .newlySuspect
//                case .ignoredDueToOlderStatus(let status):
//                    return .ignoredDueToOlderStatus(currentStatus: status)
//                }
//            case .unreachable:
//                return .alreadyUnreachable
//            case .dead:
//                return .alreadyDead
//            }
//
//        case .success(.ack(let target, let incarnation, let payload)):
//            assert(target.address == member.address, "The ack.from member [\(target)] MUST be equal to the pinged member \(member.address)]; The Ack message is being forwarded back to us from the pinged member.")
//            self.adjustLHMultiplier(.successfulProbe)
//            switch self.mark(member, as: .alive(incarnation: incarnation)) {
//            case .applied:
//                // TODO: we can be more interesting here, was it a move suspect -> alive or a reassurance?
//                return .alive(previous: lastKnownStatus, payloadToProcess: payload)
//            case .ignoredDueToOlderStatus(let currentStatus):
//                return .ignoredDueToOlderStatus(currentStatus: currentStatus)
//            }
//        case .success(.nack):
//            return .nackReceived
//        }
//    }
//
//    enum OnPingRequestResponseDirective {
//        case alive(previous: SWIM.Status, payloadToProcess: SWIM.GossipPayload)
//        case nackReceived
//        case unknownMember
//        case newlySuspect
//        case alreadySuspect
//        case alreadyUnreachable
//        case alreadyDead
//        case ignoredDueToOlderStatus(currentStatus: SWIM.Status)
//    }
//
//    func onGossipPayload(about member: SWIM.Member) -> OnGossipPayloadDirective {
//        if self.isMyself(member) {
//            return onMyselfGossipPayload(myself: member)
//        } else {
//            return onOtherMemberGossipPayload(member: member)
//        }
//    }
//
//    private func onMyselfGossipPayload(myself incoming: SWIM.Member) -> SWIM.Instance.OnGossipPayloadDirective {
//        assert(self.myShellMyself == incoming.ref, "Attempted to process gossip as-if about myself, but was not the same ref, was: \(incoming). Myself: \(self.myShellMyself, orElse: "nil")")
//
//        // Note, we don't yield changes for myself node observations, thus the self node will never be reported as unreachable,
//        // after all, we can always reach ourselves. We may reconsider this if we wanted to allow SWIM to inform us about
//        // the fact that many other nodes think we're unreachable, and thus we could perform self-downing based upon this information // TODO: explore self-downing driven from SWIM
//
//        switch incoming.status {
//        case .alive:
//            // as long as other nodes see us as alive, we're happy
//            return .applied(change: nil)
//        case .suspect(let suspectedInIncarnation, _):
//            // someone suspected us, so we need to increment our incarnation number to spread our alive status with
//            // the incremented incarnation
//            if suspectedInIncarnation == self.incarnation {
//                self.adjustLHMultiplier(.refutingSuspectMessageAboutSelf)
//                self._incarnation += 1
//                // refute the suspicion, we clearly are still alive
//                self.addToGossip(member: SWIMMember(ref: myShellMyself, status: .alive(incarnation: self._incarnation), protocolPeriod: self.protocolPeriod))
//                return .applied(change: nil)
//            } else if suspectedInIncarnation > self.incarnation {
//                return .applied(
//                    change: nil,
//                    level: .warning,
//                    message: """
//                    Received gossip about self with incarnation number [\(suspectedInIncarnation)] > current incarnation [\(self._incarnation)], \
//                    which should never happen and while harmless is highly suspicious, please raise an issue with logs. This MAY be an issue in the library.
//                    """
//                )
//            } else {
//                // incoming incarnation was < than current one, i.e. the incoming information is "old" thus we discard it
//                return .ignored
//            }
//
//        case .unreachable(let unreachableInIncarnation):
//            // someone suspected us, so we need to increment our incarnation number to spread our alive status with
//            // the incremented incarnation
//            // TODO: this could be the right spot to reply with a .nack, to prove that we're still alive
//            if unreachableInIncarnation == self.incarnation {
//                self._incarnation += 1
//            } else if unreachableInIncarnation > self.incarnation {
//                return .applied(
//                    change: nil,
//                    level: .warning,
//                    message: """
//                    Received gossip about self with incarnation number [\(unreachableInIncarnation)] > current incarnation [\(self._incarnation)], \
//                    which should never happen and while harmless is highly suspicious, please raise an issue with logs. This MAY be an issue in the library.
//                    """
//                )
//            }
//
//            return .applied(change: nil)
//
//        case .dead:
//            guard var myselfMember = self.member(for: self.myShellMyself) else {
//                return .applied(change: nil)
//            }
//
//            myselfMember.status = .dead
//            switch self.mark(self.myShellMyself, as: .dead) {
//            case .applied(.some(let previousStatus), _):
//                return .applied(change: .init(fromStatus: previousStatus, member: myselfMember))
//            default:
//                return .ignored(level: .warning, message: "Self already marked .dead")
//            }
//        }
//    }
//
//    private func onOtherMemberGossipPayload(member: SWIM.Member) -> SWIM.Instance.OnGossipPayloadDirective {
//        assert(self.myShellMyself != member.ref, "Attempted to process gossip as-if not-myself, but WAS same ref, was: \(member). Myself: \(self.myShellMyself, orElse: "nil")")
//
//        if self.isMember(member.ref) {
//            switch self.mark(member.ref, as: member.status) {
//            case .applied(let previousStatus, let currentStatus):
//                var member = member
//                member.status = currentStatus
//                if currentStatus.isSuspect, previousStatus?.isAlive ?? false {
//                    return .applied(
//                        change: .init(fromStatus: previousStatus, member: member),
//                        level: .debug,
//                        message: "Member [\(member.ref.address.node, orElse: "<unknown-node>")] marked as suspect, via incoming gossip"
//                    )
//                } else {
//                    return .applied(change: .init(fromStatus: previousStatus, member: member))
//                }
//
//            case .ignoredDueToOlderStatus(let currentStatus):
//                return .ignored(
//                    level: .trace,
//                    message: "Gossip about member \(reflecting: member.node), incoming: [\(member.status)] does not supersede current: [\(currentStatus)]"
//                )
//            }
//        } else if let remoteMemberNode = member.ref.address.node {
//            return .connect(
//                node: remoteMemberNode,
//                onceConnected: {
//                    switch $0 {
//                    case .success:
//                        self.addMember(member.ref, status: member.status)
//                    case .failure:
//                        self.addMember(member.ref, status: self.makeSuspicion(incarnation: 0)) // connecting failed, so we immediately mark it as suspect (!)
//                    }
//                }
//            )
//        } else {
//            return .ignored(
//                level: .warning,
//                message: """
//                Received gossip about node which is neither myself or a remote node (i.e. address is not present)\
//                which is highly unexpected and may indicate a configuration or networking issue. Ignoring gossip about this member. \
//                Member: \(member), SWIM.Instance state: \(String(reflecting: self))
//                """
//            )
//        }
//    }
//
//    enum OnGossipPayloadDirective {
//        case applied(change: MemberStatusChange?, level: Logger.Level?, message: Logger.Message?)
//        /// Ignoring a gossip update is perfectly fine: it may be "too old" or other reasons
//        case ignored(level: Logger.Level?, message: Logger.Message?)
//        /// Warning! Even though we have an `UniqueNode` here, we need to ensure that we are actually connected to the node,
//        /// hosting this swim actor.
//        ///
//        /// It can happen that a gossip payload informs us about a node that we have not heard about before,
//        /// and do not have a connection to it either (e.g. we joined only seed nodes, and more nodes joined them later
//        /// we could get information through the seed nodes about the new members; but we still have never talked to them,
//        /// thus we need to ensure we have a connection to them, before we consider adding them to the membership).
//        case connect(node: UniqueNode, onceConnected: (Result<UniqueNode, Error>) -> Void)
//    }
//
//    struct MemberStatusChange {
//        let member: SWIM.Member
//        var toStatus: SWIM.Status {
//            // Note if the member is marked .dead, SWIM shall continue to gossip about it for a while
//            // such that other nodes gain this information directly, and do not have to wait until they detect
//            // it as such independently.
//            self.member.status
//        }
//
//        /// Previous status of the member, needed in order to decide if the change is "effective" or if applying the
//        /// member did not move it in such way that we need to inform the cluster about unreachability.
//        let fromStatus: SWIM.Status?
//
//        init(fromStatus: SWIM.Status?, member: SWIM.Member) {
//            if let from = fromStatus, from == .dead {
//                precondition(member.status == .dead, "Change MUST NOT move status 'backwards' from [.dead] state to anything else, but did so, was: \(member)")
//            }
//
//            self.fromStatus = fromStatus
//            self.member = member
//        }
//
//        /// True if the directive was `applied` and the from/to statuses differ, meaning that a change notification has issued.
//        var isReachabilityChange: Bool {
//            guard let fromStatus = self.fromStatus else {
//                // i.e. nil -> anything, is always an effective reachability affecting change
//                return true
//            }
//
//            // explicitly list all changes which are affecting reachability, all others do not (i.e. flipping between
//            // alive and suspect does NOT affect high-level reachability).
//            switch (fromStatus, self.toStatus) {
//            case (.alive, .unreachable),
//                 (.alive, .dead):
//                return true
//            case (.suspect, .unreachable),
//                 (.suspect, .dead):
//                return true
//            case (.unreachable, .alive),
//                 (.unreachable, .suspect):
//                return true
//            case (.dead, .alive),
//                 (.dead, .suspect),
//                 (.dead, .unreachable):
//                fatalError("Change MUST NOT move status 'backwards' from .dead state to anything else, but did so, was: \(self)")
//            default:
//                return false
//            }
//        }
//    }
//}
//
//extension SWIMInstance.OnGossipPayloadDirective {
//    static func applied(change: SWIM.MemberStatusChangedEvent?) -> SWIM.Instance.OnGossipPayloadDirective {
//        .applied(change: change, level: nil, message: nil)
//    }
//
//    static var ignored: SWIM.Instance.OnGossipPayloadDirective {
//        .ignored(level: nil, message: nil)
//    }
//}
//
//extension SWIM.Instance: CustomDebugStringConvertible {
//    public var debugDescription: String {
//        // multi-line on purpose
//        """
//        SWIMInstance(
//            settings: \(settings),
//
//            myLocalPath: \(String(reflecting: myShellAddress)),
//            myShellMyself: \(String(reflecting: myShellMyself)),
//
//            _incarnation: \(_incarnation),
//            _protocolPeriod: \(_protocolPeriod),
//
//            members: [
//                \(members.map { "\($0.key)" }.joined(separator: "\n        "))
//            ]
//            membersToPing: [
//                \(membersToPing.map { "\($0)" }.joined(separator: "\n        "))
//            ]
//
//            _messagesToGossip: \(_messagesToGossip)
//        )
//        """
//    }
//}
//
//// ==== ----------------------------------------------------------------------------------------------------------------
//// MARK: SWIM Lifeguard Local Health Modifier event
//
//extension SWIMInstance {
//    internal enum LHModifierEvent {
//        case successfulProbe
//        case failedProbe
//        case refutingSuspectMessageAboutSelf
//        case probeWithMissedNack
//    }
//}
