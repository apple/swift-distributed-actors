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

/// # SWIM (Scalable Weakly-consistent Infection-style Process Group Membership Protocol).
///
/// Namespace containing message types used to implement the SWIM protocol.
///
/// > As you swim lazily through the milieu,
/// > The secrets of the world will infect you.
///
/// - SeeAlso: https://www.cs.cornell.edu/projects/Quicksilver/public_pdfs/SWIM.pdf
final class SWIMInstance {

    let settings: SWIM.Settings

    /// Main members storage, map to values to obtain current members.
    private var members: [ActorRef<SWIM.Message>: SWIMMember]

    /// Constantly mutated by `nextMemberToPing` in an effort to keep the order in which we ping nodes evenly distributed.
    private var membersToPing: [SWIMMember]

    /// The incarnation number is used to get a sense of ordering of events, so if an `.alive` or `.suspect`
    /// state with a lower incarnation than the one currently known by a node is received, it can be dropped
    /// as outdated and we don't accidentally override state with older events. The incarnation can only
    /// be incremented by the respective node itself and will happen if that node receives a `.suspect` for
    /// itself, to which it will respond with an `.alive` with the incremented incarnation.
    var incarnation: SWIM.Incarnation {
        return self._incarnation
    }
    private var _incarnation: SWIM.Incarnation = 0

    // The protocol period represents the number of times we have pinged a random member
    // of the cluster. At the end of every ping cycle, the number will be incremented.
    // Suspicion timeouts are based on the protocol period, e.g. if the ping interval
    // is 300ms and the suspicion timeout is set to 10 periods, a suspected node will
    // be declared `.dead` after not receiving an `.alive` for approx. 3 seconds.
    private var _protocolPeriod: Int = 0

    // We need to store the path to the owning SWIMMembershipShell to avoid adding it to the `membersToPing` list
    private var myLocalPath: UniqueActorPath? = nil
    private var myRemotePath: UniqueActorPath? = nil
    private var myShellMyself: ActorRef<SWIM.Message>? = nil

    private var _messagesToGossip = Heap(of: SWIM.Gossip.self, comparator: {
        $0.numberOfTimesGossiped < $1.numberOfTimesGossiped
    })

    init(_ settings: SWIM.Settings) {
        self.settings = settings

        self.members = [:]
        self.membersToPing = []
    }

    func addMyself(_ ref: ActorRef<SWIM.Message>) {
        self.myLocalPath = ref.path

        let myRemoteAddress = ref._system!.settings.cluster.uniqueBindAddress // !-safe, system is always available, or we are dying anyway so crash is "ok"
        self.myRemotePath = ref.path
        self.myRemotePath?.address =  myRemoteAddress
        self.myShellMyself = ref
        self.addMember(ref, status: .alive(incarnation: 0))
    }

    enum AddMemberDirective {
        case added
        case newerMemberAlreadyPresent(SWIM.Member)
    }

    @discardableResult
    func addMember(_ ref: ActorRef<SWIM.Message>, status: SWIM.Status) -> AddMemberDirective {
        let maybeExistingMember = self.member(for: ref)
        if let existingMember = maybeExistingMember, existingMember.status.supersedes(status) {
            // we already have a newer state for this member
            return .newerMemberAlreadyPresent(existingMember)
        }

        let member = SWIMMember(ref: ref, status: status, protocolPeriod: self.protocolPeriod)
        if maybeExistingMember == nil && notMyself(member) {
            // Newly added members are inserted at a random spot in the list of members
            // to ping, to have a better distribution of messages to this node from all
            // other nodes. If for example all nodes would add it to the end of the list,
            // it would take a longer time until it would be pinged for the first time
            // and also likely receive multiple pings within a very short time frame.
            self.membersToPing.insert(member, at: Int.random(in: self.membersToPing.startIndex...self.membersToPing.endIndex))
        }

        self.members[ref] = member
        self.addToGossip(member: member)

        return .added
    }

    /// Implements the round-robin yet shuffled member to probe selection as proposed in the SWIM paper.
    ///
    /// This mechanism should reduce the time until state is spread across the whole cluster,
    /// by guaranteeing that each node will be gossiped to within N cycles (where N is the cluster size).
    ///
    /// - Note:
    ///   SWIM 4.3: [...] The failure detection protocol at member works by maintaining a list (intuitively, an array) of the known
    ///   elements of the current membership list, and select- ing ping targets not randomly from this list,
    ///   but in a round-robin fashion. Instead, a newly joining member is inserted in the membership list at
    ///   a position that is chosen uniformly at random. On completing a traversal of the entire list,
    ///   rearranges the membership list to a random reordering.
    func nextMemberToPing() -> ActorRef<SWIM.Message>? {
        if self.members.isEmpty {
            return nil
        }

        if self.membersToPing.isEmpty {
            self.membersToPing = self.members.values
                .lazy
                .filter { member in self.notMyself(member) && !member.isDead }
                .shuffled()
        }

        if self.membersToPing.isEmpty {
            return nil
        }

        return self.membersToPing.removeFirst().ref
    }

    /// Selects `settings.failureDetector.indirectProbeCount` members to send a `ping-req` to.
    func membersToPingRequest(target: ActorRef<SWIM.Message>) -> ArraySlice<SWIM.Member> {
        func notTarget(_ ref: ActorRef<SWIM.Message>) -> Bool {
            return ref.path != target.path
        }
        let candidates = self.membersToPing
            .filter { notTarget($0.ref) && notMyself($0.ref) }
            .shuffled()

        return candidates.prefix(self.settings.failureDetector.indirectProbeCount)
    }

    func notMyself(_ member: SWIM.Member) -> Bool {
        return self.notMyself(member.ref)
    }
    func notMyself(_ ref: ActorRef<SWIM.Message>) -> Bool {
        return self.notMyself(ref.path)
    }
    func notMyself(_ memberPath: UniqueActorPath) -> Bool {
        return !self.isMyself(memberPath)
    }
    func isMyself(_ member: SWIM.Member) -> Bool {
        return self.isMyself(member.ref.path)
    }
    func isMyself(_ memberPath: UniqueActorPath) -> Bool {
        return self.myLocalPath == memberPath || self.myRemotePath == memberPath
    }

    @discardableResult
    func mark(_ ref: ActorRef<SWIM.Message>, as status: SWIM.Status) -> MarkResult {
        let previousStatusOption = self.status(of: ref)
        if let previousStatus = previousStatusOption, previousStatus.supersedes(status) {
            // we already have a newer status for this member
            return .ignoredDueToOlderStatus(currentStatus: previousStatus)
        }

        let member = SWIM.Member(ref: ref, status: status, protocolPeriod: self.protocolPeriod)
        self.members[ref] = member
        self.addToGossip(member: member)

        return .applied(previousStatus: previousStatusOption)
    }
    enum MarkResult: Equatable {
        case ignoredDueToOlderStatus(currentStatus: SWIM.Status)
        case applied(previousStatus: SWIM.Status?)
    }

    func incrementProtocolPeriod() {
        self._protocolPeriod += 1
    }

    var protocolPeriod: Int {
        return self._protocolPeriod
    }

    func status(of ref: ActorRef<SWIM.Message>) -> SWIM.Status? {
        if notMyself(ref) {
            return self.members[ref]?.status
        } else {
            return .alive(incarnation: self.incarnation)
        }
    }

    func member(for ref: ActorRef<SWIM.Message>) -> SWIM.Member? {
        return self.members[ref]
    }

    var memberCount: Int {
        return self.members.count
    }

    var memberRefs: [ActorRef<SWIM.Message>] {
        return Array(self.members.keys)
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
        return ref.path == self.myLocalPath || self.members[ref] != nil
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

        var gossips: [SWIM.Gossip] = []
        gossips.reserveCapacity(min(self.settings.gossip.maxGossipCountPerMessage, self._messagesToGossip.count) )
        while gossips.count < self.settings.gossip.maxNumberOfMessages,
              let gossip = self._messagesToGossip.removeRoot() {
            gossips.append(gossip)
        }

        var members: [SWIM.Member] = []
        members.reserveCapacity(gossips.count)

        for var gossip in gossips {
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

        var warning: String? = nil
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
    func onPingRequestResponse(_ result: Result<SWIM.Ack, ExecutionError>, pingedMember member: ActorRef<SWIM.Message>) -> OnPingRequestResponseDirective {
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
            case .dead:
                return .alreadyDead
            }

        case .success(let ack):
            assert(ack.pinged.path == member.path, "The ack.from member [\(ack.pinged)] MUST be equal to the pinged member \(member.path)]; The Ack message is being forwarded back to us from the pinged member.")
            switch self.mark(member, as: .alive(incarnation: ack.incarnation)) {
            case .applied:
                // TODO we can be more interesting here, was it a move suspect -> alive or a reassurance?
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
        case alreadyDead
        case ignoredDueToOlderStatus(currentStatus: SWIM.Status)
    }

    func onGossipPayload(about member: SWIM.Member) -> OnGossipPayloadDirective {
        if self.isMyself(member) {
            switch member.status {
            case .alive:
                // as long as other nodes see us as alive, we're happy
                return .applied(warning: nil)
            case .suspect(let suspectedInIncarnation):
                // someone suspected us, so we need to increment our
                // incarnation number to spread our alive status with
                // the incremented incarnation
                if suspectedInIncarnation == self.incarnation {
                    self._incarnation += 1
                    return .applied(warning: nil)
                } else {
                    let warning = """
                                  Received gossip about self with incarnation number [\(suspectedInIncarnation)] > current incarnation [\(self._incarnation)], \
                                  which should never happen and while harmless is highly suspicious, please raise an issue with logs. This MAY be an issue in the library.
                                  """
                    return .applied(warning: warning)
                }

            case .dead:
                return .selfDeterminedDead
            }
        } else {
            if self.isMember(member.ref) {
                switch self.mark(member.ref, as: member.status) {
                case .applied:
                    return .applied(warning: nil)
                case .ignoredDueToOlderStatus(let currentStatus):
                    return .ignored(warning: "Ignoring gossip about member [\(member)] due to older status, incoming: [\(member.status)], current: [\(currentStatus)]")
                }
            } else if let remoteMemberAddress = member.ref.path.address?.address {
                return .connect(address: remoteMemberAddress, onceConnected: { _ in
                    self.addMember(member.ref, status: member.status)
                })
            } else {
                return .ignored(warning: """
                                         Received gossip about node which is neither myself or a remote node (i.e. address is not present)\
                                         which is highly unexpected and may indicate a configuration or networking issue. Ignoring gossip about this member. \
                                         Member: \(member), SWIM.Instance state: \(String(reflecting: self))
                                         """)
            }
        }
    }
    enum OnGossipPayloadDirective {
        case applied(warning: String?)
        /// Ignoring a gossip update is perfectly fine: it may be "too old" or other reasons
        case ignored(warning: String?)
        /// It can happen that a gossip payload informs us about a node that we have not heard about before,
        /// and do not have a connection to it either (e.g. we joined only seed nodes, and more nodes joined them later
        /// we could get information through the seed nodes about the new members; but we still have never talked to them,
        /// thus we need to ensure we have a connection to them, before we consider adding them to the membership).
        // TODO: OR! actually we add them right away, and if they don't reply to our probing we'd declare them down...? A bit weird hm...
        case connect(address: NodeAddress, onceConnected: (UniqueNodeAddress) -> ())
        case selfDeterminedDead
    }
}

extension SWIM.Instance: CustomDebugStringConvertible {
    public var debugDescription: String {
        // multi-line on purpose
        return """
               SWIMInstance(
                   settings: \(settings),
                   
                   myLocalPath: \(String(reflecting: myLocalPath)),
                   myRemotePath: \(String(reflecting: myRemotePath)),
                   myShellMyself: \(String(reflecting: myShellMyself)),
                                       
                   _incarnation: \(_incarnation),
                   _protocolPeriod: \(_protocolPeriod), 

                   members: [
                       \(members.map({"\($0.key)"}).joined(separator: "\n        "))
                   ] 
                   membersToPing: [ 
                       \(membersToPing.map({"\($0)"}).joined(separator: "\n        "))
                   ]
                    
                   _messagesToGossip: \(_messagesToGossip)
               )
               """
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SWIM Member

struct SWIMMember: Hashable {
    /// Each (SWIM) cluster member is running a `probe` actor which we interact with when gossiping the SWIM messages.
    let ref: ActorRef<SWIM.Message> // TODO better name for `ref` is it a `probeRef` (sounds right?) or `swimmerRef` (meh)?

    var status: SWIM.Status

    // Period in which protocol period was this state set
    var protocolPeriod: Int

    init(ref: ActorRef<SWIM.Message>, status: SWIM.Status, protocolPeriod: Int) {
        self.ref = ref
        self.status = status
        self.protocolPeriod = protocolPeriod
    }

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

