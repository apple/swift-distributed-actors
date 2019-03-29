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
// MARK: Internal Network Kernel, which owns and administers all connections of this system

/// The remoting kernel "drives" all internal state machines of the remoting subsystem. 
internal class RemotingKernel {
    public typealias Ref = ActorRef<RemotingKernel.Messages>

    // ~~~~~~ HERE BE DRAGONS, shared concurrently modified concurrent state !!!
    // We do this to avoid "looping" any initial access of an actor ref through the kernels mailbox
    // which would cause more latency to obtaining the association. refs cache the remote control once they have obtained it.

    private let _associationsLock: Lock

    /// Used by remote actor refs to obtain associations
    /// - Protected by: `_associationsLock`
    private var _associationsRegistry: [NodeUID: AssociationRemoteControl]

    // The `!` here is ok because we set the pool from the outside before starting
    // the remoting. Because of initialization order in the dependencies there is
    // currently no other way.
    internal var serializationPool: SerializationPool!

    internal func associationRemoteControl(with uid: NodeUID) -> AssociationRemoteControl? {
        return self._associationsLock.withLock {
            return self._associationsRegistry[uid]
        }
    }

    /// To be invoked by kernel actor whenever an association is made;
    /// The cache is used by remote actor refs to obtain means of sending messages into the pipeline,
    /// without having to queue through the remoting kernels mailbox.
    private func cacheAssociationRemoteControl(_ association: AssociationStateMachine.State) {
        switch association {
        case .associated(let assoc):
            self._associationsLock.withLockVoid {
                // TODO or association ID rather than the remote id?
                self._associationsRegistry[assoc.remoteAddress.uid] = assoc.makeRemoteControl()
            }
        // TODO: other cases could be if it is terminated , then we want to store the tombstone right away?
        }
    }
    
    // TODO `dead` associations could be moved on to a smaller map, like an optimized Int Set or something, to keep less space
    // END OF HERE BE DRAGONS, shared concurrently modified concurrent state !!!

    private var _ref: RemotingKernel.Ref?
    var ref: RemotingKernel.Ref {
        // since this is initiated during system startup, nil should never happen
        // TODO slap locks around it...
        guard let it = self._ref else {
            fatalError("Accessing RemotingKernel.ref failed, was nil!")
        }
        return it
    }

    // init(system: ActorSystem) throws {
    init() {
        self._associationsLock = Lock()
        self._associationsRegistry = [:]

        // not enjoying this dance, but this way we can share the RemotingKernel as the kernel AND the container for the ref.
        // the single thing in the class it will modify is the associations registry, which we do to avoid actor queues when
        // remote refs need to obtain those
        //
        // TODO see if we can restructure this to avoid these nil/then-set dance
        self._ref = nil
    }

    /// Actually starts the kernel actor which kicks off binding to a port, and all further remoting work
    internal func start(system: ActorSystem) throws -> RemotingKernel.Ref {
        // TODO concurrency... lock the ref as others may read it?
        self._ref = try system._spawnSystemActor(
            self.bind(),
            name: "remoting",
            props: self.props)
        
        return self.ref
    }

    // Due to lack of Union Types, we have to emulate them
    enum Messages: NoSerializationVerification {
        // The external API, exposed to users of the RemotingKernel
        case command(CommandMessage)
        // The external API, exposed to users of the RemotingKernel to query for state
        case query(QueryMessage)
        /// Messages internally driving the state machines; timeouts, network inbound events etc.
        case inbound(InboundMessage)
    }
    enum CommandMessage: NoSerializationVerification {
        // this is basically our API internally for this system

        // case bind(Wire.NodeAddress) since binds right away from config settings // TODO: Bind is done right away in start, should we do the bind command instead?
        case handshakeWith(NodeAddress)
        case unbind // TODO some promise to complete once we unbound
    } 
    enum QueryMessage: NoSerializationVerification {
        case associatedNodes(ActorRef<[UniqueNodeAddress]>) // TODO better type here
        // TODO: case subscribeAssociations(ActorRef<[UniqueNodeAddress]>) // to receive events about it one by one
    }
    internal enum InboundMessage {
        case handshakeOffer(Wire.HandshakeOffer, channel: Channel, replyTo: EventLoopPromise<ByteBuffer>) // TODO should be a domain object here
        case handshakeAccepted(Wire.HandshakeAccept, channel: Channel, replyTo: EventLoopPromise<Void>)
        case handshakeRejected(Wire.HandshakeReject, replyTo: EventLoopPromise<ByteBuffer>)
        case handshakeFailed(NodeAddress?, Error) // TODO remove?
    }

    private var behavior: Behavior<Messages> {
        return self.bind() // todo message self to bind?
    }

    private var props: Props =
        Props()
            .addingSupervision(strategy: .stop) // always fail completely (may revisit this)

}

// MARK: Kernel state: Bootstrap / Binding

extension RemotingKernel {

    /// Binds on setup to the configured address (as configured in `system.settings.remoting`).
    ///
    /// Once bound proceeds to `ready` state, where it remains to accept or initiate new handshakes.
    private func bind() -> Behavior<Messages> {
        return .setup { context in
            let remotingSettings = context.system.settings.remoting
            let uniqueBindAddress = remotingSettings.uniqueBindAddress

            // FIXME: all the ordering dance with creating of state and the address...
            context.log.info("Binding to: [\(uniqueBindAddress)]")

            let chanLogger = ActorLogger.make(system: context.system, identifier: "channel") // TODO better id
            let chanElf: EventLoopFuture<Channel> = self.bootstrapServerSide(system: context.system, kernel: context.myself, log: chanLogger, bindAddress: uniqueBindAddress, settings: remotingSettings, serializationPool: self.serializationPool)

            // TODO: configurable bind timeout?

            //  TODO crash everything, entire system, when bind fails
            return context.awaitResultThrowing(of: chanElf, timeout: .milliseconds(300)) { (chan: Channel) in
                context.log.info("Bound to \(chan.localAddress.map { $0.description } ?? "<no-local-address>")")
                
                let state = KernelState(settings: remotingSettings, channel: chan, log: context.log)

                return self.ready(state: state)
            }
        }
    }

    /// Ready and interpreting commands and incoming messages.
    ///
    /// Serves as main "driver" for handshake and association state machines.
    private func ready(state: KernelState) -> Behavior<Messages> {
        func receiveKernelCommand(context: ActorContext<Messages>, command: CommandMessage) -> Behavior<Messages> {
            switch command {
            case .handshakeWith(let remoteAddress):
                return self.beginHandshake(context, state, with: remoteAddress)
            case .unbind:
                return self.unbind(state: state)
            }
        }

        func receiveQuery(context: ActorContext<Messages>, query: QueryMessage) -> Behavior<Messages> {
            switch query {
            case .associatedNodes(let replyTo):
                replyTo.tell(state.associatedAddresses()) // TODO: we'll want to put this into some nicer message wrapper?
                return .same
            }
        }

        func receiveInbound(context: ActorContext<Messages>, message: InboundMessage) throws -> Behavior<Messages> {
            switch message {
            case .handshakeOffer(let offer, let channel, let promise):
                return self.onHandshakeOffer(state, offer, channel: channel, replyInto: promise)
            case .handshakeAccepted( let accepted, let channel, let promise):
                return self.onHandshakeAccepted(state, accepted, channel: channel, replyInto: promise)
            case .handshakeRejected(let rejected, let promise):
                return self.onHandshakeRejected(state, rejected, replyInto: promise)
            case .handshakeFailed(_, let error):
                // return self.onHandshakeFailed(state, rejected) // FIXME implement this basically disassociate() right away?
                return FIXME("HANDSHAKE FAILED: [\(error)]:\(type(of: error))") // FIXME: handshake reject should be implemented
            }
        }

        // TODO: would be nice with some form of subReceive...
        return .receive { context, message in
            switch message {
            case .command(let command): return receiveKernelCommand(context: context, command: command)
            case .query(let query):     return receiveQuery(context: context, query: query)
            case .inbound(let inbound): return try receiveInbound(context: context, message: inbound)
            }
        }
    }
}

// Implements: Handshake init
extension RemotingKernel {
    /// Initiate an outgoing handshake to the `address`
    ///
    /// Handshakes are currently not performed concurrently but one by one.
    private func beginHandshake(_ context: ActorContext<Messages>, _ state: KernelState, with remoteAddress: NodeAddress) -> Behavior<Messages> {
        var state = state

        if let existingAssociation = state.association(with: remoteAddress) {
            // TODO in reality should attempt and may need to drop the other "old" one?
            state.log.warning("Attempted associating with already associated node: [\(remoteAddress)], existing association: [\(existingAssociation)]")
            return .same
        }

        state.log.info("Initiating handshake with \(remoteAddress)...")

        // we MUST register the intention of shaking hands with remoteAddress before obtaining the connection,
        // in order to let the fsm handle any retry decisions in face of connection failures et al.
        let hsm = state.makeHandshake(with: remoteAddress)

        // TODO make sure we never to multiple connections to the same remote; associations must get IDs?
        // TODO: This is rather costly... we should not have to stop processing other messages until the connect completes;
        //       change this so we can connect to many hosts in parallel
        let outboundChanElf: EventLoopFuture<Channel> = self.bootstrapClientSide(
            system: context.system,
            kernel: context.myself,
            log: context.log,
            targetAddress: remoteAddress,
            settings: state.settings,
            serializationPool: self.serializationPool
        )

        return context.awaitResult(of: outboundChanElf, timeout: .milliseconds(100)) {
            switch $0 {
            case .success(let outboundChan):
                // Initialize and store a new Handshake FSM for this dance
                // And ask it to create a handshake offer
                let offer = hsm.makeOffer()

                _ = self.sendHandshakeOffer(state, offer, over: outboundChan) // TODO move to Promise style, rather than passing channel

                return self.ready(state: state)

            case .failure(let error):
                return self.onOutboundConnectionError(context, state, with: remoteAddress, error: error)
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Sending wire protocol messages

extension RemotingKernel {
    
    // TODO: Move this to instead use the replyInto pattern (and then we eventually move those to domain objects as we do the serialization pipeline)
    private func sendHandshakeOffer(_ state: KernelState, _ offer: Wire.HandshakeOffer, over channel: Channel) -> EventLoopFuture<Void> {
        let proto = ProtoHandshakeOffer(offer)
        traceLog_Remote("Offering handshake [\(proto)]")

        do {
            let allocator = state.allocator // TODO move this off onto the serialization pipeline

            // TODO allow allocating into existing buffer
            // FIXME: serialization SHOULD be on dedicated part... put it into ELF already?
            let bytes: ByteBuffer = try proto.serializedByteBuffer(allocator: allocator)
            // TODO should we use the serialization infra ourselves here? I guess so...
            
            // FIXME make the promise dance here
            return channel.writeAndFlush(bytes)
        } catch {
            // TODO change since serialization which can throw should be shipped of to a future
            // ---- since now we blocked the actor basically with the serialization
            return state.eventLoopGroup.next().makeFailedFuture(error)
        }
    }

    // TODO: pass around a more limited state -- just what is needed for the sending of stuff
    private func sendHandshakeAccept(_ state: KernelState, _ accept: Wire.HandshakeAccept, replyInto: EventLoopPromise<ByteBuffer>) {
        let allocator = state.allocator
        
        let proto = ProtoHandshakeAccept(accept)
        traceLog_Remote("Accepting handshake: [\(proto)]")

        do {
            // TODO this does much copying;
            // TODO should be sent through pipeline where we do the serialization thingies
            let bytes = try proto.serializedByteBuffer(allocator: allocator)

            replyInto.succeed(bytes)
        } catch {
            replyInto.fail(error)
        }
    }
}

// Implements: Incoming Handshake
extension RemotingKernel {
    
    /// Initial entry point for accepting a new connection; Potentially allocates new handshake state machine.
    private func onHandshakeOffer(_ state: KernelState, _ offer: Wire.HandshakeOffer, channel: Channel, replyInto promise: EventLoopPromise<ByteBuffer>) -> Behavior<Messages> {
        var newState = state
        let log = state.log

        if let hsm = newState.incomingHandshake(offer: offer) {
            // handshake is allowed to proceed; TODO: semantics; what if we already have one in progress; we could return this rather than this if/else
            log.info("Negotiating handshake...")
            switch hsm.negotiate() {
            case .acceptAndAssociate(let completedHandshake):
                log.info("Accept association with \(offer.from)!")
                let association = newState.associate(completedHandshake, channel: channel)
                self.cacheAssociationRemoteControl(association)
                _ = self.sendHandshakeAccept(newState, completedHandshake.makeAccept(), replyInto: promise)
                return self.ready(state: newState) // TODO change the state

            case .rejectHandshake(let error):
                log.info("Rejecting handshake from \(offer.from)! Error: \(error)")
                return self.ready(state: newState) // TODO change the state

            case .goAwayRogueHandshake(let error):
                log.warning("Rogue handshake! Reject, reject! From \(offer.from)! Error: \(error)")
                return self.ready(state: newState) // TODO change the state
            }
        } else {
            log.warning("Ignoring handshake offer \(offer), no state machine available for it...")
            return .ignore
        }
    }
}


// Implements: Failures to obtain connections
extension RemotingKernel {

    func onOutboundConnectionError(_ context: ActorContext<Messages>, _ state: KernelState, with remoteAddress: NodeAddress, error: Error) -> Behavior<Messages> {
        var state = state
        state.log.warning("Failed await for outbound channel to \(remoteAddress); Error was: \(error)")

        guard var handshakeState = state.handshakeInProgress(with: remoteAddress) else {
            state.log.warning("Connection error for handshake which is not in progress, this should not happen, but is harmless.") // TODO meh or fail hard
            return .ignore
        }

        switch handshakeState {
        case .initiated(var hsm):
            switch hsm.onHandshakeError(error) {
            case .scheduleRetryHandshake(let offer, let delay):
                state.log.info("Schedule retry handshake: [\(offer)], delay: [\(delay)]")
                context.timers.startSingleTimer(
                    key: "handshake-timer-\(remoteAddress)", 
                    // message: .command(.retryHandshakeWith(remoteAddress)), // TODO better?
                    message: .command(.handshakeWith(remoteAddress)),
                    delay: delay
                )
            case .giveUpHandshake:
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
extension RemotingKernel {
    private func onHandshakeAccepted(_ state: KernelState, _ accept: Wire.HandshakeAccept, channel: Channel, replyInto promise: EventLoopPromise<Void>) -> Behavior<Messages> {
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

        state.log.debug("[Remoting] Associated with: \(completed.remoteAddress).")
        self.cacheAssociationRemoteControl(association)
        promise.succeed(())
        return self.ready(state: state)
    }

    private func onHandshakeRejected(_ state: KernelState, _ reject: Wire.HandshakeReject, replyInto promise: EventLoopPromise<ByteBuffer>) -> Behavior<Messages> {
        return TODO("onHandshakeRejected")
    }
}


// Implements: Unbind
extension RemotingKernel {

    fileprivate func unbind(state: KernelState) -> Behavior<Messages> {
        let _ = state.channel.close(mode: .all)
        // TODO: pipe back to whomever requested the termination
        return .stopped // FIXME too eagerly
    }
}

// MARK: Data types

/// Connection errors should result in Disassociating with the offending system.
enum SwiftDistributedActorsProtocolError: Error {
    case illegalHandshake(reason: Error)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Kernel State

internal protocol ReadOnlyKernelState {
    var log: Logger { get }
    var allocator: ByteBufferAllocator { get }
    var eventLoopGroup: EventLoopGroup { get } // TODO or expose the MultiThreaded one...?

    /// Unique address of the current node.
    var localAddress: UniqueNodeAddress { get }
    var settings: RemotingSettings { get }
}

/// State of the `RemotingKernel` state machine
internal struct KernelState: ReadOnlyKernelState {
    typealias Messages = RemotingKernel.Messages

    // TODO maybe move log and settings outside of state into the kernel?
    public var log: Logger
    public let settings: RemotingSettings

    public let localAddress: UniqueNodeAddress

    public let channel: Channel
    public let eventLoopGroup: EventLoopGroup

    public let allocator: ByteBufferAllocator

    private var _handshakes: [NodeAddress: HandshakeStateMachine.State] = [:]
    private var _associations: [NodeAddress: AssociationStateMachine.State] = [:]

    init(settings: RemotingSettings, channel: Channel, log: Logger) {
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

    func associatedAddresses() -> [UniqueNodeAddress] {
        return self._associations.values.map { asm -> UniqueNodeAddress in
            switch asm {
            case .associated(let state): return state.remoteAddress
            }
        }
    }
    func handshakes() -> [HandshakeStateMachine.State] {
        return self._handshakes.values.map { hsm -> HandshakeStateMachine.State in
            return hsm
        }
    }
}

extension KernelState {

    /// This is the entry point for a client initiating a handshake with a remote node.
    mutating func makeHandshake(with address: NodeAddress) -> HandshakeStateMachine.InitiatedState {
        // TODO more checks here, so we don't reconnect many times etc

        let handshakeFsm = HandshakeStateMachine.initialClientState(kernelState: self, connectTo: address)
        let handshakeState = HandshakeStateMachine.State.initiated(handshakeFsm)
        self._handshakes[address] = handshakeState
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
            let fsm = HandshakeStateMachine.HandshakeReceivedState(kernelState: self, offer: offer)
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
    mutating func associate(_ handshake: HandshakeStateMachine.CompletedState, channel: Channel) -> AssociationStateMachine.State {
        guard self._handshakes.removeValue(forKey: handshake.remoteAddress.address) != nil else {
            fatalError("BOOM: Can't complete a handshake which was not in progress!") // throw HandshakeError.acceptAttemptForNotInProgressHandshake(handshake)
            // TODO perhaps we instead just warn and ignore this; since it should be harmless
        }

        // FIXME: wrong channel?
        let asm = AssociationStateMachine.AssociatedState(fromCompleted: handshake, log: self.log, over: channel)
        let state: AssociationStateMachine.State = .associated(asm)
        self._associations[handshake.remoteAddress.address] = state
        return state
    }

    mutating func removeAssociation() {
        return undefined()
    }


}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorSystem extensions

extension ActorSystem {

    internal var remoting: ActorRef<RemotingKernel.Messages> {
        return self._remoting?.ref ?? self.deadLetters.adapt(from: RemotingKernel.Messages.self)
    }

    // TODO MAYBE 
//    func join(_ nodeAddress: Wire.NodeAddress) {
//        guard let kernel = self.RemotingKernel else {
//            fatalError("NOPE. no networking possible if you yourself have no address") // FIXME
//        }
//
//        return kernel.tell(.join(nodeAddress))
//    }
}

