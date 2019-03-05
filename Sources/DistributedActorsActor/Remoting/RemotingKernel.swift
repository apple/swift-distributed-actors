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

// MARK: Internal Network Kernel, which owns and administers all connections of this system

extension RemotingKernel {

    /// Starts the `RemotingKernel` actor if enabled, otherwise returns `nil` rather than the kernel ref.
    static func start(system: ActorSystem, settings: RemotingSettings) -> RemotingKernel.Ref? {
        guard settings.enabled else {
            return nil
        }

        let kernel = RemotingKernel()

        // try! safe: considered safe here; only 2 cases exist when it could fail:
        //   a) when the path is illegal (and we know "remoting" is valid)
        //   b) when the kernel is attempted to start a second time, in which case this is very-bad™ and we want a backtrace.
        //      This would be a Swift Distributed Actors bug; since the system starts remoting and shall never do so multiple times.
        do {
            return try system._spawnSystemActor(
                kernel.behavior,
                name: "remoting",
                props: kernel.props
            )
        } catch {
            fatalError("Starting remoting kernel (/system/remoting) failed. This is potentially a bug, please open a ticket. Error was: \(error)")
        }
    }

}

/// The remoting kernel "drives" all internal state machines of the remoting subsystem. 
internal class RemotingKernel {
    public typealias Ref = ActorRef<RemotingKernel.Messages>

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

        // case bind(Wire.NodeAddress) since binds right away from config settings
        case handshakeWith(NodeAddress)
        case unbind // TODO some promise to complete once we unbound
    } 
    enum QueryMessage: NoSerializationVerification {
        case associatedNodes(ActorRef<[UniqueNodeAddress]>) // TODO better type here
        // TODO: case subscribeAssociations(ActorRef<[UniqueNodeAddress]>) // to receive events about it one by one
    }
    internal enum InboundMessage {
        case handshakeOffer(Wire.HandshakeOffer, replyTo: EventLoopPromise<ByteBuffer>) // TODO should be a domain object here
        case handshakeAccepted(Wire.HandshakeAccept, replyTo: EventLoopPromise<ByteBuffer>)
        case handshakeRejected(Wire.HandshakeReject, replyTo: EventLoopPromise<ByteBuffer>)
        case handshakeFailed(NodeAddress?, Error) // TODO remove?
//        case inbound(NetworkInbound)
    }

    internal var behavior: Behavior<Messages> {
        return self.bind() // todo message self to bind?
    }

    internal var props: Props {
        return Props().addSupervision(strategy: .stop) // TODO "when this dies everything dies"
    }

}

// MARK: Kernel state: Bootstrap / Binding

extension RemotingKernel {

    /// Binds on setup to the configured address (as configured in `system.settings.remoting`).
    ///
    /// Once bound proceeds to `ready` state, where it remains to accept or initiate new handshakes.
    internal func bind() -> Behavior<Messages> {
        return .setup { context in
            let remotingSettings = context.system.settings.remoting
            let uniqueBindAddress = remotingSettings.uniqueBindAddress

            // FIXME: all the ordering dance with creating of state and the address...
            context.log.info("Binding to: [\(uniqueBindAddress)]")

            let chanLogger = ActorLogger.make(system: context.system, identifier: "channel") // TODO better id
            let chanElf: EventLoopFuture<Channel> = self.bootstrapServerSide(kernel: context.myself, log: chanLogger, bindAddress: uniqueBindAddress, settings: remotingSettings)

            // TODO: configurable bind timeout?

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
    fileprivate func ready(state: KernelState) -> Behavior<Messages> {
        func receiveKernelCommand(context: ActorContext<Messages>, command: CommandMessage) -> Behavior<Messages> {
            switch command {
            case .handshakeWith(let remoteAddress):
                // TODO extract into single method
                //                context.log.info("Bootstrapping client side NIO.....")
                //                let chanElf = self.bootstrapClientSide(targetAddress: remoteAddress, settings: state.settings)
                //                context.log.info("Channel elf waiting.....")
                //                return context.awaitResultThrowing(of: chanElf, timeout: .milliseconds(300)) { chan in
                //                    self.initiateHandshake(context, state, with: remoteAddress)
                //                }
                return self.initiateHandshake(context, state, with: remoteAddress)
            case .unbind:
                return self.unbind(state: state)
            }
        }

        func receiveKernelQuery(context: ActorContext<Messages>, query: QueryMessage) -> Behavior<Messages> {
            switch query {
            case .associatedNodes(let replyTo):
                replyTo.tell(state.associatedAddresses()) // TODO: we'll want to put this into some nicer message wrapper?
                return .same
            }
        }

        func receiveInbound(context: ActorContext<Messages>, message: InboundMessage) throws -> Behavior<Messages> {
            switch message {
            case .handshakeOffer(let offer, let promise):
                return self.onHandshakeOffer(state, offer, replyInto: promise)
            case .handshakeAccepted( let accepted, let promise):
                return self.onHandshakeAccepted(state, accepted, replyInto: promise)
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
            case .query(let query):     return receiveKernelQuery(context: context, query: query)
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
    func initiateHandshake(_ context: ActorContext<Messages>, _ state: KernelState, with remoteAddress: NodeAddress) -> Behavior<Messages> {
        if let existingAssociation = state.association(with: remoteAddress) {
            // TODO in reality should attempt and may need to drop the other "old" one?
            state.log.warning("Attempted associating with already associated node: [\(remoteAddress)], existing association: [\(existingAssociation)]")
            return .same
        }

        var nextState = state
        nextState.log.info("Associating with \(remoteAddress)...")

        // TODO: This is rather costly... we should not have to stop processing other messages until the connect completes; change this so we can connect to many hosts in parallel
        let outboundChanElf: EventLoopFuture<Channel> = self.bootstrapClientSide(kernel: context.myself, log: context.log, targetAddress: remoteAddress, settings: state.settings)
        return context.awaitResult(of: outboundChanElf, timeout: .milliseconds(100)) { outboundChanRes in
            switch outboundChanRes {
            case .failure(let err):
                state.log.error("Failed to connect to \(remoteAddress), error was: \(err)")
                throw err

            case .success(let outboundChan):
                // Initialize and store a new Handshake FSM for this dance
                let handshakeFsm = nextState.initiateHandshake(with: remoteAddress)
                // And ask it to create a handshake offer
                let offer = handshakeFsm.makeOffer()
                
                _ = self.sendHandshakeOffer(state, offer, over: outboundChan) // TODO move to Promise style, rather than passing channel
                
                return self.ready(state: nextState)
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Sending wire protocol messages

extension RemotingKernel {
    
    // TODO: Move this to instead use the replyInto pattern (and then we eventually move those to domain objects as we do the serialization pipeline)
    func sendHandshakeOffer(_ state: KernelState, _ offer: Wire.HandshakeOffer, over channel: Channel) -> EventLoopFuture<Void> {
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
            return state.eventLoopGroup.next().newFailedFuture(error: error)
        }
    }

    // TODO: pass around a more limited state -- just what is needed for the sending of stuff
    func sendHandshakeAccept(_ state: KernelState, _ accept: Wire.HandshakeAccept, replyInto: EventLoopPromise<ByteBuffer>) {
        let allocator = state.allocator
        
        let proto = ProtoHandshakeAccept(accept)
        traceLog_Remote("Accepting handshake: [\(proto)]")

        do {
            // TODO this does much copying;
            // TODO should be send through pipeline where we do the serialization thingies
            let bytes = try proto.serializedByteBuffer(allocator: allocator)

            replyInto.succeed(result: bytes)
        } catch {
            replyInto.fail(error: error)
        }
    }
}

// Implements: Incoming Handshake
extension RemotingKernel {
    
    /// Initial entry point for accepting a new connection; Potentially allocates new handshake state machine.
    func onHandshakeOffer(_ state: KernelState, _ offer: Wire.HandshakeOffer, replyInto promise: EventLoopPromise<ByteBuffer>) -> Behavior<Messages> {
        var newState = state
        let log = state.log 

        // TODO implement as directives from the state machine

        if let hsm = newState.incomingHandshake(offer: offer) {
            // handshake is allowed to proceed; TODO: semantics; what if we already have one in progress; we could return this rather than this if/else
            log.info("Negotiating handshake...")
            switch hsm.negotiate() {
            case .acceptAndAssociate(let completedHandshake):
                log.info("Accept association with \(offer.from)!")
                let association = newState.associate(completedHandshake)
                _ = self.sendHandshakeAccept(newState, completedHandshake.makeAccept(), replyInto: promise)
                return self.ready(state: newState) // TODO change the state

            case .rejectHandshake:
                log.info("Rejecting handshake from \(offer.from)!")
                return self.ready(state: newState) // TODO change the state

            case .rogueHandshakeGoAway:
                log.warning("Rogue handshake! Reject, reject! From \(offer.from)!")
                return self.ready(state: newState) // TODO change the state
            }
        } else {
            log.warning("Ignoring handshake offer \(offer), no state machine available for it...")
            return .ignore
        }
    }
}

// Implements: Incoming Handshake Replies
extension RemotingKernel {
    func onHandshakeAccepted(_ state: KernelState, _ accept: Wire.HandshakeAccept, replyInto promise: EventLoopPromise<ByteBuffer>) -> Behavior<Messages> {
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

        let association = state.associate(completed)

        state.log.debug("[Remoting] Associated with: \(completed.remoteAddress).")
        return self.ready(state: state)
    }

    func onHandshakeRejected(_ state: KernelState, _ reject: Wire.HandshakeReject, replyInto promise: EventLoopPromise<ByteBuffer>) -> Behavior<Messages> {
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
    var selfAddress: UniqueNodeAddress { get }
    var settings: RemotingSettings { get }
}

/// State of the `RemotingKernel` state machine
internal struct KernelState: ReadOnlyKernelState {
    typealias Messages = RemotingKernel.Messages

    // TODO maybe move log and settings outside of state into the kernel?
    public var log: Logger
    public let settings: RemotingSettings

    public let selfAddress: UniqueNodeAddress

    public let channel: Channel
    public let eventLoopGroup: EventLoopGroup

    public let allocator: ByteBufferAllocator

    private var _handshakes: [NodeAddress: HandshakeStateMachine.State] = [:]
    private var _associations: [NodeAddress: AssociationStateMachine.State] = [:]

    init(settings: RemotingSettings, channel: Channel, log: Logger) {
        self.settings = settings
        self.allocator = settings.allocator

        self.eventLoopGroup = settings.eventLoopGroup ?? settings.makeDefaultEventLoopGroup()

        self.selfAddress = settings.uniqueBindAddress

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
    mutating func initiateHandshake(with address: NodeAddress) -> HandshakeStateMachine.InitiatedState {
        // TODO more checks here, so we don't reconnect many times etc

        let handshakeFsm = HandshakeStateMachine.InitiatedState(kernelState: self, remoteAddress: address)
        let handshakeState = HandshakeStateMachine.State.initiated(handshakeFsm)
        self._handshakes[address] = handshakeState
        return handshakeFsm
    }
    
    /// This is the entry point for a server receiving a handshake with a remote node.
    /// Inspects and possibly allocates a `HandshakeStateMachine` in the `HandshakeReceivedState` state.
    mutating func incomingHandshake(offer: Wire.HandshakeOffer) -> HandshakeStateMachine.HandshakeReceivedState? { // TODO return directives to act on
        if let inProgressHandshake = self._handshakes[offer.from.address] {
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
            return nil
        }
    }

    /// "Upgrades" a connection with a remote node from handshaking state to associated.
    /// Stores an `Association` for the newly established association;
    mutating func associate(_ handshake: HandshakeStateMachine.CompletedState) -> AssociationStateMachine.State {
        guard let removedHandshake = self._handshakes.removeValue(forKey: handshake.remoteAddress.address) else {
            fatalError("BOOM: Can't complete a handshake which was not in progress!") // throw HandshakeError.acceptAttemptForNotInProgressHandshake(handshake)
            // TODO perhaps we instead just warn and ignore this; since it should be harmless
        }

        // FIXME: wrong channel?
        let asm = AssociationStateMachine.AssociatedState(fromCompleted: handshake, log: self.log, over: self.channel)
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

    var remoting: ActorRef<RemotingKernel.Messages> { // TODO only the "external ones"
        // return self.RemotingKernel?.adapt(with: <#T##@escaping (From) -> Messages##@escaping (From) -> RemotingKernel.Messages#>) // TODO the adapting for external only protocol etc
        return self._remoting ?? self.deadLetters.adapt(from: RemotingKernel.Messages.self, with: { m in DeadLetter(m) })
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

