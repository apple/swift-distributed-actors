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

import NIO
import DistributedActorsConcurrencyHelpers

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Internal Shell responsible for all networking/remoting/clustering state

/// The network shell "drives" all internal state machines of the remoting subsystem.
internal class ClusterShell { // TODO: may still change the name, we'll see how we end up splitting things
    public typealias Ref = ActorRef<ClusterShell.Message>

    // ~~~~~~ HERE BE DRAGONS, shared concurrently modified concurrent state ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    // We do this to avoid "looping" any initial access of an actor ref through the cluster shell's mailbox
    // which would cause more latency to obtaining the association. refs cache the remote control once they have obtained it.

    private let _associationsLock: Lock

    /// Used by remote actor refs to obtain associations
    /// - Protected by: `_associationsLock`
    private var _associationsRegistry: [NodeUID: AssociationRemoteControl]

    // `_serializationPool` is only used when `start()` is invoked, and there it is set immediately as well
    // any earlier access to the pool is a bug (in our library) and must be treated as such.
    private var _serializationPool: SerializationPool? = nil
    internal var serializationPool: SerializationPool {
        guard let pool = self._serializationPool else {
            fatalError("BUG! Tried to access serializationPool on \(self) and it was nil! Please report this on the issue tracker.")
        }
        return pool
    }

    internal func associationRemoteControl(with uid: NodeUID) -> AssociationRemoteControl? {
        return self._associationsLock.withLock {
            return self._associationsRegistry[uid]
        }
    }

    var associationRemoteControls: [AssociationRemoteControl] {
        return self._associationsLock.withLock {
            return [AssociationRemoteControl](self._associationsRegistry.values)
        }
    }

    /// To be invoked by cluster shell whenever an association is made;
    /// The cache is used by remote actor refs to obtain means of sending messages into the pipeline,
    /// without having to queue through the cluster shell's mailbox.
    private func cacheAssociationRemoteControl(_ associationState: AssociationStateMachine.AssociatedState) {
        self._associationsLock.withLockVoid {
            // TODO or association ID rather than the remote id?
            self._associationsRegistry[associationState.remoteAddress.uid] = associationState.makeRemoteControl()
        }
    }
    
    // TODO `dead` associations could be moved on to a smaller map, like an optimized Int Set or something, to keep less space
    // ~~~~~~ END OF HERE BE DRAGONS, shared concurrently modified concurrent state ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Cluster Shell, reference used for issuing commands to the cluster

    private var _ref: ClusterShell.Ref?
    var ref: ClusterShell.Ref {
        // since this is initiated during system startup, nil should never happen
        // TODO slap locks around it...
        guard let it = self._ref else {
            return fatalErrorBacktrace("Accessing ClusterShell.ref failed, was nil! This should never happen as access should only happen after start() was invoked.")
        }
        return it
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Failure Detector

    // Implementation notes: The `_failureDetectorRef` has to remain internally accessible.
    // This is in order to solve a chicken-and-egg problem that we face during spawning of
    // the first system actor that is the *failure detector* so it cannot reach to the systems
    // value before it started... // TODO see if we indeed shall guarantee that this is the first actor?
    var _failureDetectorRef: FailureDetectorShell.Ref?
    var failureDetectorRef: FailureDetectorShell.Ref {
        guard let it = self._failureDetectorRef else {
            return fatalErrorBacktrace("Accessing ClusterShell.failureDetector failed, was nil! This should never happen as access should only happen after start() was invoked.")
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
        // TODO see if we can restructure this to avoid these nil/then-set dance
        self._ref = nil
        self._failureDetectorRef = nil
    }

    /// Actually starts the shell which kicks off binding to a port, and all further remoting work
    internal func start(system: ActorSystem) throws -> ClusterShell.Ref {
        self._serializationPool = try SerializationPool.init(settings: .default, serialization: system.serialization)

        // TODO maybe a bit inverted... maybe create it inside the failure detector actor?
        let failureDetector = try system.settings.cluster.makeFailureDetector(system: system)
        self._failureDetectorRef = try system._spawnSystemActor(
            FailureDetectorShell.behavior(driving: failureDetector),
            name: "failureDetector")

        // TODO concurrency... lock the ref as others may read it?
        self._ref = try system._spawnSystemActor(
            self.bind(),
            name: "remoting",
            props: self.props)
        
        return self.ref
    }

    func shutdown(waitingAtMost timeout: TimeAmount = .seconds(3)) {
        let receptacle = BlockingReceptacle<Void>()
        self.ref.tell(.command(.unbind(receptacle)))
        // TODO: actually stop all event loops?
        // TODO: once/if in a cluster we should attempt to leave nicely; the command would be more than "unbind" I suppose
        receptacle.wait(atMost: timeout)
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
    enum CommandMessage: NoSerializationVerification {
        // this is basically our API internally for this system

        // case bind(Wire.NodeAddress) since binds right away from config settings // TODO: Bind is done right away in start, should we do the bind command instead?
        case handshakeWith(NodeAddress)
        case unbind(BlockingReceptacle<Void>)
    } 
    enum QueryMessage: NoSerializationVerification {
        case associatedNodes(ActorRef<Set<UniqueNodeAddress>>) // TODO better type here
        // TODO: case subscribeAssociations(ActorRef<[UniqueNodeAddress]>) // to receive events about it one by one
    }
    internal enum InboundMessage {
        case handshakeOffer(Wire.HandshakeOffer, channel: Channel, replyTo: EventLoopPromise<Wire.HandshakeResponse>)
        case handshakeAccepted(Wire.HandshakeAccept, channel: Channel)
        case handshakeRejected(Wire.HandshakeReject)
        case handshakeFailed(NodeAddress, Error) // TODO remove?
    }

    private var behavior: Behavior<Message> {
        return self.bind() // todo message self to bind?
    }

    private var props: Props =
        Props()
            .addingSupervision(strategy: .stop) // always fail completely (may revisit this)

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
            let uniqueBindAddress = clusterSettings.uniqueBindAddress

            // FIXME: all the ordering dance with creating of state and the address...
            context.log.info("Binding to: [\(uniqueBindAddress)]")

            let chanLogger = ActorLogger.make(system: context.system, identifier: "channel") // TODO better id
            let chanElf: EventLoopFuture<Channel> = self.bootstrapServerSide(system: context.system, shell: context.myself, log: chanLogger, bindAddress: uniqueBindAddress, settings: clusterSettings, serializationPool: self.serializationPool)

            // TODO: configurable bind timeout?

            //  TODO crash everything, entire system, when bind fails
            return context.awaitResultThrowing(of: chanElf, timeout: .milliseconds(300)) { (chan: Channel) in
                context.log.info("Bound to \(chan.localAddress.map { $0.description } ?? "<no-local-address>")")
                
                let state = ClusterShellState(settings: clusterSettings, channel: chan, log: context.log)

                return self.ready(state: state)
            }
        }
    }

    /// Ready and interpreting commands and incoming messages.
    ///
    /// Serves as main "driver" for handshake and association state machines.
    private func ready(state: ClusterShellState) -> Behavior<Message> {
        func receiveShellCommand(context: ActorContext<Message>, command: CommandMessage) -> Behavior<Message> {
            switch command {
            case .handshakeWith(let remoteAddress):
                return self.beginHandshake(context, state, with: remoteAddress)
            case .unbind(let receptacle):
                return self.unbind(context, state: state, signalOnceUnbound: receptacle)
            }
        }

        func receiveQuery(context: ActorContext<Message>, query: QueryMessage) -> Behavior<Message> {
            switch query {
            case .associatedNodes(let replyTo):
                replyTo.tell(state.associatedAddresses()) // TODO: we'll want to put this into some nicer message wrapper?
                return .same
            }
        }

        func receiveInbound(context: ActorContext<Message>, message: InboundMessage) throws -> Behavior<Message> {
            switch message {
            case .handshakeOffer(let offer, let channel, let promise):
                return self.onHandshakeOffer(state, offer, channel: channel, replyInto: promise)
            case .handshakeAccepted( let accepted, let channel):
                return self.onHandshakeAccepted(state, accepted, channel: channel)
            case .handshakeRejected(let rejected):
                return self.onHandshakeRejected(state, rejected)
            case .handshakeFailed(_, let error):
                // return self.onHandshakeFailed(state, rejected) // FIXME implement this basically disassociate() right away?
                return FIXME("HANDSHAKE FAILED: [\(error)]:\(type(of: error))") // FIXME: handshake reject should be implemented
            }
        }

        // TODO: would be nice with some form of subReceive...
        return .receive { context, message in
            switch message {
            case .command(let command): return receiveShellCommand(context: context, command: command)
            case .query(let query):     return receiveQuery(context: context, query: query)
            case .inbound(let inbound): return try receiveInbound(context: context, message: inbound)
            }
        }
    }
}

// Implements: Handshake init
extension ClusterShell {
    /// Initiate an outgoing handshake to the `address`
    ///
    /// Handshakes are currently not performed concurrently but one by one.
    private func beginHandshake(_ context: ActorContext<Message>, _ state: ClusterShellState, with remoteAddress: NodeAddress) -> Behavior<Message> {
        var state = state

        if let existingAssociation = state.association(with: remoteAddress) {
            // TODO in reality should attempt and may need to drop the other "old" one?
            state.log.warning("Attempted associating with already associated node: [\(remoteAddress)], existing association: [\(existingAssociation)]")
            return .same
        }

        state.log.info("Initiating handshake with \(remoteAddress)...")
        let hsm = state.registerHandshake(with: remoteAddress)
        // we MUST register the intention of shaking hands with remoteAddress before obtaining the connection,
        // in order to let the fsm handle any retry decisions in face of connection failures et al.

        // TODO make sure we never to multiple connections to the same remote; associations must get IDs?
        // TODO: This is rather costly... we should not have to stop processing other messages until the connect completes;
        //       change this so we can connect to many hosts in parallel
        let outboundChanElf: EventLoopFuture<Channel> = self.bootstrapClientSide(
            system: context.system,
            shell: context.myself,
            log: context.log,
            targetAddress: remoteAddress,
            handshakeOffer: hsm.makeOffer(),
            settings: state.settings,
            serializationPool: self.serializationPool
        )

        return context.awaitResult(of: outboundChanElf, timeout: .milliseconds(100)) {
            switch $0 {
            case .success:
                return self.ready(state: state)

            case .failure(let error):
                return self.onOutboundConnectionError(context, state, with: remoteAddress, error: error)
            }
        }
    }
}

// Implements: Incoming Handshake
extension ClusterShell {
    
    /// Initial entry point for accepting a new connection; Potentially allocates new handshake state machine.
    private func onHandshakeOffer(_ state: ClusterShellState, _ offer: Wire.HandshakeOffer, channel: Channel, replyInto promise: EventLoopPromise<Wire.HandshakeResponse>) -> Behavior<Message> {
        var newState = state
        let log = state.log

        if let hsm = newState.incomingHandshake(offer: offer) {
            // handshake is allowed to proceed;
            // TODO: semantics; what if we already have one in progress; we could return this rather than this if/else
            log.debug("Negotiating handshake...")
            switch hsm.negotiate() {
            case .acceptAndAssociate(let completedHandshake):
                log.info("Accept association with \(offer.from)!")
                let association = newState.associate(completedHandshake, channel: channel)
                self.cacheAssociationRemoteControl(association)
                let accept = completedHandshake.makeAccept()
                promise.succeed(.accept(accept))
                return self.ready(state: newState)

            case .rejectHandshake(let rejectedHandshake):
                log.info("Rejecting handshake from \(offer.from)! Error: \(rejectedHandshake.error)")
                newState.abortHandshake(with: offer.from.address)
                promise.succeed(.reject(rejectedHandshake.makeReject()))
                return self.ready(state: newState)
            }
        } else {
            log.warning("Ignoring handshake offer \(offer), no state machine available for it...")
            return .ignore
        }
    }
}


// Implements: Failures to obtain connections
extension ClusterShell {

    func onOutboundConnectionError(_ context: ActorContext<Message>, _ state: ClusterShellState, with remoteAddress: NodeAddress, error: Error) -> Behavior<Message> {
        var state = state
        state.log.warning("Failed await for outbound channel to \(remoteAddress); Error was: \(error)")

        guard let handshakeState = state.handshakeInProgress(with: remoteAddress) else {
            state.log.warning("Connection error for handshake which is not in progress, this should not happen, but is harmless.") // TODO meh or fail hard
            return .ignore
        }

        switch handshakeState {
        case .initiated(var hsm):
            switch hsm.onHandshakeError(error) {
            case .scheduleRetryHandshake(let delay):
                state.log.info("Schedule retry handshake to: [\(hsm.remoteAddress)] delay: [\(delay)]")
                context.timers.startSingleTimer(
                    key: "handshake-timer-\(remoteAddress)", 
                    // message: .command(.retryHandshakeWith(remoteAddress)), // TODO better?
                    message: .command(.handshakeWith(remoteAddress)),
                    delay: delay
                )
            case .giveUpOnHandshake:
                state.abortHandshake(with: remoteAddress)
            }

        case .wasOfferedHandshake(let state):
            preconditionFailure("Outbound connection error should never happen on receiving end. State was: [\(state)], error was: \(error)")
        case .completed(let state):
            preconditionFailure("Outbound connection error on already completed state handshake. This should not happen. State was: [\(state)], error was: \(error)")
        }
        
        return self.ready(state: state)
    }
}

// Implements: Incoming Handshake Replies
extension ClusterShell {
    private func onHandshakeAccepted(_ state: ClusterShellState, _ accept: Wire.HandshakeAccept, channel: Channel) -> Behavior<Message> {
        var state = state // local copy for mutation

        guard let completed = state.incomingHandshakeAccept(accept) else {
            if state.associatedAddresses().contains(accept.from) {
                // this seems to be a re-delivered accept, we already accepted association with this node.
                return .ignore
            } else {
                state.log.error("Illegal handshake accept received. No handshake was in progress with \(accept.from)") // TODO tests and think this through more
                return .same
            }
        }

        let association = state.associate(completed, channel: channel)

        state.log.debug("[Cluster] Associated with: \(completed.remoteAddress).")
        self.cacheAssociationRemoteControl(association)
        return self.ready(state: state)
    }

    private func onHandshakeRejected(_ state: ClusterShellState, _ reject: Wire.HandshakeReject) -> Behavior<Message> {
        var state = state

        state.log.error("Handshake was rejected by: [\(reject.from)], reason: [\(reject.reason)]")

        state.abortHandshake(with: reject.from)
        return self.ready(state: state)
    }
}


// Implements: Unbind
extension ClusterShell {

    fileprivate func unbind(_ context: ActorContext<Message>, state: ClusterShellState, signalOnceUnbound: BlockingReceptacle<Void>) -> Behavior<Message> {
        let addrDesc = "\(state.settings.uniqueBindAddress.address.host):\(state.settings.uniqueBindAddress.address.port)"
        return context.awaitResult(of: state.channel.close(mode: .all), timeout: .seconds(3)) { // TODO hardcoded timeout
            switch $0 {
            case .success:
                context.log.info("Unbound server socket [\(addrDesc)].")
                signalOnceUnbound.offerOnce(())
                return .stopped
            case .failure(let err):
                context.log.warning("Failed while unbinding server socket [\(addrDesc)]. Error: \(err)")
                signalOnceUnbound.offerOnce(())
                throw err
            }
        }
    }
}

// MARK: Data types

/// Connection errors should result in Disassociating with the offending system.
enum SwiftDistributedActorsProtocolError: Error {
    case illegalHandshake(reason: Error)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Shell State

// TODO we hopefully will rather than this, end up with specialized protocols depending on what we need to expose,
// and then types may require those specific capabilities from the shell; e.g. scheduling things or similar.
internal protocol ReadOnlyClusterState {
    var log: Logger { get }
    var allocator: ByteBufferAllocator { get }
    var eventLoopGroup: EventLoopGroup { get } // TODO or expose the MultiThreaded one...?

    /// Base backoff strategy to use in handshake retries // TODO: move it around somewhere so only handshake cares?
    var backoffStrategy: BackoffStrategy { get }

    /// Unique address of the current node.
    var localAddress: UniqueNodeAddress { get }
    var settings: ClusterSettings { get }
}

/// State of the `ClusterShell` state machine.
internal struct ClusterShellState: ReadOnlyClusterState {
    typealias Messages = ClusterShell.Message

    // TODO maybe move log and settings outside of state into the shell?
    public var log: Logger
    public let settings: ClusterSettings

    public let localAddress: UniqueNodeAddress
    public let channel: Channel

    public let eventLoopGroup: EventLoopGroup

    public var backoffStrategy: BackoffStrategy {
        return settings.handshakeBackoffStrategy
    }

    public let allocator: ByteBufferAllocator

    private var _handshakes: [NodeAddress: HandshakeStateMachine.State] = [:]
    private var _associations: [NodeAddress: AssociationStateMachine.State] = [:]

    // TODO somehow protect / sync associations and membership view?
    // TODO this may move... not sure yet who should "own" the membership; we'll see once we do membership provider or however we call it then
    private var membership: Membership = .empty


    init(settings: ClusterSettings, channel: Channel, log: Logger) {
        self.settings = settings
        self.allocator = settings.allocator
        self.eventLoopGroup = settings.eventLoopGroup ?? settings.makeDefaultEventLoopGroup()
        self.localAddress = settings.uniqueBindAddress

        self.channel = channel

        self.log = log
    }

    func association(with address: NodeAddress) -> AssociationStateMachine.State? {
        return self._associations[address]
    }

    func associatedAddresses() -> Set<UniqueNodeAddress> {
        var set: Set<UniqueNodeAddress> = .init(minimumCapacity: self._associations.count)

        for asm in self._associations.values {
            switch asm {
            case .associated(let state): set.insert(state.remoteAddress)
            }
        }

        return set
    }
    func handshakes() -> [HandshakeStateMachine.State] {
        return self._handshakes.values.map { hsm -> HandshakeStateMachine.State in
            return hsm
        }
    }
}

extension ClusterShellState {

    /// This is the entry point for a client initiating a handshake with a remote node.
    mutating func registerHandshake(with remoteAddress: NodeAddress) -> HandshakeStateMachine.InitiatedState {
        // TODO more checks here, so we don't reconnect many times etc

        if let existingAssociation = self.association(with: remoteAddress) {
            self.log.warning("Beginning new handshake to [\(reflecting: remoteAddress)], with already existing association: \(existingAssociation). Could this be a bug?")
        }

        let handshakeFsm = HandshakeStateMachine.InitiatedState(settings: self.settings, localAddress: self.localAddress, connectTo: remoteAddress)
        let handshakeState = HandshakeStateMachine.State.initiated(handshakeFsm)
        self._handshakes[remoteAddress] = handshakeState
        return handshakeFsm
    }
    
    func handshakeInProgress(with address: NodeAddress) -> HandshakeStateMachine.State? {
        return self._handshakes[address]
    }

    /// Abort a handshake, clearing any of its state;
    mutating func abortHandshake(with address: NodeAddress) {
        self._handshakes.removeValue(forKey: address)
    }

    /// This is the entry point for a server receiving a handshake with a remote node.
    /// Inspects and possibly allocates a `HandshakeStateMachine` in the `HandshakeReceivedState` state.
    mutating func incomingHandshake(offer: Wire.HandshakeOffer) -> HandshakeStateMachine.HandshakeReceivedState? { // TODO return directives to act on
        if self._handshakes[offer.from.address] != nil {
            return FIXME("we should respond that already have this handshake in progress?") // FIXME: add test for incoming handshake while one in progress already
        } else {
            let fsm = HandshakeStateMachine.HandshakeReceivedState(state: self, offer: offer)
            self._handshakes[offer.from.address] = .wasOfferedHandshake(fsm)
            return fsm
        }
    }
    mutating func incomingHandshakeAccept(_ accept: Wire.HandshakeAccept) -> HandshakeStateMachine.CompletedState? { // TODO return directives to act on
        if let inProgressHandshake = self._handshakes[accept.from.address] {
            switch inProgressHandshake {
            case .initiated(let hsm):
                let completed = HandshakeStateMachine.CompletedState(fromInitiated: hsm, remoteAddress: accept.from)
                return completed
            case .wasOfferedHandshake:
                // TODO model the states to express this can not happen // there is a client side state machine and a server side one
                self.log.warning("Received accept but state machine is in WAS OFFERED state. This should be impossible.")
                return nil
            case .completed:
                // TODO: validate if it is for the same UID or not, if not, we may be in trouble?
                self.log.warning("Received handshake Accept for already completed handshake. This should not happen.")
                return nil
            }
        } else {
            fatalError("ACCEPT incoming for handshake which was not in progress!") // TODO model differently
        }
    }

    /// "Upgrades" a connection with a remote node from handshaking state to associated.
    /// Stores an `Association` for the newly established association;
    mutating func associate(_ handshake: HandshakeStateMachine.CompletedState, channel: Channel) -> AssociationStateMachine.AssociatedState {
        guard self._handshakes.removeValue(forKey: handshake.remoteAddress.address) != nil else {
            fatalError("BOOM: Can't complete a handshake which was not in progress!") // throw HandshakeError.acceptAttemptForNotInProgressHandshake(handshake)
            // TODO perhaps we instead just warn and ignore this; since it should be harmless
        }

        let asm = AssociationStateMachine.AssociatedState(fromCompleted: handshake, log: self.log, over: channel)
        let state: AssociationStateMachine.State = .associated(asm)
        
        // TODO store and update membership inside here?
        // TODO: this is not so nice, since we now have membership kind of in two places, we should make this somehow nicer...
        // TODO: Membership should drive all decisions about "allowed to join" etc, and the replacement decisions as well.

        func storeAssociation() {
            self._associations[handshake.remoteAddress.address] = state
        }

        let change = self.membership.join(handshake.remoteAddress)
        if change.isReplace {
            switch self.association(with: handshake.remoteAddress.address) {
            case .some(.associated(let associated)):
                // we are fairly certain the old node is dead now, since the new node is taking its place and has same address,
                // thus the channel is most likely pointing to an "already-dead" connection; we close it to cut off clean.
                //
                // we ignore the close-future, as it would not give us much here; could only be used to mark "we are still shutting down"
                _ = associated.channel.close()

            default:
                self.log.warning("Membership change indicated node replacement, yet no 'old' association found, this could happen if failure detection ")
            }
        }
        storeAssociation()

        return asm
    }

    mutating func removeAssociation() {
        return undefined()
    }

}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorSystem extensions

extension ActorSystem {

    internal var clusterShell: ActorRef<ClusterShell.Message> {
        return self._cluster?.ref ?? self.deadLetters.adapt(from: ClusterShell.Message.self)
    }

    // TODO not sure how to best expose, but for now this is better than having to make all internal messages public.
    public func join(address: NodeAddress) {
        self.clusterShell.tell(.command(.handshakeWith(address)))
    }

    // TODO not sure how to best expose, but for now this is better than having to make all internal messages public.
    public func _dumpAssociations() {
        let ref: ActorRef<Set<UniqueNodeAddress>> = try! self.spawnAnonymous(.receive { context, nodes in
            let stringlyNodes = nodes.map({ String(reflecting: $0) }).joined(separator: "\n     ")
            context.log.info("~~~~ ASSOCIATED NODES ~~~~~\n     \(stringlyNodes)")
            return .stopped
        })
        self.clusterShell.tell(.query(.associatedNodes(ref)))
    }

}

