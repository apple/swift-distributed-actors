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
// MARK: Acceptor

protocol PotentiallyConflicting {
    var isConflict: Bool { get }
    var ballot: BallotNumber? { get }
}

extension CASPaxos {
    final class Acceptor {
        enum Message: Codable {
            typealias _Value = Value
            case prepare(key: String, ballot: BallotNumber, replyTo: ActorRef<Preparation>) // TODO: extras
            case accept(key: String, ballot: BallotNumber, value: Value?, promise: BallotNumber, replyTo: ActorRef<Acceptance>) // TODO: extras
        }

        // ==== --------------------------------------------------------------------------------------------------------
        enum Preparation: PotentiallyConflicting, Codable {
            case conflict(ballot: BallotNumber)
            case prepared(ballot: BallotNumber, value: Value?)

            var isPrepared: Bool {
                switch self {
                case .prepared: return true
                default: return false
                }
            }

            var isConflict: Bool {
                switch self {
                case .conflict: return true
                default: return false
                }
            }

            var ballot: BallotNumber? {
                switch self {
                case .conflict(let ballot):
                    return ballot
                case .prepared(let ballot, _):
                    return ballot
                }
            }
        }

        enum Acceptance: PotentiallyConflicting, Codable {
            case conflict(ballot: BallotNumber)
            case ok

            var isConflict: Bool {
                switch self {
                case .conflict: return true
                default: return false
                }
            }

            var isOk: Bool {
                switch self {
                case .ok: return true
                default: return false
                }
            }

            var ballot: BallotNumber? {
                switch self {
                case .conflict(let ballot):
                    return ballot
                case .ok:
                    return nil
                }
            }
        }

        // ==== --------------------------------------------------------------------------------------------------------

        struct Stored {
            var promise: BallotNumber
            let ballot: BallotNumber
            let value: Value?
        }

        var storage: [String: Stored] = [:]

        // ==== --------------------------------------------------------------------------------------------------------

        var behavior: Behavior<Message> {
            .receive { context, message in
                switch message {
                case .prepare(let key, let ballot, let replyTo):
                    let preparation = self.prepare(key: key, ballot: ballot, context: context)
                    replyTo.tell(preparation)

                case .accept(let key, let ballot, let value, let promise, let replyTo):
                    let acceptance = self.accept(key: key, ballot: ballot, value: value, promise: promise, context: context)
                    replyTo.tell(acceptance)
                }

                return .same
            }
        }

        func prepare(key: String, ballot: BallotNumber, context: ActorContext<Message>) -> Preparation {
            var info = self.storage[key, default: Stored(promise: .zero, ballot: .zero, value: nil)]

            if info.promise >= ballot {
                return .conflict(ballot: info.promise)
            }

            if info.ballot >= ballot {
                return .conflict(ballot: info.ballot)
            }

            info.promise = ballot
            self.storage[key] = info

            return .prepared(ballot: info.ballot, value: info.value)
        }

        func accept(key: String, ballot: BallotNumber, value: Value?, promise: BallotNumber, context: ActorContext<Message>) -> Acceptance {
            var info = self.storage[key, default: Stored(promise: .zero, ballot: .zero, value: nil)]

            if info.promise > ballot {
                // [caspaxos]
                // Returns a conflict if it already saw a greater ballot number.
                context.log.warning("Already saw info.promise [\(info.promise)] > ballot [\(ballot)], conflict.") // TODO: more metadata
                return .conflict(ballot: info.promise)
            }

            if info.ballot >= ballot {
                context.log.warning("Already saw info.promise [\(info.ballot)] > ballot [\(ballot)], conflict.") // TODO: more metadata
                return .conflict(ballot: info.ballot)
            }

            // [caspaxos]
            // Erases the promise, marks the received tuple (ballot number, value) as the accepted value
            let accepted = Stored(promise: promise, ballot: ballot, value: value)
            context.log.info("Accept \(accepted)") // TODO: more metadata
            self.storage[key] = accepted

            // [caspaxos]
            // ... and returns a confirmation
            return .ok
        }
    }
}
