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
    typealias ChangeFunction = (Value) throws -> Value
    typealias BallotValue = (BallotNumber, Value)

    typealias Ref = ActorRef<CASPaxos<Value>.Message>
    typealias AcceptorRef = ActorRef<Acceptor.Message>
    typealias ProposerRef = ActorRef<Proposer.Message>

    enum Message: NonTransportableActorMessage {
        case change(key: String, change: ChangeFunction, replyTo: ActorRef<Result<Value, CASPaxosError>>)
        case clusterEvent(Cluster.Event)
    }

    struct CASInstance {
        let proposer: ProposerRef
        let acceptor: AcceptorRef
    }

    let failureTolerance: Int
    var expectedReplies: Int {
        self.failureTolerance + 1
    }

    /// Name of this CASPaxos instance
    let name: String

    /// CAS instances for every key in use.
    var instances: [String: CASInstance]

    var membership: Cluster.Membership = .empty

    ///
    /// - Parameter failureTolerance: Number (`F`) of failed nodes during a CAS operation which still allow for a successful write.
    ///     For a value of `F == 1` a total of at-least 2 (other) members must be active and respond to any proposer write.
    init(name: String, failureTolerance: Int) {
        self.name = name
        self.failureTolerance = failureTolerance
        self.instances = [:]
    }

    var behavior: Behavior<Message> {
        Behavior<Message>.setup { context in
            context.system.cluster.events.subscribe(context.messageAdapter {
                Message.clusterEvent($0)
            })

            context.receptionist.registerMyself(with: .casPaxos(instanceName: ""))

            return .receiveMessage { message in
                switch message {
                case .clusterEvent(let event):
                    self.onClusterEvent(event: event, context: context)
                case .change(let key, let change, let replyTo):
                    self.onChange(key: key, change: change, replyTo: replyTo, context: context)
                }
                return .same
            }
        }
    }

    private func onClusterEvent(event: Cluster.Event, context: ActorContext<Message>) {
        do {
            try self.membership.apply(event: event)
        } catch {
            context.log.warning("Failed to apply cluster event: \(event)")
        }
    }

    private func onChange(key: String, change: @escaping ChangeFunction, replyTo: ActorRef<Result<Value, CASPaxosError>>, context: ActorContext<Message>) {
        let upMembers = self.membership.count(withStatus: .up)
        guard upMembers >= self.expectedReplies else {
            context.log.warning("Unable to perform change on [\(key)], not enough [.up] members: [\(upMembers)/\(self.expectedReplies)]")
            replyTo.tell(.failure(CASPaxosError.notEnoughMembers(members: upMembers, necessaryMembers: self.expectedReplies)))
            return
        }

        let instance: CASInstance
        if let _instance = self.instances[key] {
            instance = _instance
        } else {
            instance = CASInstance(
                proposer: try! context.spawn("proposer-\(key)", Proposer().behavior), // FIXME: fix this try!
                acceptor: try! context.spawn("acceptor-\(key)", Acceptor().behavior) // FIXME: fix this try!
            )
        }

        instance.proposer.tell(Self.Proposer.Message.local(.change(key: key, change: change, replyTo: replyTo)))
    }
}

// TODO: parameterized extensions would help here
extension ActorRef {
    // TODO: nicer signature, i.e. throw the Error and flatten the result
    func change<Value>(key: String, change: @escaping CASPaxos<Value>.ChangeFunction, timeout: DistributedActors.TimeAmount) -> AskResponse<Result<Value, CASPaxosError>>
        where Value: Codable, Message == CASPaxos<Value>.Message {
        self.ask(timeout: timeout) {
            CASPaxos<Value>.Message.change(key: key, change: change, replyTo: $0)
        }
    }

    func read<Value>(key: String, timeout: DistributedActors.TimeAmount) -> AskResponse<Result<Value, CASPaxosError>>
        where Value: Codable, Message == CASPaxos<Value>.Message {
        self.change(key: key, change: { $0 }, timeout: timeout)
    }
}

enum CASPaxosError: Error, NonTransportableActorMessage {
    /// CAS can only work if there are at least necessary members in the cluster
    ///
    /// We need `2F + 1` members in total, to tolerate `F` failures, since F is known, we can bail early if we know we can't complete the CAS,
    /// since we'll never get quorum for it.
    case notEnoughMembers(members: Int, necessaryMembers: Int)

    /// It is illegal to send multiple CAS concurrently to the same key
    case concurrentRequestError

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
