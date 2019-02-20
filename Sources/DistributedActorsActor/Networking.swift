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
import SwiftProtobuf // TODO don't want protobufs present in this file

// Actors engage in 'Networking' - the process of interacting with others to exchange information and develop contacts.

// MARK: Actor System Network Settings

public struct NetworkSettings {

    public static var `default`: NetworkSettings {
        return NetworkSettings(bindAddress: nil)
    }

    /// If not `nil` the system will attempt to bind to the provided address on startup.
    /// Once bound, the system is able to accept incoming connections.
    public var bindAddress: Network.Address? {
        didSet {
            switch bindAddress {
            case .some(let addr):
                // TODO: had an idea to keep the UID stable once assigned...
                self._uniqueAddress = Network.UniqueAddress(address: addr, uid: .random())
            case .none:
                self._uniqueAddress = nil
            }
        }
    }

    // Reflects the bindAddress however carries an uniquely assigned UID.
    // The UID remains the same throughout updates of the `bindAddress` field.
    private var _uniqueAddress: Network.UniqueAddress?
    public var uniqueBindAddress: Network.UniqueAddress? {
        return self._uniqueAddress
    }

    public init(bindAddress: Network.Address?) {
        self.bindAddress = bindAddress
    }
}


// MARK: Internal Network Kernel, which owns and administers all connections of this system

extension NetworkKernel {

    /// Starts the `NetworkKernel` actor, if and only if a `bindAddress` is configured in `settings`.
    static func start(system: ActorSystem, settings: Swift Distributed ActorsActor.NetworkSettings) -> NetworkKernel.Ref? {
        guard let bindAddress = settings.uniqueBindAddress else {
            // no address to bind to
            return nil
        }


        // TODO prepare state already here?

        let kernel = NetworkKernel()

        return try! system._spawnSystemActor(
            kernel.behavior,
            name: "network",
            designatedUid: .opaque,
            props: kernel.props
        )
    }
}

internal class NetworkKernel {
    public typealias Ref = ActorRef<NetworkKernel.Messages>

    enum Messages {
        // case bind(Network.Address) since binds right away from config settings
        case associate(Network.Address)

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

extension NetworkKernel {

    internal func bind() -> Behavior<Messages> {
        return .setup { context in
            let networkSettings = context.system.settings.network
            let uniqueBindAddress = networkSettings.uniqueBindAddress!

            // FIXME: all the ordering dance with creating of state and the address...
            context.log.info("Binding to: [\(networkSettings.uniqueBindAddress!)]")

            let chanElf: EventLoopFuture<Channel> = self.bootstrapServerSide(bindAddress: uniqueBindAddress, settings: networkSettings)
//            chanElf.map { channel in
//                return self.bound(channel)
//            }

            // FIXME: no blocking in actors ;-)
            let chan = try chanElf.wait() // FIXME: OH NO! terrible, awaiting the suspend/resume features to become Future<Behavior>
            context.log.info("Bound to \(chan.localAddress.map({ $0.description }) ?? "<no-local-address>")")

            let state = Network.KernelState(networkSettings: networkSettings, channel: chan, log: context.log)

            return self.ready(state: state)
        }
    }

    // TODO: abstract into `Transport`
    internal func ready(state: Network.KernelState) -> Behavior<Messages> {
        return .receiveMessage { message in
            switch message {
            case .associate(let address):
                return self.associate(state: state, address: address)

            case .inbound(let inbound): // TODO cleanup state machine, in ready perhaps we'd not want handshakes to complete, but only in "offered handshake"
                fatalError("SOME INBOUND DATA: \(inbound)")

            case .unbind:
                return self.unbind(state: state)
            }
        }
    }

    /// Initiate an outgoing handshake to the `address`
    ///
    /// Handshakes are currently not performed concurrently but one by one.
    internal func associate(state: Network.KernelState, address: Network.Address) -> Behavior<Messages> {
        if let existingAssociation = state.association(with: address) {
            fatalError("We have on already... what now? Got \(existingAssociation) for \(address)")
        } else {
            state.log.info("Associating with \(address)...")

            var s = state // TODO so `inout state` I guess
            let handshakeOffer = s.prepareAssociation(with: address)

            let chanElf: EventLoopFuture<Channel> = self.bootstrapClientSide(targetAddress: address, settings: state.networkSettings)
            let channel = try! chanElf.wait() // FIXME super bad blocking inside actor
            state.log.info("outgoing channel \(channel)")

            var b = state.allocator.buffer(capacity: "HELLO".utf8.count)
            b.write(string: "HELLO")
            try! channel.writeAndFlush(b).wait()


            // TODO separate the "do network stuff" from high level "write a handshake and expect a Ack/Nack back"
            // TODO: control.sendHandshakeOffer()
//            let res = s.control.writeHandshake(handshakeOffer, allocator: state.allocator)

            return ready(state: s)
        }
    }

    internal func unbind(state: Network.KernelState) -> Behavior<Messages> {
        let _ = state.channel.close(mode: .all)
        // TODO: pipe back to whomever requested the termination
        return .stopped // FIXME too eagerly
    }

}

// MARK: Data types

/// Connection errors should result in Disassociating with the offending system.
internal enum Swift Distributed ActorsConnectionError: Error {
    /// The first handshake bytes did not match the expected "magic bytes";
    /// It is very likely the other side attempting to connect to our port is NOT a Swift Distributed Actors system,
    /// thus we should reject it immediately. This can happen due to misconfiguration, e.g. mixing
    /// up ports and attempting to send HTTP or other data to a Swift Distributed Actors networking port.
    case illegalHandshakeMagic(was: UInt32, expected: UInt32) // TODO: Or [UInt8] of length 4...
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

internal protocol NetworkInbound {}
internal protocol NetworkOutbound {}

/// Magic 4 byte value for use as initial bytes in connections (before handshake).
/// Reads as: `3AC7 == SACT == Swift Distributed ActorsActors`
internal let NetworkHandshakeMagicBytes: UInt32 = 0x3AC7

// TODO: Or "WireProtocol" or "Networking"
public enum Network {

    struct KernelState {
        public var log: Logger

        /// Unique address of the current node.
        public let address: UniqueAddress
        public let networkSettings: Swift Distributed ActorsActor.NetworkSettings

        public let channel: Channel

        public var control: Control
        public let allocator = NIO.ByteBufferAllocator() // FIXME take from config

        var handshakesInProgress: [HandshakeOffer] = []
        var associations: [Association] = []

        init(networkSettings: Swift Distributed ActorsActor.NetworkSettings, channel: Channel, log: Logger) {
            self.networkSettings = networkSettings
            guard let selfAddress = networkSettings.uniqueBindAddress else {
                // should never happen, since we ONLY start the network kernel once when the bind address is set
                fatalError("Value of networkSettings.uniqueBindAddress was nil, yet attempted to use network kernel. " + 
                    "This may be a Swift Distributed Actors bug, please report this on the issue tracker.")
            }
            self.address = selfAddress

            self.channel = channel
            self.log = log

            self.control = Control(log: log, channel: channel)
        }

        mutating func prepareAssociation(with address: Address) -> HandshakeOffer {
            // TODO more checks here, so we don't reconnect many times etc
            // Every association begins with us extending a handshake to the other node.
            let handshakeOffer = HandshakeOffer(from: self.address, to: address)

            self.handshakesInProgress.append(handshakeOffer)
            return handshakeOffer
        }
        mutating func completeAssociation() {}
        mutating func removeAssociation() {}

        func association(with: Address) -> Association? {
            return nil // FIXME
        }
    }

    // TODO: proper state machine as part of other ticket
    //    enum HandshakeState {
    //        case none
    //        case initiated(with: Address)
    //        case awaitingAck(until: Deadline)
    //        case accepted
    //    }

    class Control {
        private let log: Logger

        // FIXME do we really need control over it here?
        private let channel: Channel

        // Association ID to control for it
        private let outbound: [Int: AssociationControl] = [:]


        init(log: Logger, channel: Channel) {
            self.log = log
            self.channel = channel
        }
    }

    class AssociationControl {
        let log: Logger
        let outboundChannel: Channel

        init(log: Logger, outboundChannel: Channel) {
            self.log = log
            self.outboundChannel = outboundChannel
        }

        func writeHandshake(_ offer: HandshakeOffer, allocator: ByteBufferAllocator) -> EventLoopFuture<Void> {
            log.warning("Offering handshake [\(offer)]")
            let proto = ProtoHandshake(offer)
            log.warning("Offering handshake [\(proto)]")
            let bytes = try! proto.serializedByteBuffer(allocator: allocator) // FIXME: serialization SHOULD be on dedicated part... put it into ELF already?

            let res = self.outboundChannel.writeAndFlush(bytes) // TODO centralize them more?

            try! pprint("res = \(res.wait())")

            res.whenFailure { err in
                pprint("Write[\(#function)] failed: \(err)")
            }
            res.whenSuccess { r in
                pprint("Write[\(#function)] failed: \(r)")
            }

            return res
        }

    }

// TODO: maybe a split like this? and wire protocol cleanly into its own fine?
// }
// public enum WireProtocol {

    struct Envelope: NetworkInbound, NetworkOutbound {
        // let version: Version

        var recipient: UniqueActorPath
        // let headers: [String: String]

        var serializerId: Int
        var payload: ByteBuffer
    }

    internal struct Version {
        var reserved: UInt8 = 0
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var patch: UInt8 = 0
    }

    // TODO: such messages should go over a priority lane
    internal struct HandshakeOffer: NetworkOutbound {
        internal let version: Version = Version.init(reserved: 0, major: 0, minor: 0, patch: 1) // TODO: get it for real

        internal let from: UniqueAddress
        internal let to: Address

        init(from: UniqueAddress, to: Address) {
            self.from = from
            self.to = to
        }
    }

    // TODO: alternative namings: Ack/Nack or Accept/Reject... I'm on the fence here to be honest...
    internal struct HandshakeAccept: NetworkInbound {
        internal let version: Version = Version.init(reserved: 0, major: 0, minor: 0, patch: 1) // TODO: get it for real
        // TODO: Maybe offeringToSpeakAtVersion or something like that?
        internal let from: UniqueAddress

        init(from: UniqueAddress, to: Address) {
            self.from = from
        }
    }

    /// Negative. We can not establish an association with this node.
    internal struct HandshakeReject: NetworkInbound { // TODO: Naming bikeshed
        internal let version: Version = Version.init(reserved: 0, major: 0, minor: 0, patch: 1) // TODO: get it for real
        internal let reason: String?

        /// not an UniqueAddress, so we can't proceed into establishing an association - even by accident
        internal let from: Address

        init(from: Address, reason: String?) {
            self.from = from
            self.reason = reason
        }
    }

    struct Association {
        let address: Network.Address
        let uid: Int64
    }

    public struct Address {
        let `protocol`: String = "sact" // TODO open up
        var systemName: String
        var host: String
        var port: UInt
    }

    public struct UniqueAddress {
        let address: Address
        let uid: NodeUID // TODO ponder exact value here here
    }

    public struct NodeUID {
        let value: UInt32 // TODO redesign / reconsider exact size

        public init(_ value: UInt32) {
            self.value = value
        }
    }

}

extension Network.Address: CustomStringConvertible {
    public var description: String {
        return "\(`protocol`)://\(systemName)@\(host):\(port)"
    }
}

public extension Network.NodeUID {
    static func random() -> Network.NodeUID {
        return Network.NodeUID(UInt32.random(in: 1 ... .max))
    }
}

extension Network.NodeUID: Equatable {
}

// MARK: ActorSystem extensions

extension ActorSystem {

    var network: ActorRef<NetworkKernel.Messages> { // TODO only the "external ones"
        pprint("Trying to talk to network kernel; it is \(self.networkKernel)")

        // return self.networkKernel?.adapt(with: <#T##@escaping (From) -> Messages##@escaping (From) -> NetworkKernel.Messages#>) // TODO the adapting for external only protocol etc
        return self.networkKernel ?? self.deadLetters.adapt(from: NetworkKernel.Messages.self, with: { m in DeadLetter(m) })
    }
//    func join(_ nodeAddress: Network.Address) {
//        guard let kernel = self.networkKernel else {
//            fatalError("NOPE. no networking possible if you yourself have no address") // FIXME
//        }
//
//        return kernel.tell(.join(nodeAddress))
//    }
}
