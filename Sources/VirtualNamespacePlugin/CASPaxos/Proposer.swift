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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Proposer

extension CASPaxos {
    final class Proposer {
        enum Message: Codable {
            case local(LocalMessage)
            case acceptorReply(AcceptorReply)
        }

        enum LocalMessage: NonTransportableActorMessage {
            case change(key: String, change: ChangeFunction, replyTo: ActorRef<Result<Value, CASPaxosError>>) // TODO: extras: Extras (where Extras == [String: String])
        }

        enum AcceptorReply: Codable {
            case conflict(proposed: BallotNumber, latest: BallotNumber)
            case accept(accepted: BallotNumber)
        }

        var ballot: BallotNumber

        // // TODO: Implement ballot cache to improve roundtrips and success rate of CAS operations
//        /// Cache of values seen by other Proposers
//        var cache: [String: BallotValue] = [:]

        /// Holds ids of in-flight CAS operations, only one in-flight operation per key is allowed.
        var locks: Set<String> = []

        init() {
            self.ballot = .zero
        }

        var behavior: Behavior<Message> {
            Behavior<Message>.receive { context, message in
                switch message {
                case .local(.change(let key, let change, let replyTo)):
                    let reply = self.change(key: key, change: change, context: context)
                    return .same

                case .acceptorReply(.conflict(let proposed, let latest)):
                    fatalError("\(message) not implemented yet")

                case .acceptorReply(.accept(let accepted)):
                    fatalError("\(message) not implemented yet")
                }
            }
        }

        func change(key: String, change: ChangeFunction, context: ActorContext<Message>) -> EventLoopFuture<Value> {
            let returnPromise = context.system._eventLoopGroup.next().makePromise(of: Value.self)

            // Lock key while we perform the CAS for it
            guard self.tryLockCAS(key) else {
                returnPromise.fail(CASPaxosError.concurrentRequestError)
                return returnPromise.futureResult
            }

            // The proposer generates a ballot number,
            // and sends "prepare" messages containing that number to the acceptors.

            return returnPromise.futureResult
        }

        /// "Lock" a specific key while we're trying to CAS it.
        internal func tryLockCAS(_ key: String) -> Bool {
            self.locks.insert(key).inserted
        }

        /// "Unlock" a specific key.
        internal func unlockCAS(_ key: String) {
            self.locks.remove(key)
        }
    }
}
