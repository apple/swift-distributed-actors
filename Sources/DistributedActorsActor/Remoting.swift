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

// Actors engage in 'Networking' - the process of interacting with others to exchange information and develop contacts.

// MARK: Actor System Remoting Settings

public struct RemotingSettings {

    public static var `default`: RemotingSettings {
        return RemotingSettings(bindAddress: nil)
    }

    /// If not `nil` the system will attempt to bind to the provided address on startup.
    /// Once bound, the system is able to accept incoming connections.
    public var bindAddress: Remote.Address? {
        didSet {
            switch bindAddress {
            case .some(let addr):
                // TODO: had an idea to keep the UID stable once assigned...
                self._uniqueAddress = Remote.UniqueAddress(address: addr, uid: .random())
            case .none:
                self._uniqueAddress = nil
            }
        }
    }

    // Reflects the bindAddress however carries an uniquely assigned UID.
    // The UID remains the same throughout updates of the `bindAddress` field.
    private var _uniqueAddress: Remote.UniqueAddress?
    public var uniqueBindAddress: Remote.UniqueAddress? {
        return self._uniqueAddress
    }

    public init(bindAddress: Remote.Address?) {
        self.bindAddress = bindAddress
    }
}


// MARK: Internal Network Kernel, which owns and administers all connections of this system

extension RemotingKernel {

    /// Starts the `NetworkKernel` actor, if and only if a `bindAddress` is configured in `settings`.
    static func start(system: ActorSystem, settings: Swift Distributed ActorsActor.RemotingSettings) -> RemotingKernel.Ref? {
        guard settings.uniqueBindAddress != nil else {
            // no address to bind to
            return nil
        }


        // TODO prepare state already here?

        let kernel = RemotingKernel()

        return try! system._spawnSystemActor(
            kernel.behavior,
            name: "network",
            designatedUid: .opaque,
            props: kernel.props
        )
    }
}

internal class RemotingKernel {
    public typealias Ref = ActorRef<RemotingKernel.Messages>

    enum Messages {
        // case bind(Wire.Address) since binds right away from config settings
        case associate(Remote.Address)
        
        case handshakeOffer(Wire.HandshakeOffer)
        case handshake(Wire.HandshakeAccept)
        case handshakeFailed(with: NIO.SocketAddress?, Error)

//        // TODO this is internal protocol... how to hide it -- we need adapters I guess
//        case handshakeAccept(Network.HandshakeAccept)
//        case handshakeReject(Network.HandshakeReject)
        case inbound(NetworkInbound)

        case unbind // TODO some promise to complete once we unbound
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

    internal func bind() -> Behavior<Messages> {
        return .setup { context in
            let remotingSettings = context.system.settings.network
            let uniqueBindAddress = remotingSettings.uniqueBindAddress!

            // FIXME: all the ordering dance with creating of state and the address...
            context.log.info("Binding to: [\(remotingSettings.uniqueBindAddress!)]")

            let chanLogger = ActorLogger.make(system: context.system, identifier: "channel") // TODO better id
            let chanElf: EventLoopFuture<Channel> = self.bootstrapServerSide(kernel: context.myself, log: chanLogger, bindAddress: uniqueBindAddress, settings: remotingSettings)

            // FIXME: no blocking in actors ;-)
            let chan = try chanElf.wait() // FIXME: OH NO! terrible, awaiting the suspend/resume features to become Future<Behavior>
            context.log.info("Bound to \(chan.localAddress.map({ $0.description }) ?? "<no-local-address>")")

            let state = KernelState(remotingSettings: remotingSettings, channel: chan, log: context.log)

            return self.ready(state: state)
        }
    }

    // TODO: abstract into `Transport`
    fileprivate func ready(state: KernelState) -> Behavior<Messages> {
        return .receive { context, message in
            switch message {
            case .associate(let address):
                return try self.beginAssociating(state: state, address: address)

            case .inbound(let inbound): // TODO cleanup state machine, in ready perhaps we'd not want handshakes to complete, but only in "offered handshake"
                fatalError("SOME INBOUND DATA: \(inbound)")

            case .unbind:
                return self.unbind(state: state)

            case let .handshakeOffer(offer):
                return TODO("state.selfControl.associateWith: OFFER \(offer)") // TODO implement me
            case let .handshake(accepted):
                return TODO("state.selfControl.handshakeAccepted(from: accepted.from) ACC: \(accepted)") // TODO implement me
            case let .handshakeFailed(with, reason):
                context.log.warning("Association with \(String(describing: with)) was rejected! Reason: \(String(describing: reason))") // TODO better msg
                return TODO("Handle handshake failure \(with)    \(reason)") // TODO implement me
            }
        }
    }

    /// Initiate an outgoing handshake to the `address`
    ///
    /// Handshakes are currently not performed concurrently but one by one.
    fileprivate func beginAssociating(state: KernelState, address: Remote.Address) throws -> Behavior<Messages> {
        if let existingAssociation = state.association(with: address) {
            fatalError("We have on already... what now? Got \(existingAssociation) for \(address)")
        } else {
            state.log.info("Associating with \(address)...")

            var s = state // TODO so `inout state` I guess

            let clientChanElf: EventLoopFuture<Channel> = self.bootstrapClientSide(targetAddress: address, settings: state.remotingSettings)
            let clientChan = try! clientChanElf.wait() // FIXME super bad! blocking inside actor, oh no!

            let association = s.prepareAssociation(with: address, over: clientChan)

            // TODO separate the "do network stuff" from high level "write a handshake and expect a Ack/Nack back"


            // Implementation note: The general idea with control structures is that only those allow to send messages or similar.
            // If in a `...State` which does not offer us a `control` then we can't and must not attempt to send data.
            // We may want to fine tune which states offer what control structures.
            let offer = Wire.HandshakeOffer(version: state.protocolVersion, from: s.selfAddress, to: address)
            // let res = association.control.writeHandshake(offer: offer, allocator: state.allocator) // FIXME
            let res = association.control.writeHandshake(offer, allocator: state.allocator) // FIXME

            try res.wait() // FIXME no blocking at any time
            return ready(state: s)
        }
    }

    fileprivate func unbind(state: KernelState) -> Behavior<Messages> {
        let _ = state.channel.close(mode: .all)
        // TODO: pipe back to whomever requested the termination
        return .stopped // FIXME too eagerly
    }

}

// MARK: Data types

/// Connection errors should result in Disassociating with the offending system.
enum Swift Distributed ActorsConnectionError: Error {
    /// The first handshake bytes did not match the expected "magic bytes";
    /// It is very likely the other side attempting to connect to our port is NOT a Swift Distributed Actors system,
    /// thus we should reject it immediately. This can happen due to misconfiguration, e.g. mixing
    /// up ports and attempting to send HTTP or other data to a Swift Distributed Actors networking port.
    case illegalHandshakeMagic(was: UInt16, expected: UInt16) // TODO: Or [UInt8]...
    case illegalHandshake
}

extension Swift Distributed ActorsConnectionError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .illegalHandshakeMagic(let was, let expected):
            return ".illegalHandshakeMagic(was: \(was.hexString), expected: \(expected.hexString))"
        case .illegalHandshake:
            return ".illegalHandshake"
        }
    }
}

internal protocol NetworkInbound {
}

internal protocol NetworkOutbound {
}

/// Magic 2 byte value for use as initial bytes in connections (before handshake).
/// Reads as: `3AC7 == SACT == S Act == Swift Distributed Actors Act == Swift Distributed Actors Actors` (S can also stand for Swift)
internal let HandshakeMagicBytes: UInt16 = 0x3AC7

/// State of the `RemotingKernel` state machine
fileprivate struct KernelState {
    public var log: Logger

    let protocolVersion = Wire.Version(reserved: 0, major: 0, minor: 0, patch: 1)

    /// Unique address of the current node.
    public let selfAddress: Remote.UniqueAddress
    public let remotingSettings: Swift Distributed ActorsActor.RemotingSettings

    public let channel: Channel

    public var _control: Remote.Control
    public let allocator = NIO.ByteBufferAllocator() // FIXME take from config

    private var handshakesInProgress: [Wire.HandshakeOffer] = []
    private var associations: [Remote.Address: Remote.Association] = [:] // TODO currently also the in progress ones... once we get Unique Address of remote they are "done" hm hm

    init(remotingSettings: Swift Distributed ActorsActor.RemotingSettings, channel: Channel, log: Logger) {
        self.remotingSettings = remotingSettings
        guard let selfAddress = remotingSettings.uniqueBindAddress else {
            // should never happen, since we ONLY start the network kernel once when the bind address is set
            fatalError("Value of remotingSettings.uniqueBindAddress was nil, yet attempted to use network kernel. " +
                "This may be a Swift Distributed Actors bug, please report this on the issue tracker.")
        }
        self.selfAddress = selfAddress

        self.channel = channel
        self.log = log

        self._control = Remote.Control(log: log, channel: channel)
    }

    /// Control for "server side" of this node.
    @inlinable
    var selfControl: Remote.Control {
        return self._control
    }
    /// Obtain control of a `Remote.Association`.
    ///
    /// Only associations which have completed their handshake may be controlled.
    func control(of address: Remote.Address) -> Remote.AssociationControl? {
        return self.association(with: address)?.control
    }

    /// Prepares and stores (to be completed) association within current state.
    ///
    /// An association starts in the `.shakingHands` state until the associated with node
    /// accepts the handshake. Only when may
    mutating func prepareAssociation(with address: Remote.Address, over clientChan: Channel) -> Remote.Association {
//            // TODO more checks here, so we don't reconnect many times etc

        // Every association begins with us extending a handshake to the other node.
        let handshakeOffer = Wire.HandshakeOffer(version: self.protocolVersion, from: self.selfAddress, to: address)
        self.handshakesInProgress.append(handshakeOffer)
        // TODO fix that we create it in two spots...


        // TODO pass it `self` as well, so it can create values based on state
        let association = Remote.Association(log: Logging.make("association-to-\(address)"), state: .shakingHands, with: address, over: clientChan)
        self.associations[address] = association
        return association
    }

    mutating func completeAssociation() {
        return undefined()
    }

    mutating func removeAssociation() {
        return undefined()
    }

    func association(with address: Remote.Address) -> Remote.Association? {
        return self.associations[address]
    }
}


// TODO: Or "WireProtocol" or "Networking"
public enum Remote {

    // TODO: proper state machine as part of other ticket
    //    enum HandshakeState {
    //        case none
    //        case initiated(with: Address)
    //        case awaitingAck(until: Deadline)
    //        case accepted
    //    }

    struct Control {
        private let log: Logger

        // FIXME do we really need control over it here?
        private let channel: Channel

        // TODO now kept in state...
//        // Association ID to control for it
//        private let outbound: [Int: AssociationControl] = [:]

        init(log: Logger, channel: Channel) {
            self.log = log
            self.channel = channel
        }

        func close() -> EventLoopFuture<Void> {
            return self.channel.close()
        }
    }

    struct Association {
        enum State {
            case shakingHands // TODO: decide if we need "i extended the offer, or I am anticipating on it etc.."
            case complete
            case closed // TODO some tombstone... I want to avoid "quarantine" since the word is soooo misleading (quarantine can go away; such "ban that node" may never go away)
        }

        let log: Logger
        var state: Association.State

        let address: Address
        let control: AssociationControl
        // let channel: Channel // TODO make mutable since we may attempt to reconnect

        // TODO would want Association to always have UniqueAddress... so we need to model the "shaking hands" with something before that (see that list for in progress handshakes)
        var uniqueAddress: Remote.UniqueAddress? // TODO consider this modeling agian... Once we have Unique the association is useful
        let uid: Int64 = 0 // TODO maybe it is more efficient to key associations directly, and use this as key in the map? TODO

        init(log: Logger, state: Remote.Association.State, with address: Remote.Address, over chan: Channel) {
            self.log = log
            self.state = state
            self.address = address
            self.uniqueAddress = nil
            // let.channel = chan

            // TODO: make the log in there more specific (name)
            self.control = AssociationControl(log: self.log, channel: chan)
        }
    }

    class AssociationControl {
        let log: Logger
        let channel: Channel

        init(log: Logger, channel: Channel) {
            self.log = log
            self.channel = channel
        }

        // TODO since we are based on `state` we could create the appropriate offer here, no need to pass it in
        func writeHandshake(_ offer: Wire.HandshakeOffer, allocator: ByteBufferAllocator) -> EventLoopFuture<Void> {
            log.warning("Offering handshake [\(offer)]")
            let proto = ProtoHandshakeOffer(offer)
            log.warning("Offering handshake [\(proto)]")

            // TODO allow allocating into existing buffer
            var bytes = try! proto.serializedByteBuffer(allocator: allocator) // FIXME: serialization SHOULD be on dedicated part... put it into ELF already?
            var b = allocator.buffer(capacity: 4 + bytes.readableBytes)
            b.write(integer: HandshakeMagicBytes) // handshake must be prefixed with magic
            b.write(buffer: &bytes)

            let res = self.channel.writeAndFlush(b)

            res.whenFailure { err in
                pprint("Write[\(#function)] failed: \(err)")
            }
            res.whenSuccess { r in
                pprint("Write[\(#function)] success")
            }

            return res
        }

    }

    public struct Address: Hashable {
        let `protocol`: String = "sact" // TODO open up
        var systemName: String
        var host: String
        var port: UInt
    }

    public struct UniqueAddress: Hashable {
        let address: Address
        let uid: NodeUID // TODO ponder exact value here here
    }

    public struct NodeUID: Hashable {
        let value: UInt32 // TODO redesign / reconsider exact size

        public init(_ value: UInt32) {
            self.value = value
        }
    }
}

/// The wire protocol data types are namespaced using this enum.
///
/// When written onto they wire they are serialized to their transport specific formats (e.g. using protobuf or hand-rolled serializers).
/// These models are intentionally detached from their serialized forms.
public enum Wire {

    struct Envelope: NetworkInbound, NetworkOutbound {
        let version: Wire.Version

        // TODO recipient to contain address?
        var recipient: UniqueActorPath

        // TODO metadata
        // TODO "flags" incl. isSystemMessage

        var serializerId: Int
        var payload: ByteBuffer
    }

    /// Version of wire protocol used by the given node.
    ///
    /// TODO: Exact semantics remain to be defined.
    internal struct Version {
        var value: UInt32

        init(_ value: UInt32) {
            self.value = value
        }

        init(reserved: UInt8, major: UInt8, minor: UInt8, patch: UInt8) {
            var v: UInt32 = 0
            v += UInt32(reserved)
            v += UInt32(major) << 8
            v += UInt32(minor) << 16
            v += UInt32(patch) << 24
            self.value = v
        }

        var reserved: UInt8 {
            return UInt8(self.value >> 24)
        }
        var major: UInt8 {
            return UInt8((self.value >> 16) & 0b11111111)
        }
        var minor: UInt8 {
            return UInt8((self.value >> 8) & 0b11111111)
        }
        var patch: UInt8 {
            return UInt8(self.value & 0b11111111)
        }
    }

    // TODO: such messages should go over a priority lane
    internal struct HandshakeOffer: NetworkOutbound {
        internal var version: Version = Version.init(reserved: 0, major: 0, minor: 0, patch: 1) // TODO: get it for real

        internal var from: Remote.UniqueAddress
        internal var to: Remote.Address
    }

    // TODO: alternative namings: Ack/Nack or Accept/Reject... I'm on the fence here to be honest...
    internal struct HandshakeAccept: NetworkInbound {
        internal let version: Version = Version.init(reserved: 0, major: 0, minor: 0, patch: 1) // TODO: get it for real
        // TODO: Maybe offeringToSpeakAtVersion or something like that?
        internal let from: Remote.UniqueAddress

        init(from: Remote.UniqueAddress, to: Remote.Address) {
            self.from = from
        }
    }

    /// Negative. We can not establish an association with this node.
    internal struct HandshakeReject: NetworkInbound { // TODO: Naming bikeshed
        internal let version: Version = Version.init(reserved: 0, major: 0, minor: 0, patch: 1) // TODO: get it for real
        internal let reason: String?

        /// not an UniqueAddress, so we can't proceed into establishing an association - even by accident
        internal let from: Remote.Address

        init(from: Remote.Address, reason: String?) {
            self.from = from
            self.reason = reason
        }
    }

}

extension Remote.Address: CustomStringConvertible {
    public var description: String {
        return "\(`protocol`)://\(systemName)@\(host):\(port)"
    }
}

public extension Remote.NodeUID {
    static func random() -> Remote.NodeUID {
        return Remote.NodeUID(UInt32.random(in: 1 ... .max))
    }
}

extension Remote.NodeUID: Equatable {
}

// MARK: ActorSystem extensions

extension ActorSystem {

    var remoting: ActorRef<RemotingKernel.Messages> { // TODO only the "external ones"
        pprint("Trying to talk to network kernel; it is \(self._remoting)")
        // return self.networkKernel?.adapt(with: <#T##@escaping (From) -> Messages##@escaping (From) -> NetworkKernel.Messages#>) // TODO the adapting for external only protocol etc
        return self._remoting ?? self.deadLetters.adapt(from: RemotingKernel.Messages.self, with: { m in DeadLetter(m) })
    }

//    func join(_ nodeAddress: Wire.Address) {
//        guard let kernel = self.networkKernel else {
//            fatalError("NOPE. no networking possible if you yourself have no address") // FIXME
//        }
//
//        return kernel.tell(.join(nodeAddress))
//    }
}
