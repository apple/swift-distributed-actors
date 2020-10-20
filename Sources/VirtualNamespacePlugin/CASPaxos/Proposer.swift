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
import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Proposer

extension CASPaxos {
    final class Proposer {
        enum Message: Codable {
            case local(LocalMessage)
            case acceptorReply(AcceptorReply) // FIXME: this is not used, we use ask for all interactions
        }

        enum LocalMessage: NonTransportableActorMessage {
            case change(
                key: String,
                change: ChangeFunction,
                peers: LazyFilterSequence<LazyMapSequence<Set<AddressableActorRef>, CASPaxos<Value>.Ref>>, // TODO: pass just Acceptors rather than full thing?
                replyTo: ActorRef<Value?>
            ) // TODO: extras: Extras (where Extras == [String: String])
        }

        enum AcceptorReply: Codable {
            case conflict(proposed: BallotNumber, latest: BallotNumber)
            case accept(accepted: BallotNumber)
        }

        let failureTolerance: Int

        /// A proposer needs to wait for `F + 1` accepts in order to gain quorum.
        var expectedAccepts: Int {
            self.failureTolerance + 1 // TODO: this can't handle resizing clusters yet
        }

        var ballot: BallotNumber

        // // TODO: Implement ballot cache to improve roundtrips and success rate of CAS operations
//        /// Cache of values seen by other Proposers
//        var cache: [String: BallotValue] = [:]

        /// Holds ids of in-flight CAS operations, only one in-flight operation per key is allowed.
        var locks: Set<String> = []

        init(failureTolerance: Int) {
            self.failureTolerance = failureTolerance
            self.ballot = .zero
        }

        var behavior: Behavior<Message> {
            Behavior<Message>.receive { context, message in
                switch message {
                case .local(.change(let key, let change, let peers, let replyTo)):
                    let casResult = self.change(key: key, change: change, peers: peers, context: context)
                    casResult._onComplete { result in
                        switch result {
                        case .success(let newValue):
                            replyTo.tell(newValue)
                        case .failure(let error):
                            context.log.warning("Failed CAS: \(error) for \(key)")
                             // FIXME!!: we need to signal errors back to the `replyTo`
                        }
                    }
                    return .same

                case .acceptorReply(.conflict(let proposed, let latest)):
                    fatalError("\(message) not implemented yet")

                case .acceptorReply(.accept(let accepted)):
                    fatalError("\(message) not implemented yet")
                }
            }
        }

        func change(
            key: String,
            change: @escaping ChangeFunction,
            peers: LazyFilterSequence<LazyMapSequence<Set<AddressableActorRef>, CASPaxos<Value>.Ref>>, // peers: Set<CASPaxos<Value>.AcceptorRef>, // FIXME: pass just set of Acceptors?
            context: ActorContext<Message>
        ) -> EventLoopFuture<Value?> {
            let returnPromise = context.system._eventLoopGroup.next().makePromise(of: Value?.self)

            // If we know we won't ever get quorum, don't even try and fail right away
            guard peers.count >= self.expectedAccepts else {
                returnPromise.fail(CASPaxosError.notEnoughMembers(members: peers.count, necessaryMembers: self.expectedAccepts))
                return returnPromise.futureResult
            }

            // Lock key while we perform the CAS for it
            guard self.tryLockCAS(key) else {
                returnPromise.fail(CASPaxosError.concurrentRequestError)
                return returnPromise.futureResult
            }

            // ==== Prepare phase --------------------------------------------------------------------------------------

            // [caspaxos]
            // The proposer generates a ballot number,
            self.ballot.increment()
            let ballot = self.ballot

            // [caspaxos]
            // and sends "prepare" messages containing that number to the acceptors.
            let futurePreparations: [EventLoopFuture<CASPaxos<Value>.Acceptor.Preparation>] = peers.map { (peer: CASPaxos<Value>.Ref) in
                peer.ask(timeout: .seconds(3)) { (replyTo: ActorRef<CASPaxos<Value>.Acceptor.Preparation>) in // FIXME: hardcoded timeout
                    CASPaxos<Value>.Message.acceptorMessage(
                        CASPaxos<Value>.Acceptor.Message.prepare(key: key, ballot: ballot, replyTo: replyTo)
                    )
                }
            }.map { // FIXME: terrible hack to work-around the fact that we need to make whenAll and similar things on these and we are actually hiding the fact we're using nio futures (and cannot always create them even)
                switch $0 {
                case .completed(.failure(let error)):
                    return context.system._eventLoopGroup.next().makeFailedFuture(error)
                case .completed(.success(let answer)):
                    return context.system._eventLoopGroup.next().makeSucceededFuture(answer)
                case .nioFuture(let future):
                    return future
                }
            }

            // TODO: this is enough to wait for `F+1` first replies, the others we can ignore
            context.onResultAsync(of: EventLoopFuture.whenAllComplete(futurePreparations, on: context.system._eventLoopGroup.next()), timeout: .seconds(10)) { result in
                guard case .success(let preparations) = result else {
                    context.log.warning("Failed to gather responses: \(result)")
                    return .same
                }

                var conflicts: [BallotNumber] = []
                var prepareOKs: [(ballot: BallotNumber, value: Value?)] = []
                prepareOKs.reserveCapacity(self.expectedAccepts)

                for prep in preparations {
                    switch prep {
                    case .failure(let error):
                        context.log.warning("Failed: \(error)")
                    case .success(.conflict(let ballot)):
                        conflicts.append(ballot)
                    case .success(.prepared(let ballot, let value)):
                        prepareOKs.append((ballot: ballot, value: value))
                    }
                }

                // [caspaxos]
                // Waits for the F + 1 confirmations

                guard prepareOKs.count >= self.expectedAccepts else {
                    context.log.warning("No quorum, results: \(prepareOKs)", metadata: [
                        "cas/instance": "\(context.path)", // FIXME: instead carry the instance name and use it here
                        "cas/oks": Logger.MetadataValue.array(prepareOKs.map { Logger.MetadataValue.string("\($0)") }),
                    ])
                    returnPromise.fail(CASPaxosError.noPrepareQuorum(oks: prepareOKs.count, necessary: self.expectedAccepts))
                    return .same
                }

                // [caspaxos]
                let currentValue: Value?
                // If they (OKs) all contain the empty value, then the proposer defines the current state as ∅
                let allOksEmptyState: Bool = prepareOKs.allSatisfy { $0.value == nil }
                if allOksEmptyState {
                    context.log.debug("All OKs (\(prepareOKs.count)) are nil value, our value is the first")
                    currentValue = nil
                } else {
                    // [caspaxos]
                    // otherwise it picks the value of the tuple with the highest ballot number.
                    guard let (highestBallot, value) = prepareOKs.sorted(by: { $0.ballot.counter < $1.ballot.counter }).last else {
                        fatalError("No highest value -- we had zero OKs") // FIXME: better handling of this
                    }
                    currentValue = value
                }

                // ==== Commit phase -----------------------------------------------------------------------------------
                // [caspaxos]
                // Applies the f function to the current state
                let newValue: Value?
                do {
                    newValue = try change(currentValue)
                } catch {
                    context.log.warning("User change function failed to apply from \(currentValue), error: \(error)")
                    returnPromise.fail(CASPaxosError.changeFunctionFailed(error))
                    return .same
                }

                // [caspaxos]
                // ...and sends the result (`newValue`),
                // along with the generated ballot number B (an "accept" message) to the acceptors.

                // FIXME: sanity check the promise generation... this is based on grydka
                var promise = ballot
                promise.increment()

                // [caspaxos]
                // Waits for the F + 1 confirmations.
                let futureAcceptances: [EventLoopFuture<CASPaxos<Value>.Acceptor.Acceptance>] = peers.map { (peer: CASPaxos<Value>.Ref) in
                    peer.ask(timeout: .seconds(3)) { (replyTo: ActorRef<CASPaxos<Value>.Acceptor.Acceptance>) in // FIXME: hardcoded timeout
                        CASPaxos<Value>.Message.acceptorMessage(
                            CASPaxos<Value>.Acceptor.Message.accept(key: key, ballot: ballot, value: newValue, promise: promise, replyTo: replyTo)
                        )
                    }
                }.map { // FIXME: terrible hack to work-around the fact that we need to make whenAll and similar things on these and we are actually hiding the fact we're using nio futures (and cannot always create them even)
                    switch $0 {
                    case .completed(.failure(let error)):
                        return context.system._eventLoopGroup.next().makeFailedFuture(error)
                    case .completed(.success(let answer)):
                        return context.system._eventLoopGroup.next().makeSucceededFuture(answer)
                    case .nioFuture(let future):
                        return future
                    }
                }

                // TODO: this is enough to wait for `F+1` first replies, the others we can ignore
                context.onResultAsync(of: EventLoopFuture.whenAllComplete(futureAcceptances, on: context.system._eventLoopGroup.next()), timeout: .seconds(10)) { result in
                    guard case .success(let acceptances) = result else {
                        context.log.warning("Failed to gather responses: \(result)")
                        returnPromise.fail(CASPaxosError.TODO("Failed to gather acceptances"))
                        return .same
                    }

                    var conflicts: [BallotNumber] = []
                    var acceptOKs: Int = 0

                    for ack in acceptances {
                        switch ack {
                        case .failure(let error):
                            context.log.warning("Failed: \(error)")
                        case .success(.conflict(let ballot)):
                            conflicts.append(ballot)
                        case .success(.ok):
                            acceptOKs += 1
                        }
                    }

                    // [caspaxos]
                    // Waits for the F + 1 confirmations

                    guard acceptOKs >= self.expectedAccepts else {
                        context.log.warning("No quorum while gathering accept/oks, results: \(acceptOKs)", metadata: [
                            "cas/instance": "\(context.path)", // FIXME: instead carry the instance name and use it here
                            "cas/oks": "\(acceptOKs)",
                        ])
                        returnPromise.fail(CASPaxosError.noAcceptQuorum(oks: acceptOKs, necessary: self.expectedAccepts))
                        return .same
                    }

                    // [caspaxos]
                    // Returns the new state to the client.
                    // Finally~!

                    context.log.info("Completed CAS(\(currentValue) -> \(newValue)) with \(acceptOKs)")
                    returnPromise.succeed(newValue)
                    return .same
                }

                return .same
            }

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
