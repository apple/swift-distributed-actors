// ==== ------------------------------------------------------------------ ====
// === DO NOT EDIT: Generated by GenActors                     
// ==== ------------------------------------------------------------------ ====

//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActors
import class NIO.EventLoopFuture

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Generated OwnerOfThings messages 

/// DO NOT EDIT: Generated OwnerOfThings messages
extension OwnerOfThings {
    public enum Message { 
        case readLastObservedValue(_replyTo: ActorRef<Reception.Listing<OwnerOfThings>?>) 
        case performLookup(_replyTo: ActorRef<Result<Reception.Listing<OwnerOfThings>, Error>>) 
    }

    
}
// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Generated OwnerOfThings behavior

extension OwnerOfThings {

    public static func makeBehavior(instance: OwnerOfThings) -> Behavior<Message> {
        return .setup { _context in
            let context = Actor<OwnerOfThings>.Context(underlying: _context)
            let instance = instance

            /* await */ instance.preStart(context: context)

            return Behavior<Message>.receiveMessage { message in
                switch message { 
                
                case .readLastObservedValue(let _replyTo):
                    let result = instance.readLastObservedValue()
                    _replyTo.tell(result)
 
                case .performLookup(let _replyTo):
                    instance.performLookup()
                                    .whenComplete { res in _replyTo.tell(res) } 
                
                }
                return .same
            }.receiveSignal { _context, signal in 
                let context = Actor<OwnerOfThings>.Context(underlying: _context)

                switch signal {
                case is Signals.PostStop: 
                    instance.postStop(context: context)
                    return .same
                case let terminated as Signals.Terminated:
                    switch instance.receiveTerminated(context: context, terminated: terminated) {
                    case .unhandled: 
                        return .unhandled
                    case .stop: 
                        return .stop
                    case .ignore: 
                        return .same
                    }
                default:
                    return .unhandled
                }
            }
        }
    }
}
// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Extend Actor for OwnerOfThings

extension Actor where A.Message == OwnerOfThings.Message {

    func readLastObservedValue() -> Reply<Reception.Listing<OwnerOfThings>?> {
        // TODO: FIXME perhaps timeout should be taken from context
        Reply(nioFuture:
            self.ref.ask(for: Reception.Listing<OwnerOfThings>?.self, timeout: .effectivelyInfinite) { _replyTo in
                .readLastObservedValue(_replyTo: _replyTo)}
            .nioFuture
            )
    }
 

    func performLookup() -> Reply<Reception.Listing<OwnerOfThings>> {
        // TODO: FIXME perhaps timeout should be taken from context
        Reply(nioFuture:
            self.ref.ask(for: Result<Reception.Listing<OwnerOfThings>, Error>.self, timeout: .effectivelyInfinite) { _replyTo in
                .performLookup(_replyTo: _replyTo)}
            .nioFuture.flatMapThrowing { result in
                switch result {
                case .success(let res): return res
                case .failure(let err): throw err
                }
            }
            )
    }
 

}
