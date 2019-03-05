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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Protocol version

/// Wire Protocol version of this Swift Distributed Actors build.
public let DistributedActorsProtocolVersion: Swift Distributed ActorsActor.Version = Version(reserved: 0, major: 0, minor: 0, patch: 1)


// FIXME: !!!! all the Wire.Version and Wire.Handsake... do not really talk about wire; just Protocol so we should move them somehow -- ktoso
//        This is also important to keep the machine clean of any "network stuff", and just have "protocol stuff"

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Constants for Remoting

/// Magic 2 byte value for use as initial bytes in connections (before handshake).
/// Reads as: `5AC7 == SACT == S Act == Swift/Swift Distributed Actors Act == Swift/Swift Distributed Actors Actors`
internal let HandshakeMagicBytes: UInt16 = 0x5AC7


// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Handshake State Machine
// "All Handshakes want to become Associations when they grow up." -- unknown

struct HandshakeStateMachine {

    static func make(kernelState: ReadOnlyKernelState, remoteAddress: NodeAddress) -> State {
        return .initiated(InitiatedState(kernelState: kernelState, remoteAddress: remoteAddress))
    }

    enum StateWithDirective {
        case associate(CompletedState, Directive)
    }

    /// Directives are what instructs the state machine driver about what should be performed next.
    enum Directive {
        // case scheduleRetryHandshake // TODO

        /// The handshake has completed successfully, and shall be "upgraded" to an association.
        /// The handshake has fulfilled its purpose and may be dropped.
        case acceptAndAssociate(CompletedState)

        /// The handshake has failed for some reason and the connection should be immediately closed.
        case rejectHandshake
        /// The handshake is somehow "wrong". This condition can happen if somehow a handshake ends up on the "wrong" node,
        /// of if some configuration setting regarding addresses was wrong for example.
        case rogueHandshakeGoAway(Error)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handshake Initiated

    internal struct InitiatedState: CanMakeHandshakeOffer {
        private let kernelState: ReadOnlyKernelState

        let remoteAddress: NodeAddress
        var selfAddress: UniqueNodeAddress {
            return self.kernelState.selfAddress
        }

        // TODO counter for how many times to retry associating (timeouts)

        init(kernelState: ReadOnlyKernelState, remoteAddress: NodeAddress) {
            self.kernelState = kernelState
            self.remoteAddress = remoteAddress
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handshake Received

    /// Initial state for server side of handshake.
    internal struct HandshakeReceivedState: CanNegotiateHandshake {
        private let kernelState: ReadOnlyKernelState

        public let offer: Wire.HandshakeOffer
        var selfAddress: UniqueNodeAddress {
            return self.kernelState.selfAddress
        }

        func makeCompletedState() -> HandshakeStateMachine.CompletedState {
            return .init(fromReceived: self, remoteAddress: offer.from)
        }

        init(kernelState: ReadOnlyKernelState, offer: Wire.HandshakeOffer) {
            self.kernelState = kernelState
            self.offer = offer
        }
    }

    /// State reached once we have received a `HandshakeAccepted` and are ready to create an association.
    /// This state is used to unlock creating an Association.
    internal struct CompletedState: CanAcceptHandshake {
        var remoteAddress: UniqueNodeAddress
        var selfAddress: UniqueNodeAddress
        // let unique association ID?

        // State Transition used by Client Side of initial Handshake.
        //
        // Since the client is the one who initiates the handshake, once it receives an Accept containing the remote unique address
        // it may immediately transition to the completed state.
        init(fromInitiated state: InitiatedState, remoteAddress: UniqueNodeAddress) {
            precondition(state.selfAddress != remoteAddress, "Node [\(state.selfAddress)] attempted to create association with itself.")
            self.remoteAddress = remoteAddress
            self.selfAddress = state.selfAddress
        }

        // State Transition used by Client Side of initial Handshake.
        init(fromReceived state: HandshakeReceivedState, remoteAddress: UniqueNodeAddress) {
            precondition(state.selfAddress != remoteAddress, "Node [\(state.selfAddress)] attempted to create association with itself.")
            self.remoteAddress = remoteAddress
            self.selfAddress = state.selfAddress
        }
    }

    enum State {
        case initiated(InitiatedState)
        case wasOfferedHandshake(HandshakeReceivedState)
        case completed(CompletedState)
    }

}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: State capabilities

/// Client side only, able to create an offer object which is to be sent to the server-side when initiating the handshake.
protocol CanMakeHandshakeOffer {
    // State requirements --------

    var selfAddress: UniqueNodeAddress { get }
    var remoteAddress: NodeAddress { get }

    // State capabilities --------

    /// Create new handshake offer
    func makeOffer() -> Wire.HandshakeOffer

    // TODO may also need to say we should "please schedule a timeout for this offer" etc

}
extension CanMakeHandshakeOffer {
    /// Invoked when the driver attempts to send an offer.
    func makeOffer() -> Wire.HandshakeOffer {
        // TODO maybe store also at what time we sent the handshake, so we can diagnose if we should reject replies for being late etc
        return Wire.HandshakeOffer(version: DistributedActorsProtocolVersion, from: self.selfAddress, to: self.remoteAddress)
    }

    // TODO timeouts for handshakes
//    func onHandshakeTimeout() {
//        // TODO decide if we should try again or give up; return the decision
//    }
}

/// Capability to negotiate version and other handshake requirements.
///
/// Server-side of a handshake does so when it receives an Offer and the Client-side does so once an Accept is received
/// in which case it may still reject the connection -- if the server accepted it but the client does not want to. // TODO not implemented yet
protocol CanNegotiateHandshake {
    // State requirements --------
    var selfAddress: UniqueNodeAddress { get }

    /// The handshake offer that we received
    var offer: Wire.HandshakeOffer { get }

    /// Since we may reach completed state on either server or client side by different ways
    /// we abstract away this "become completed"
    func makeCompletedState() -> HandshakeStateMachine.CompletedState // TODO can also reach this on other side I think...?

    // State capabilities --------

    /// Negotiation inspects the present offer and yields if we should accept it or not.
    func negotiate() -> HandshakeStateMachine.Directive
}
extension CanNegotiateHandshake {
    func negotiate() -> HandshakeStateMachine.Directive {
        guard self.selfAddress.address == self.offer.to else {
            return .rogueHandshakeGoAway(HandshakeError.targetHandshakeAddressMismatch(self.offer, selfAddress: self.selfAddress))
        }

        // TODO negotiate version; i.e. "I'm 1.0.4, you are 0.9... reject; please upgrade to 1.0 series" etc -- ktoso
        pprint("TODO negotiation here: Local version: \(DistributedActorsProtocolVersion), remote version \(offer.version)")

        // TODO negotiate capabilities; i.e. accept with "accept, but we can't do priority lanes" (bad example, you get the idea tho) -- ktoso

        return .acceptAndAssociate(self.makeCompletedState())
    }
}

protocol CanAcceptHandshake {
    // State requirements --------
    var selfAddress: UniqueNodeAddress { get }
    var remoteAddress: UniqueNodeAddress { get }
}
extension CanAcceptHandshake {
    func makeAccept() -> Wire.HandshakeAccept {
        return .init(from: self.selfAddress, origin: self.remoteAddress)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: send... implementations for

enum HandshakeError: Error {
    /// The first handshake bytes did not match the expected "magic bytes";
    /// It is very likely the other side attempting to connect to our port is NOT a Swift Distributed Actors system,
    /// thus we should reject it immediately. This can happen due to misconfiguration, e.g. mixing
    /// up ports and attempting to send HTTP or other data to a Swift Distributed Actors networking port.
    case illegalHandshakeMagic(was: UInt16, expected: UInt16)

    /// Attempted accepting handshake which was not in progress.
    /// Could mean that the sending side sent the accept twice?
    case acceptAttemptForNotInProgressHandshake(Wire.HandshakeAccept)

    /// The node at which the handshake arrived does not recognize the "to" address of the handshake.
    /// This may be a configuration issue (due to bind address and NAT mixups), or a routing issue
    /// where the handshake was received at "the wrong node".
    ///
    /// The UID part of the `NodeAddress` does not matter for this check, but is included here for debugging purposes.
    case targetHandshakeAddressMismatch(Wire.HandshakeOffer, selfAddress: UniqueNodeAddress)
}
