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

import DistributedActorsConcurrencyHelpers
import NIO

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Internal Shell responsible for all clustering (i.e. connection management) state.

/// The cluster shell "drives" all internal state machines of the cluster subsystem.
///
/// It is responsible for managing the underlying (re-)connections by extending and accepting/rejecting handshakes,
/// as well as orchestrating any high-level membership changes, e.g. by interacting with a failure detector and other gossip mechanisms.
///
/// It keeps the `Membership` instance that can be seen the source of truth for any membership based decisions.
internal class ClusterShell {
    internal static let naming = ActorNaming.unique("cluster")
    public typealias Ref = ActorRef<ClusterShell.Message>

    // ~~~~~~ HERE BE DRAGONS, shared concurrently modified concurrent state ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    // We do this to avoid "looping" any initial access of an actor ref through the cluster shell's mailbox
    // which would cause more latency to obtaining the association. refs cache the remote control once they have obtained it.

    private let _associationsLock: Lock

    /// Used by remote actor refs to obtain associations
    /// - Protected by: `_associationsLock`
    private var _associationsRegistry: [UniqueNode: AssociationRemoteControl]

    private var _swimRef: ActorRef<SWIM.Message>!

    private var _events: EventStream<ClusterEvent>!

    // FIXME: use event stream to publish events instead of direct communication
    private var _downingStrategyRef: ActorRef<DowningStrategyMessage>!

    // `_serializationPool` is only used when `start()` is invoked, and there it is set immediately as well
    // any earlier access to the pool is a bug (in our library) and must be treated as such.
    private var _serializationPool: SerializationPool?
    internal var serializationPool: SerializationPool {
        guard let pool = self._serializationPool else {
            fatalError("BUG! Tried to access serializationPool on \(self) and it was nil! Please report this on the issue tracker.")
        }
        return pool
    }

    internal func associationRemoteControl(with node: UniqueNode) -> AssociationRemoteControl? {
        return self._associationsLock.withLock {
            self._associationsRegistry[node]
        }
    }

    var associationRemoteControls: [AssociationRemoteControl] {
        return self._associationsLock.withLock {
            [AssociationRemoteControl](self._associationsRegistry.values)
        }
    }

    /// To be invoked by cluster shell whenever an association is made;
    /// The cache is used by remote actor refs to obtain means of sending messages into the pipeline,
    /// without having to queue through the cluster shell's mailbox.
    private func cacheAssociationRemoteControl(_ associationState: AssociationStateMachine.AssociatedState) {
        self._associationsLock.withLockVoid {
            // TODO: or association ID rather than the remote id?
            self._associationsRegistry[associationState.remoteNode] = associationState.makeRemoteControl()
        }
    }

    // TODO: `dead` associations could be moved on to a smaller map, like an optimized Int Set or something, to keep less space
    // ~~~~~~ END OF HERE BE DRAGONS, shared concurrently modified concurrent state ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Cluster Shell, reference used for issuing commands to the cluster

    private var _ref: ClusterShell.Ref?
    var ref: ClusterShell.Ref {
        // since this is initiated during system startup, nil should never happen
        // TODO: slap locks around it...
        guard let it = self._ref else {
            return fatalErrorBacktrace("Accessing ClusterShell.ref failed, was nil! This should never happen as access should only happen after start() was invoked.")
        }
        return it
    }

    init() {
        self._associationsLock = Lock()
        self._associationsRegistry = [:]

        // not enjoying this dance, but this way we can share the ClusterShell as the shell AND the container for the ref.
        // the single thing in the class it will modify is the associations registry, which we do to avoid actor queues when
        // remote refs need to obtain those
        //
        // FIXME: see if we can restructure this to avoid these nil/then-set dance
        self._ref = nil
    }

    /// Actually starts the shell which kicks off binding to a port, and all further cluster work
    internal func start(system: ActorSystem, eventStream: EventStream<ClusterEvent>) throws -> StartDelayed<Message> {
        self._serializationPool = try SerializationPool(settings: .default, serialization: system.serialization)
        self._events = eventStream

        // TODO: concurrency... lock the ref as others may read it?
        let delayed = try system._spawnSystemActorDelayed(
            ClusterShell.naming,
            self.bind(),
            props: self.props,
            perpetual: true
        )

        self._ref = delayed.ref

        return delayed
    }

    // Due to lack of Union Types, we have to emulate them
    enum Message: NoSerializationVerification {
        // The external API, exposed to users of the ClusterShell
        case command(CommandMessage)
        // The external API, exposed to users of the ClusterShell to query for state
        case query(QueryMessage)
        /// Messages internally driving the state machines; timeouts, network inbound events etc.
        case inbound(InboundMessage)
    }

    // this is basically our API internally for this system
    enum CommandMessage: NoSerializationVerification, SilentDeadLetter {
        case join(Node)

        case handshakeWith(Node, replyTo: ActorRef<HandshakeResult>?)
        case retryHandshake(HandshakeStateMachine.InitiatedState)

        case reachabilityChanged(UniqueNode, MemberReachability)

        case downCommand(Node)
        case unbind(BlockingReceptacle<Void>) // TODO: could be NIO future
    }

    enum QueryMessage: NoSerializationVerification {
        case associatedNodes(ActorRef<Set<UniqueNode>>) // TODO: better type here
        case currentMembership(ActorRef<Membership>)
        // TODO: case subscribeAssociations(ActorRef<[UniqueNode]>) // to receive events about it one by one
    }

    internal enum InboundMessage {
        case handshakeOffer(Wire.HandshakeOffer, channel: Channel, replyTo: EventLoopPromise<Wire.HandshakeResponse>)
        case handshakeAccepted(Wire.HandshakeAccept, channel: Channel)
        case handshakeRejected(Wire.HandshakeReject)
        case handshakeFailed(Node, Error) // TODO: remove?
    }

    // TODO: reformulate as Wire.accept / reject?
    internal enum HandshakeResult: Equatable {
        case success(UniqueNode)
        case failure(HandshakeConnectionError)
    }

    struct HandshakeConnectionError: Error, Equatable { // TODO: merge with HandshakeError?
        let node: Node
        let message: String
    }

    private var behavior: Behavior<Message> {
        return self.bind() // todo message self to bind?
    }

    private var props: Props =
        Props()
        .supervision(strategy: .escalate) // always fail completely
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster Bootstrap / Binding

extension ClusterShell {
    /// Binds on setup to the configured address (as configured in `system.settings.cluster`).
    ///
    /// Once bound proceeds to `ready` state, where it remains to accept or initiate new handshakes.
    private func bind() -> Behavior<Message> {
        return .setup { context in
            let clusterSettings = context.system.settings.cluster
            let uniqueBindAddress = clusterSettings.uniqueBindNode

            let swimBehavior = SWIMShell(settings: clusterSettings.swim, clusterRef: context.myself).behavior
            self._swimRef = try context.system._spawnSystemActor(SWIMShell.naming, swimBehavior, perpetual: true)

            switch clusterSettings.downingStrategy {
            case .noop:
                let shell = DowningStrategyShell(NoopDowningStrategy())
                self._downingStrategyRef = try context.spawn(shell.naming, shell.behavior)
            case .timeout(let settings):
                let shell = DowningStrategyShell(TimeoutBasedDowningStrategy(settings, selfNode: context.system.settings.cluster.uniqueBindNode))
                self._downingStrategyRef = try context.spawn(shell.naming, shell.behavior)
            }

            // FIXME: all the ordering dance with creating of state and the address...
            context.log.info("Binding to: [\(uniqueBindAddress)]")

            let chanElf = self.bootstrapServerSide(
                system: context.system,
                shell: context.myself,
                bindAddress: uniqueBindAddress,
                settings: clusterSettings,
                serializationPool: self.serializationPool
            )

            // TODO: configurable bind timeout?
            return context.awaitResultThrowing(of: chanElf, timeout: .milliseconds(300)) { (chan: Channel) in
                context.log.info("Bound to \(chan.localAddress.map { $0.description } ?? "<no-local-address>")")

                let state = ClusterShellState(settings: clusterSettings, channel: chan, log: context.log)
                context.system.metrics.recordMembership(state.membership)

                return self.ready(state: state)
            }
        }
    }

    /// Ready and interpreting commands and incoming messages.
    ///
    /// Serves as main "driver" for handshake and association state machines.
    private func ready(state: ClusterShellState) -> Behavior<Message> {
        func receiveShellCommand(context: ActorContext<Message>, command: CommandMessage) -> Behavior<Message> {
            state.tracelog(.inbound, message: command)

            switch command {
            case .join(let node):
                return self.onJoin(context, state: state, joining: node)

            case .handshakeWith(let remoteAddress, let replyTo):
                return self.beginHandshake(context, state, with: remoteAddress, replyTo: replyTo)
            case .retryHandshake(let initiated):
                return self.connectSendHandshakeOffer(context, state, initiated: initiated)

            case .reachabilityChanged(let node, let reachability):
                return self.onReachabilityChange(context, state: state, node: node, reachability: reachability)

            case .unbind(let receptacle):
                // TODO: should become shutdown
                return self.unbind(context, state: state, signalOnceUnbound: receptacle)

            case .downCommand(let node):
                return self.onDownCommand(context, state: state, down: node)
            }
        }

        func receiveQuery(context: ActorContext<Message>, query: QueryMessage) -> Behavior<Message> {
            switch query {
            case .associatedNodes(let replyTo):
                replyTo.tell(state.associatedNodes()) // TODO: we'll want to put this into some nicer message wrapper?
                return .same
            case .currentMembership(let replyTo):
                replyTo.tell(state.membership)
                return .same
            }
        }

        func receiveInbound(context: ActorContext<Message>, message: InboundMessage) throws -> Behavior<Message> {
            switch message {
            case .handshakeOffer(let offer, let channel, let promise):
                self.tracelog(context, .receiveUnique(from: offer.from), message: offer)
                return self.onHandshakeOffer(context, state, offer, channel: channel, replyInto: promise)

            case .handshakeAccepted(let accepted, let channel):
                self.tracelog(context, .receiveUnique(from: accepted.from), message: accepted)
                return self.onHandshakeAccepted(context, state, accepted, channel: channel)

            case .handshakeRejected(let rejected):
                self.tracelog(context, .receive(from: rejected.from), message: rejected)
                return self.onHandshakeRejected(context, state, rejected)

            case .handshakeFailed(let address, let error):
                self.tracelog(context, .receive(from: address), message: error)
                return self.onHandshakeFailed(context, state, with: address, error: error) // FIXME: implement this basically disassociate() right away?
            }
        }

        // TODO: would be nice with some form of subReceive...
        return .receive { context, message in
            switch message {
            case .command(let command): return receiveShellCommand(context: context, command: command)
            case .query(let query): return receiveQuery(context: context, query: query)
            case .inbound(let inbound): return try receiveInbound(context: context, message: inbound)
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Handshake init

extension ClusterShell {
    /// Initiate an outgoing handshake to the `remoteNode`
    ///
    /// Handshakes are currently not performed concurrently but one by one.
    internal func beginHandshake(_ context: ActorContext<Message>, _ state: ClusterShellState, with remoteNode: Node, replyTo: ActorRef<HandshakeResult>?) -> Behavior<Message> {
        var state = state

        if let existingAssociation = state.association(with: remoteNode) {
            // TODO: we maybe could want to attempt and drop the other "old" one?
            state.log.debug("Attempted associating with already associated node: [\(remoteNode)], existing association: [\(existingAssociation)]")
            switch existingAssociation {
            case .associated(let associationState):
                replyTo?.tell(.success(associationState.remoteNode))
            }
            return .same
        }

        let whenHandshakeComplete = state.eventLoopGroup.next().makePromise(of: Wire.HandshakeResponse.self)
        whenHandshakeComplete.futureResult.onComplete { result in
            switch result {
            case .success(.accept(let accept)):
                /// we need to switch here, since we MAY have been attached to an ongoing handshake which may have been initiated
                /// in either direction // TODO check if this is really needed.
                let associatedRemoteNode: UniqueNode
                if accept.from.node == remoteNode {
                    associatedRemoteNode = accept.from
                } else {
                    associatedRemoteNode = accept.origin
                }
                replyTo?.tell(.success(associatedRemoteNode))
            case .success(.reject(let reject)):
                replyTo?.tell(.failure(HandshakeConnectionError(node: remoteNode, message: reject.reason)))
            case .failure(let error):
                replyTo?.tell(HandshakeResult.failure(.init(node: remoteNode, message: "\(error)")))
            }
        }

        let handshakeState = state.registerHandshake(with: remoteNode, whenCompleted: whenHandshakeComplete)
        // we MUST register the intention of shaking hands with remoteAddress before obtaining the connection,
        // in order to let the fsm handle any retry decisions in face of connection failures et al.

        switch handshakeState {
        case .initiated(let initiated):
            return self.connectSendHandshakeOffer(context, state, initiated: initiated)

        case .wasOfferedHandshake, .inFlight, .completed:
            // the reply will be handled already by the future.onComplete we've set up above here
            // so nothing to do here, just become the next state
            return self.ready(state: state)
        }
    }

    func connectSendHandshakeOffer(_ context: ActorContext<Message>, _ state: ClusterShellState, initiated: HandshakeStateMachine.InitiatedState) -> Behavior<Message> {
        var state = state

        state.log.info("Extending handshake offer to \(initiated.remoteNode))") // TODO: log retry stats?
        let offer: Wire.HandshakeOffer = initiated.makeOffer()
        self.tracelog(context, .send(to: initiated.remoteNode), message: offer)

        let outboundChanElf: EventLoopFuture<Channel> = self.bootstrapClientSide(
            system: context.system,
            shell: context.myself,
            targetNode: initiated.remoteNode,
            handshakeOffer: offer,
            settings: state.settings,
            serializationPool: self.serializationPool
        )

        // the timeout is being handled by the `connectTimeout` socket option
        // in NIO, so it is safe to use an infinite timeout here
        return context.awaitResult(of: outboundChanElf, timeout: .effectivelyInfinite) { result in
            switch result {
            case .success(let chan):
                return self.ready(state: state.onHandshakeChannelConnected(initiated: initiated, channel: chan))

            case .failure(let error):
                return self.onOutboundConnectionError(context, state, with: initiated.remoteNode, error: error)
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Incoming Handshake

extension ClusterShell {
    /// Initial entry point for accepting a new connection; Potentially allocates new handshake state machine.
    internal func onHandshakeOffer(_ context: ActorContext<Message>, _ state: ClusterShellState,
                                   _ offer: Wire.HandshakeOffer, channel: Channel, replyInto promise: EventLoopPromise<Wire.HandshakeResponse>) -> Behavior<Message> {
        var state = state

        switch state.onIncomingHandshakeOffer(offer: offer) {
        case .negotiate(let hsm):
            // handshake is allowed to proceed
            switch hsm.negotiate() {
            case .acceptAndAssociate(let completedHandshake):
                state.log.info("Accept association with \(offer.from)!")

                let association = state.associate(completedHandshake, channel: channel)
                self.cacheAssociationRemoteControl(association)

                let accept = completedHandshake.makeAccept()
                self.tracelog(context, .send(to: offer.from.node), message: accept)
                promise.succeed(.accept(accept))

                return self.ready(state: state)

            case .rejectHandshake(let rejectedHandshake):
                state.log.warning("Rejecting handshake from \(offer.from), error: [\(rejectedHandshake.error)]:\(type(of: rejectedHandshake.error))")

                // note that we should NOT abort the channel here since we still want to send back the rejection.

                let reject: Wire.HandshakeReject = rejectedHandshake.makeReject()
                self.tracelog(context, .send(to: offer.from.node), message: reject)
                promise.succeed(.reject(reject))

                return self.ready(state: state)
            }
        case .abortDueToConcurrentHandshake:
            // concurrent handshake and we should abort
            let error = HandshakeConnectionError(
                node: offer.from.node,
                message: """
                Terminating this connection, as there is a concurrently established connection with same host [\(offer.from)] \
                which will be used to complete the handshake.
                """
            )
            state.abortIncomingHandshake(offer: offer, channel: channel)
            promise.fail(error)
            return .same
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Failures to obtain connections

extension ClusterShell {
    func onOutboundConnectionError(_ context: ActorContext<Message>, _ state: ClusterShellState, with remoteNode: Node, error: Error) -> Behavior<Message> {
        var state = state
        state.log.warning("Failed await for outbound channel to \(remoteNode); Error was: \(error)")

        guard let handshakeState = state.handshakeInProgress(with: remoteNode) else {
            state.log.warning("Connection error for handshake which is not in progress, this should not happen, but is harmless.") // TODO: meh or fail hard
            return .ignore
        }

        switch handshakeState {
        case .initiated(var initiated):
            switch initiated.onHandshakeError(error) {
            case .scheduleRetryHandshake(let delay):
                state.log.debug("Schedule handshake retry to: [\(initiated.remoteNode)] delay: [\(delay)]")
                context.timers.startSingle(
                    key: TimerKey("handshake-timer-\(remoteNode)"),
                    message: .command(.retryHandshake(initiated)),
                    delay: delay
                )
            case .giveUpOnHandshake:
                if let hsmState = state.abortOutgoingHandshake(with: remoteNode) {
                    self.notifyHandshakeFailure(state: hsmState, node: remoteNode, error: error)
                }
            }

        case .wasOfferedHandshake(let state):
            preconditionFailure("Outbound connection error should never happen on receiving end. State was: [\(state)], error was: \(error)")
        case .completed(let state):
            preconditionFailure("Outbound connection error on already completed state handshake. This should not happen. State was: [\(state)], error was: \(error)")
        case .inFlight:
            preconditionFailure("An in-flight marker state should never be stored, yet was encountered in \(#function)")
        }

        return self.ready(state: state)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Incoming Handshake Replies

extension ClusterShell {
    private func onHandshakeAccepted(_ context: ActorContext<Message>, _ state: ClusterShellState, _ accept: Wire.HandshakeAccept, channel: Channel) -> Behavior<Message> {
        var state = state // local copy for mutation

        guard let completed = state.incomingHandshakeAccept(accept) else {
            if state.associatedNodes().contains(accept.from) {
                // this seems to be a re-delivered accept, we already accepted association with this node.
                return .ignore
            } else {
                state.log.error("Illegal handshake accept received. No handshake was in progress with \(accept.from)") // TODO: tests and think this through more
                return .same
            }
        }

        let association = state.associate(completed, channel: channel)
        self.cacheAssociationRemoteControl(association)
        state.log.debug("Associated with: \(completed.remoteNode). Membership: \(state.membership)")

        completed.whenCompleted?.succeed(.accept(completed.makeAccept()))

        context.system.metrics.recordMembership(state.membership)
        return self.ready(state: state)
    }

    private func onHandshakeRejected(_ context: ActorContext<Message>, _ state: ClusterShellState, _ reject: Wire.HandshakeReject) -> Behavior<Message> {
        var state = state

        state.log.error("Handshake was rejected by: [\(reject.from)], reason: [\(reject.reason)]")

        // TODO: back off intensely, give up after some attempts?

        if let hsmState = state.abortOutgoingHandshake(with: reject.from) {
            self.notifyHandshakeFailure(state: hsmState, node: reject.from, error: HandshakeConnectionError(node: reject.from, message: reject.reason))
        }

        context.system.metrics.recordMembership(state.membership)
        return self.ready(state: state)
    }

    private func onHandshakeFailed(_ context: ActorContext<Message>, _ state: ClusterShellState, with node: Node, error: Error) -> Behavior<Message> {
        var state = state

        state.log.error("Handshake error while connecting [\(node)]: \(error)")
        if let hsmState = state.abortOutgoingHandshake(with: node) {
            self.notifyHandshakeFailure(state: hsmState, node: node, error: error)
        }

        context.system.metrics.recordMembership(state.membership)
        return self.ready(state: state)
    }

    private func notifyHandshakeFailure(state: HandshakeStateMachine.State, node: Node, error: Error) {
        switch state {
        case .initiated(let initiated):
            initiated.whenCompleted?.fail(HandshakeConnectionError(node: node, message: "\(error)"))
        case .wasOfferedHandshake(let offered):
            offered.whenCompleted?.fail(HandshakeConnectionError(node: node, message: "\(error)"))
        case .completed(let completed):
            completed.whenCompleted?.fail(HandshakeConnectionError(node: node, message: "\(error)"))
        case .inFlight:
            preconditionFailure("An in-flight marker state should never be stored, yet was encountered in \(#function)")
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Unbind

extension ClusterShell {
    fileprivate func unbind(_ context: ActorContext<Message>, state: ClusterShellState, signalOnceUnbound: BlockingReceptacle<Void>) -> Behavior<Message> {
        let addrDesc = "\(state.settings.uniqueBindNode.node.host):\(state.settings.uniqueBindNode.node.port)"
        return context.awaitResult(of: state.channel.close(mode: .all), timeout: .seconds(3)) { // TODO: hardcoded timeout
            switch $0 {
            case .success:
                context.log.info("Unbound server socket [\(addrDesc)].")
                signalOnceUnbound.offerOnce(())
                self.serializationPool.shutdown()
                return .stop
            case .failure(let err):
                context.log.warning("Failed while unbinding server socket [\(addrDesc)]. Error: \(err)")
                signalOnceUnbound.offerOnce(())
                self.serializationPool.shutdown()
                throw err
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Handling cluster membership changes

extension ClusterShell {
    /// Joining needs to inform SWIM about the new member; it in turn will ensure we associate with it, and inform us when it can be moved to joining/up
    func onJoin(_ context: ActorContext<Message>, state: ClusterShellState, joining node: Node) -> Behavior<Message> {
        self._swimRef.tell(.local(.monitor(node)))
        return .same
    }

    func onReachabilityChange(_ context: ActorContext<Message>, state: ClusterShellState,
                              node: UniqueNode, reachability: MemberReachability) -> Behavior<Message> {
        var state = state

        if let changedMember = state.onMemberReachabilityChange(node, toReachability: reachability) {
            switch reachability {
            case .unreachable:
                self._events.publish(.reachability(.memberUnreachable(changedMember)))
            case .reachable:
                self._events.publish(.reachability(.memberReachable(changedMember)))
            }

            context.system.metrics.recordMembership(state.membership)
            return self.ready(state: state)
        } else {
            return .same
        }
    }

    func onDownCommand(_ context: ActorContext<Message>, state: ClusterShellState, down node: Node) -> Behavior<Message> {
        var state = state

        if let change = state.onMembershipChange(node, toStatus: .down) {
            // self.nodeDeathWatcher.tell(.forceDown(change.node))
            self._events.publish(.membership(.memberDown(Member(node: change.node, status: .down))))

            if let logChangeLevel = state.settings.logMembershipChanges {
                context.log.log(level: logChangeLevel, "Cluster membership change: \(reflecting: change), membership: \(state.membership)")
            }
        }

        guard node != state.selfNode.node else {
            // ==== ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
            // Down(self node); ensuring SWIM knows about this and should likely initiate graceful shutdown

            self._swimRef.tell(.local(.confirmDead(state.selfNode)))

            context.log.warning("Self node was determined [DOWN].")

            return self.ready(state: state)
        }

        // ==== ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
        // Down(other node);

        guard let association = state.association(with: node) else {
            context.log.debug("Received Down command for not associated node [\(node)], ignoring.")
            return .ignore
        }

        // TODO: push more logic into the State (Instance/Shell style)

        switch association {
        case .associated(let associated):
            self._swimRef.tell(.local(.confirmDead(associated.remoteNode)))
            state.log.info("Marked node [\(associated.remoteNode)] as: DOWN")
            // case tombstone ???
        }

        return self.ready(state: state)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Data types

/// Connection errors should result in Disassociating with the offending system.
enum ActorsProtocolError: Error {
    case illegalHandshake(reason: Error)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: TraceLog for Cluster

extension ClusterShell {
    /// Optional "dump all messages" logging.
    private func tracelog(_ context: ActorContext<ClusterShell.Message>, _ type: TraceLogType, message: Any,
                          file: String = #file, function: String = #function, line: UInt = #line) {
        if let level = context.system.settings.cluster.traceLogLevel {
            context.log.log(
                level: level,
                "[tracelog:cluster] \(type.description): \(message)",
                file: file, function: function, line: line
            )
        }
    }

    internal enum TraceLogType: CustomStringConvertible {
        case send(to: Node)
        case receive(from: Node)
        case receiveUnique(from: UniqueNode)

        var description: String {
            switch self {
            case .send(let to):
                return "SEND(to:\(to))"
            case .receive(let from):
                return "RECV(from:\(from))"
            case .receiveUnique(let from):
                return "RECV(from:\(from))"
            }
        }
    }
}
