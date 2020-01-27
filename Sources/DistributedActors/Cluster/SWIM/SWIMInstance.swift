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

/// # SWIM (Scalable Weakly-consistent Infection-style Process Group Membership Protocol).
///
/// Implementation of the SWIM protocol in abstract terms, see [SWIMShell] for the actor acting upon directives issued by this instance.
///
/// > As you swim lazily through the milieu,
/// > The secrets of the world will infect you.
///
/// ### Modifications
/// - Random, stable order members to ping selection: Unlike the completely random selection in the original paper.
///
/// See the reference documentation of this swim implementation in the reference documentation.
///
/// ### Related Papers
/// - SeeAlso: [SWIM: Scalable Weakly-consistent Infection-style Process Group Membership Protocol](https://www.cs.cornell.edu/projects/Quicksilver/public_pdfs/SWIM.pdf)
/// - SeeAlso: [Lifeguard: Local Health Awareness for More Accurate Failure Detection](https://arxiv.org/abs/1707.00788)
final class SWIMInstance {
    let settings: SWIM.Settings

    /// Main members storage, map to values to obtain current members.
    private var members: [ActorRef<SWIM.Message>: SWIMMember]

    /// List of members maintained in random yet stable order, see `addMember` for details.
    internal var membersToPing: [SWIMMember]
    /// Constantly mutated by `nextMemberToPing` in an effort to keep the order in which we ping nodes evenly distributed.
    private var _membersToPingIndex: Int = 0
    private var membersToPingIndex: Int {
        self._membersToPingIndex
    }

    /// The incarnation number is used to get a sense of ordering of events, so if an `.alive` or `.suspect`
    /// state with a lower incarnation than the one currently known by a node is received, it can be dropped
    /// as outdated and we don't accidentally override state with older events. The incarnation can only
    /// be incremented by the respective node itself and will happen if that node receives a `.suspect` for
    /// itself, to which it will respond with an `.alive` with the incremented incarnation.
    var incarnation: SWIM.Incarnation {
        self._incarnation
    }

    private var _incarnation: SWIM.Incarnation = 0

    // The protocol period represents the number of times we have pinged a random member
    // of the cluster. At the end of every ping cycle, the number will be incremented.
    // Suspicion timeouts are based on the protocol period, e.g. if the ping interval
    // is 300ms and the suspicion timeout is set to 10 periods, a suspected node will
    // be declared `.dead` after not receiving an `.alive` for approx. 3 seconds.
    private var _protocolPeriod: Int = 0

    // We store the owning SWIMShell ref in order avoid adding it to the `membersToPing` list
    private var myShellMyself: ActorRef<SWIM.Message>?
    private var myShellAddress: ActorAddress? {
        self.myShellMyself?.address
    }

    private var myNode: UniqueNode?

    private var _messagesToGossip = Heap(of: SWIM.Gossip.self, comparator: {
        $0.numberOfTimesGossiped < $1.numberOfTimesGossiped
    })

    init(_ settings: SWIM.Settings) {
        self.settings = settings

        self.members = [:]
        self.membersToPing = []
    }

    // FIXME: only reason myNode is optional is tests where we test from actors all on the same node
    func addMyself(_ ref: ActorRef<SWIM.Message>, node myNode: UniqueNode? = nil) {
        self.myShellMyself = ref
        self.myNode = myNode
        self.addMember(ref, status: .alive(incarnation: 0))
    }

    @discardableResult
    func addMember(_ ref: ActorRef<SWIM.Message>, status: SWIM.Status) -> AddMemberDirective {
        let maybeExistingMember = self.member(for: ref)
        if let existingMember = maybeExistingMember, existingMember.status.supersedes(status) {
            // we already have a newer state for this member
            return .newerMemberAlreadyPresent(existingMember)
        }

        let member = SWIMMember(ref: ref, status: status, protocolPeriod: self.protocolPeriod)
        self.members[ref] = member

        if maybeExistingMember == nil, self.notMyself(member) {
            // Newly added members are inserted at a random spot in the list of members
            // to ping, to have a better distribution of messages to this node from all
            // other nodes. If for example all nodes would add it to the end of the list,
            // it would take a longer time until it would be pinged for the first time
            // and also likely receive multiple pings within a very short time frame.
            let insertIndex = Int.random(in: self.membersToPing.startIndex ... self.membersToPing.endIndex)
            self.membersToPing.insert(member, at: insertIndex)
            if insertIndex <= self.membersToPingIndex {
                // If we inserted the new member before the current `membersToPingIndex`,
                // we need to advance the index to avoid pinging the same member multiple
                // times in a row. This is especially critical when inserting a larger
                // number of members, e.g. when the cluster is just being formed, or
                // on a rolling restart.
                self.advanceMembersToPingIndex()
            }
        }

        self.addToGossip(member: member)

        return .added(member)
    }

    enum AddMemberDirective {
        case added(SWIM.Member)
        case newerMemberAlreadyPresent(SWIM.Member)
    }

    /// Implements the round-robin yet shuffled member to probe selection as proposed in the SWIM paper.
    ///
    /// This mechanism should reduce the time until state is spread across the whole cluster,
    /// by guaranteeing that each node will be gossiped to within N cycles (where N is the cluster size).
    ///
    /// - Note:
    ///   SWIM 4.3: [...] The failure detection protocol at member works by maintaining a list (intuitively, an array) of the known
    ///   elements of the current membership list, and select-ing ping targets not randomly from this list,
    ///   but in a round-robin fashion. Instead, a newly joining member is inserted in the membership list at
    ///   a position that is chosen uniformly at random. On completing a traversal of the entire list,
    ///   rearranges the membership list to a random reordering.
    func nextMemberToPing() -> ActorRef<SWIM.Message>? {
        if self.membersToPing.isEmpty {
            return nil
        }

        defer { self.advanceMembersToPingIndex() }
        return self.membersToPing[self.membersToPingIndex].ref
    }

    /// Selects `settings.failureDetector.indirectProbeCount` members to send a `ping-req` to.
    func membersToPingRequest(target: ActorRef<SWIM.Message>) -> ArraySlice<SWIM.Member> {
        func notTarget(_ ref: ActorRef<SWIM.Message>) -> Bool {
            return ref.address != target.address
        }
        func isReachable(_ status: SWIM.Status) -> Bool {
            return status.isAlive || status.isSuspect
        }
        let candidates = self.members
            .values
            .filter { notTarget($0.ref) && notMyself($0.ref) && isReachable($0.status) }
            .shuffled()

        return candidates.prefix(self.settings.failureDetector.indirectProbeCount)
    }

    func notMyself(_ member: SWIM.Member) -> Bool {
        return self.notMyself(member.ref)
    }

    func notMyself(_ ref: ActorRef<SWIM.Message>) -> Bool {
        return self.notMyself(ref.address)
    }

    func notMyself(_ memberAddress: ActorAddress) -> Bool {
        return !self.isMyself(memberAddress)
    }

    func isMyself(_ member: SWIM.Member) -> Bool {
        return self.isMyself(member.ref.address)
    }

    func isMyself(_ memberAddress: ActorAddress) -> Bool {
        return self.myShellAddress == memberAddress
    }

    @discardableResult
    func mark(_ ref: ActorRef<SWIM.Message>, as status: SWIM.Status) -> MarkedDirective {
        let previousStatusOption = self.status(of: ref)

        if let previousStatus = previousStatusOption, previousStatus.supersedes(status) {
            // we already have a newer status for this member
            return .ignoredDueToOlderStatus(currentStatus: previousStatus)
        }

        let member = SWIM.Member(ref: ref, status: status, protocolPeriod: self.protocolPeriod)
        self.members[ref] = member
        self.addToGossip(member: member)

        if status.isDead {
            self.removeFromMembersToPing(member)
        }

        return .applied(previousStatus: previousStatusOption, currentStatus: status)
    }

    enum MarkedDirective: Equatable {
        case ignoredDueToOlderStatus(currentStatus: SWIM.Status)
        case applied(previousStatus: SWIM.Status?, currentStatus: SWIM.Status)

        /// True if the directive was `applied` and the from/to statuses differ, meaning that a change notification has issued.
        var isEffectiveStatusChange: Bool {
            switch self {
            case .ignoredDueToOlderStatus:
                return false
            case .applied(nil, _):
                // from no status, to any status is definitely an effective change
                return true
            case .applied(.some(let previousStatus), let currentStatus):
                return previousStatus != currentStatus
            }
        }
    }

    func incrementProtocolPeriod() {
        self._protocolPeriod += 1
    }

    func advanceMembersToPingIndex() {
        self._membersToPingIndex = (self._membersToPingIndex + 1) % self.membersToPing.count
    }

    func removeFromMembersToPing(_ member: SWIM.Member) {
        if let index = self.membersToPing.firstIndex(where: { $0.ref == member.ref }) {
            self.membersToPing.remove(at: index)
            if index < self.membersToPingIndex {
                self._membersToPingIndex -= 1
            }

            if self.membersToPingIndex >= self.membersToPing.count {
                self._membersToPingIndex = self.membersToPing.startIndex
            }
        }
    }

    var protocolPeriod: Int {
        return self._protocolPeriod
    }

    func status(of ref: ActorRef<SWIM.Message>) -> SWIM.Status? {
        if self.notMyself(ref) {
            return self.members[ref]?.status
        } else {
            return .alive(incarnation: self.incarnation)
        }
    }

    func member(for ref: ActorRef<SWIM.Message>) -> SWIM.Member? {
        return self.members[ref]
    }

    func member(for node: UniqueNode) -> SWIM.Member? {
        if self.myNode == node {
            return self.member(for: self.myShellMyself!)
        }

        return self.members.first(where: { key, _ in key.address.node == node })?.value
    }

    /// Counts non-dead members.
    var memberCount: Int {
        return self.members.filter { !$0.value.isDead }.count
    }

    // for testing; used to implement the data for the testing message in the shell: .getMembershipState
    var _allMembersDict: [ActorRef<SWIM.Message>: SWIM.Status] {
        return self.members.mapValues { $0.status }
    }

    /// Lists all suspect members, including myself if suspect.
    var suspects: [SWIM.Member] {
        return self.members
            .lazy
            .map { $0.value }
            .filter { $0.isSuspect }
    }

    func isMember(_ ref: ActorRef<SWIM.Message>) -> Bool {
        // the ref could be either:
        // - "us" (i.e. the actor which hosts this SWIM instance, or
        // - a "known member"
        return ref.address == self.myShellAddress || self.members[ref] != nil
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

        var gossipMessages: [SWIM.Gossip] = []
        gossipMessages.reserveCapacity(min(self.settings.gossip.maxGossipCountPerMessage, self._messagesToGossip.count))
        while gossipMessages.count < self.settings.gossip.maxNumberOfMessages,
            let gossip = self._messagesToGossip.removeRoot() {
            gossipMessages.append(gossip)
        }

        var members: [SWIM.Member] = []
        members.reserveCapacity(gossipMessages.count)

        for var gossip in gossipMessages {
            members.append(gossip.member)
            gossip.numberOfTimesGossiped += 1
            if gossip.numberOfTimesGossiped < self.settings.gossip.maxGossipCountPerMessage {
                self._messagesToGossip.append(gossip)
            }
        }

        return .membership(members)
    }

    private func addToGossip(member: SWIM.Member) {
        // we need to remove old state before we add the new gossip, so we don't gossip out stale state
        self._messagesToGossip.remove(where: { $0.member.ref == member.ref })
        self._messagesToGossip.append(.init(member: member, numberOfTimesGossiped: 0))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Handling SWIM protocol interactions

extension SWIM.Instance {
    func onPing(lastKnownStatus: SWIM.Status) -> OnPingDirective {
        guard let myself = self.myShellMyself else {
            preconditionFailure("Myself (ref to SWIM.Shell) must be set before reacting to ping messages.")
        }

        var warning: String?
        // if a node suspects us in the current incarnation, we need to increment
        // our incarnation number, so the new `alive` status can properly propagate through
        // the cluster (and "win" over the old `.suspect` status).
        if case .suspect(let suspectedInIncarnation) = lastKnownStatus {
            if suspectedInIncarnation == self._incarnation {
                self._incarnation += 1
                warning = nil
            } else if suspectedInIncarnation > self._incarnation {
                // this should never happen, because the only member allowed to increment our incarnation nr is _us_,
                // so it is not possible (unless malicious intents) to observe an incarnation larger than we are at.
                warning = """
                Received ping with incarnation number [\(suspectedInIncarnation)] > current incarnation [\(self._incarnation)], \
                which should never happen and while harmless is highly suspicious, please raise an issue with logs. This MAY be an issue in the library.
                """
            }
        }

        let ack = SWIM.Ack(pinged: myself, incarnation: self._incarnation, payload: self.makeGossipPayload())

        return .reply(ack, warning: warning)
    }

    enum OnPingDirective {
        case reply(SWIM.Ack, warning: String?)
    }

    /// React to an `Ack` (or lack thereof within timeout)
    func onPingRequestResponse(_ result: Result<SWIM.Ack, Error>, pingedMember member: ActorRef<SWIM.Message>) -> OnPingRequestResponseDirective {
        guard let lastKnownStatus = self.status(of: member) else {
            return .unknownMember
        }

        switch result {
        case .failure:
            switch lastKnownStatus {
            case .alive(let incarnation):
                switch self.mark(member, as: .suspect(incarnation: incarnation)) {
                case .applied:
                    return .newlySuspect
                case .ignoredDueToOlderStatus(let status):
                    return .ignoredDueToOlderStatus(currentStatus: status)
                }
            case .suspect:
                return .alreadySuspect
            case .unreachable:
                return .alreadyUnreachable
            case .dead:
                return .alreadyDead
            }

        case .success(let ack):
            assert(ack.pinged.address == member.address, "The ack.from member [\(ack.pinged)] MUST be equal to the pinged member \(member.address)]; The Ack message is being forwarded back to us from the pinged member.")
            switch self.mark(member, as: .alive(incarnation: ack.incarnation)) {
            case .applied:
                // TODO: we can be more interesting here, was it a move suspect -> alive or a reassurance?
                return .alive(previous: lastKnownStatus, payloadToProcess: ack.payload)
            case .ignoredDueToOlderStatus(let currentStatus):
                return .ignoredDueToOlderStatus(currentStatus: currentStatus)
            }
        }
    }

    enum OnPingRequestResponseDirective {
        case alive(previous: SWIM.Status, payloadToProcess: SWIM.Payload)
        case unknownMember
        case newlySuspect
        case alreadySuspect
        case alreadyUnreachable
        case alreadyDead
        case ignoredDueToOlderStatus(currentStatus: SWIM.Status)
    }

    func onGossipPayload(about member: SWIM.Member) -> OnGossipPayloadDirective {
        if self.isMyself(member) {
            switch member.status {
            case .alive:
                // as long as other nodes see us as alive, we're happy
                return .applied
            case .suspect(let suspectedInIncarnation):
                // someone suspected us, so we need to increment our incarnation number to spread our alive status with
                // the incremented incarnation
                if suspectedInIncarnation == self.incarnation {
                    self._incarnation += 1
                } else if suspectedInIncarnation > self.incarnation {
                    return .applied(
                        level: .warning,
                        message: """
                        Received gossip about self with incarnation number [\(suspectedInIncarnation)] > current incarnation [\(self._incarnation)], \
                        which should never happen and while harmless is highly suspicious, please raise an issue with logs. This MAY be an issue in the library.
                        """
                    )
                }
                return .applied

            case .unreachable(let unreachableInIncarnation):
                // someone suspected us, so we need to increment our
                // incarnation number to spread our alive status with
                // the incremented incarnation
                if unreachableInIncarnation == self.incarnation {
                    self._incarnation += 1
                } else if unreachableInIncarnation > self.incarnation {
                    return .applied(
                        level: .warning,
                        message: """
                        Received gossip about self with incarnation number [\(unreachableInIncarnation)] > current incarnation [\(self._incarnation)], \
                        which should never happen and while harmless is highly suspicious, please raise an issue with logs. This MAY be an issue in the library.
                        """
                    )
                }

                return .applied

            case .dead:
                return .confirmedDead(member: member)
            }
        } else {
            if self.isMember(member.ref) {
                switch self.mark(member.ref, as: member.status) {
                case .applied(_, let currentStatus):
                    switch currentStatus {
                    case .unreachable:
                        return .applied(level: .notice, message: "Member \(member) marked [.unreachable] from incoming gossip")
                    case .alive:
                        // TODO: could be another spot that we have to issue a reachable though?
                        return .ignored
                    case .suspect:
                        return .markedSuspect(member: member)
                    case .dead:
                        return .confirmedDead(member: member)
                    }
                case .ignoredDueToOlderStatus(let currentStatus):
                    return .ignored(
                        level: .trace,
                        message: "Ignoring gossip about member \(reflecting: member.node), incoming: [\(member.status)] does not supersede current: [\(currentStatus)]"
                    )
                }
            } else if let remoteMemberNode = member.ref.address.node {
                return .connect(node: remoteMemberNode, onceConnected: {
                    switch $0 {
                    case .success(let uniqueNode):
                        self.addMember(member.ref, status: member.status)
                    case .failure(let error):
                        self.addMember(member.ref, status: .suspect(incarnation: 0)) // connecting failed, so we immediately mark it as suspect (!)
                    }
                })
            } else {
                return .ignored(
                    level: .warning,
                    message: """
                    Received gossip about node which is neither myself or a remote node (i.e. address is not present)\
                    which is highly unexpected and may indicate a configuration or networking issue. Ignoring gossip about this member. \
                    Member: \(member), SWIM.Instance state: \(String(reflecting: self))
                    """
                )
            }
        }
    }

    enum OnGossipPayloadDirective {
        case applied(level: Logger.Level?, message: Logger.Message?)
        /// Ignoring a gossip update is perfectly fine: it may be "too old" or other reasons
        case ignored(level: Logger.Level?, message: Logger.Message?)
        /// Warning! Even though we have an `UniqueNode` here, we need to ensure that we are actually connected to the node,
        /// hosting this swim actor.
        ///
        /// It can happen that a gossip payload informs us about a node that we have not heard about before,
        /// and do not have a connection to it either (e.g. we joined only seed nodes, and more nodes joined them later
        /// we could get information through the seed nodes about the new members; but we still have never talked to them,
        /// thus we need to ensure we have a connection to them, before we consider adding them to the membership).
        case connect(node: UniqueNode, onceConnected: (Result<UniqueNode, Error>) -> Void)
        case markedSuspect(member: SWIM.Member)
        /// Meaning the node is now marked `DEAD`.
        /// SWIM will continue to gossip about the dead node for a while.
        /// We should also notify the high-level membership that the node shall be considered `DOWN`.
        case confirmedDead(member: SWIM.Member)
    }
}

extension SWIMInstance.OnGossipPayloadDirective {
    static var applied: SWIMInstance.OnGossipPayloadDirective {
        return .applied(level: nil, message: nil)
    }

    static var ignored: SWIMInstance.OnGossipPayloadDirective {
        return .ignored(level: nil, message: nil)
    }
}

extension SWIM.Instance: CustomDebugStringConvertible {
    public var debugDescription: String {
        // multi-line on purpose
        return """
        SWIMInstance(
            settings: \(settings),
            
            myLocalPath: \(String(reflecting: myShellAddress)),
            myShellMyself: \(String(reflecting: myShellMyself)),
                                
            _incarnation: \(_incarnation),
            _protocolPeriod: \(_protocolPeriod), 

            members: [
                \(members.map { "\($0.key)" }.joined(separator: "\n        "))
            ] 
            membersToPing: [ 
                \(membersToPing.map { "\($0)" }.joined(separator: "\n        "))
            ]
             
            _messagesToGossip: \(_messagesToGossip)
        )
        """
    }
}
