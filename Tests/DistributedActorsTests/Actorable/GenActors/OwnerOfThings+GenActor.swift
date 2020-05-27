// ==== ------------------------------------------------------------------ ====
// === DO NOT EDIT: Generated by GenActors                     
// ==== ------------------------------------------------------------------ ====

//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019-2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActors

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Generated OwnerOfThings messages 

/// DO NOT EDIT: Generated OwnerOfThings messages
extension OwnerOfThings {

    public enum Message: ActorMessage { 
        case readLastObservedValue(_replyTo: ActorRef<Receptionist.Listing<OwnerOfThings>?>) 
        case performLookup(_replyTo: ActorRef<Result<Receptionist.Listing<OwnerOfThings>, ErrorEnvelope>>) 
        case performAskLookup(_replyTo: ActorRef<Result<Receptionist.Listing<OwnerOfThings.Message>, ErrorEnvelope>>) 
        case performSubscribe(p: ActorRef<Receptionist.Listing<OwnerOfThings>>) 
    }
    
}
// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Generated OwnerOfThings behavior

extension OwnerOfThings {

    public static func makeBehavior(instance: OwnerOfThings) -> Behavior<Message> {
        return .setup { _context in
            let context = Actor<OwnerOfThings>.Context(underlying: _context)
            let instance = instance

            instance.preStart(context: context)

            return Behavior<Message>.receiveMessage { message in
                switch message { 
                
                case .readLastObservedValue(let _replyTo):
                    let result = instance.readLastObservedValue()
                    _replyTo.tell(result)
 
                case .performLookup(let _replyTo):
                    instance.performLookup()
                        ._onComplete { res in
                            switch res {
                            case .success(let value):
                                _replyTo.tell(.success(value))
                            case .failure(let error):
                                _replyTo.tell(.failure(ErrorEnvelope(error)))
                            }
                        }
 
                case .performAskLookup(let _replyTo):
                    instance.performAskLookup()
                        ._onComplete { res in
                            switch res {
                            case .success(let value):
                                _replyTo.tell(.success(value))
                            case .failure(let error):
                                _replyTo.tell(.failure(ErrorEnvelope(error)))
                            }
                        }
 
                case .performSubscribe(let p):
                    instance.performSubscribe(p: p)
 
                
                }
                return .same
            }.receiveSignal { _context, signal in 
                let context = Actor<OwnerOfThings>.Context(underlying: _context)

                switch signal {
                case is Signals.PostStop: 
                    instance.postStop(context: context)
                    return .same
                case let terminated as Signals.Terminated:
                    switch try instance.receiveTerminated(context: context, terminated: terminated) {
                    case .unhandled: 
                        return .unhandled
                    case .stop: 
                        return .stop
                    case .ignore: 
                        return .same
                    }
                default:
                    try instance.receiveSignal(context: context, signal: signal)
                    return .same
                }
            }
        }
    }
}
// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Extend Actor for OwnerOfThings

extension Actor where A.Message == OwnerOfThings.Message {

     func readLastObservedValue() -> Reply<Receptionist.Listing<OwnerOfThings>?> {
        // TODO: FIXME perhaps timeout should be taken from context
        Reply.from(askResponse: 
            self.ref.ask(for: Receptionist.Listing<OwnerOfThings>?.self, timeout: .effectivelyInfinite) { _replyTo in
                Self.Message.readLastObservedValue(_replyTo: _replyTo)}
        )
    }
 

     func performLookup() -> Reply<Receptionist.Listing<OwnerOfThings>> {
        // TODO: FIXME perhaps timeout should be taken from context
        Reply.from(askResponse: 
            self.ref.ask(for: Result<Receptionist.Listing<OwnerOfThings>, ErrorEnvelope>.self, timeout: .effectivelyInfinite) { _replyTo in
                Self.Message.performLookup(_replyTo: _replyTo)}
        )
    }
 

     func performAskLookup() -> Reply<Receptionist.Listing<OwnerOfThings.Message>> {
        // TODO: FIXME perhaps timeout should be taken from context
        Reply.from(askResponse: 
            self.ref.ask(for: Result<Receptionist.Listing<OwnerOfThings.Message>, ErrorEnvelope>.self, timeout: .effectivelyInfinite) { _replyTo in
                Self.Message.performAskLookup(_replyTo: _replyTo)}
        )
    }
 

     func performSubscribe(p: ActorRef<Receptionist.Listing<OwnerOfThings>>) {
        self.ref.tell(Self.Message.performSubscribe(p: p))
    }
 

}
