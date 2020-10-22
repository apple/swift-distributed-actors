//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActors
import NIO

final class CASPaxos<Value: Codable> {
    typealias ChangeFunction = (Value?) throws -> Value?
    typealias BallotValue = (BallotNumber, Value)

    typealias Ref = ActorRef<CASPaxos<Value>.Message>
    typealias AcceptorRef = ActorRef<Acceptor.Message>
    typealias ProposerRef = ActorRef<Proposer.Message>

    enum Message: Codable {
        case local(LocalMessage)
        case acceptorMessage(CASPaxos<Value>.Acceptor.Message)
    }

    enum LocalMessage: NonTransportableActorMessage {
        case change(key: String, change: ChangeFunction, replyTo: ActorRef<Value?>)
    }

    let failureTolerance: Int

    /// Name of this CASPaxos instance
    let name: String

    var proposer: CASPaxos<Value>.ProposerRef! // TODO: CASPaxos itself could become the Proposer?
    var acceptor: CASPaxos<Value>.AcceptorRef!

    /// Only *other* peers.
    var peers: LazyFilterSequence<LazyMapSequence<Set<AddressableActorRef>, CASPaxos<Value>.Ref>>?

    ///
    /// - Parameter failureTolerance: Number (`F`) of failed nodes during a CAS operation which still allow for a successful write.
    ///     For a value of `F == 1` a total of at-least 2 (other) members must be active and respond to any proposer write.
    init(name: String, failureTolerance: Int) {
        self.name = name
        self.failureTolerance = failureTolerance
        self.peers = nil
    }

    var behavior: Behavior<Message> {
        Behavior<Message>.setup { context in
            // register myself and listen for other peers
            context.receptionist.registerMyself(with: .casPaxos(instanceName: "$namespace"))
            context.receptionist.subscribeMyself(to: .casPaxos(instanceName: "$namespace")) { (listing: Reception.Listing<CASPaxos<Value>.Ref>) in
                let peers = listing.refs.filter { $0.address != context.myself.address }
                self.peers = peers
                listing.refs.forEach { context.watch($0) }
            }

            self.proposer = try context.spawn("proposer", props: ._wellKnown, Proposer(failureTolerance: self.failureTolerance).behavior)
            self.acceptor = try context.spawn("acceptor", props: ._wellKnown, Acceptor().behavior)

            return .receiveMessage { message in
                switch message {
                case .local(.change(let key, let change, let replyTo)):
                    self.performChange(key: key, change: change, replyTo: replyTo, context: context)

                case .acceptorMessage(let acceptorMessage):
                    self.acceptor.tell(acceptorMessage)
                }

                return .same
            }
        }
    }

    func performChange(key: String, change: @escaping ChangeFunction, replyTo: ActorRef<Value?>, context: ActorContext<Message>) {
        guard let peers = self.peers else {
            fatalError("respond with an error into replyTo")
        }

        self.proposer.tell(Self.Proposer.Message.local(.change(key: key, change: change, peers: peers, replyTo: replyTo)))
    }
}

enum CASPaxosError: Error, NonTransportableActorMessage {
    /// CAS can only work if there are at least necessary members in the cluster
    ///
    /// We need `2F + 1` members in total, to tolerate `F` failures, since F is known, we can bail early if we know we can't complete the CAS,
    /// since we'll never get quorum for it.
    case notEnoughMembers(members: Int, necessaryMembers: Int)

    case noPrepareQuorum(oks: Int, necessary: Int)
    case noAcceptQuorum(oks: Int, necessary: Int)

    /// It is illegal to send multiple CAS concurrently to the same key
    case concurrentRequestError

    case TODO(String) // placeholder error; FIXME: remove this

    case changeFunctionFailed(Error)

    // Other error
    case error(Error)
}

extension Reception.Key {
    static func casPaxos<Value: Codable>(
        instanceName: String,
        valueType: Value.Type = Value.self
    ) -> Reception.Key<CASPaxos<Value>.Ref> {
        "$cas-\(instanceName)"
    }
}
