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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Generated ClassActorable messages 

/// DO NOT EDIT: Generated ClassActorable messages
extension ClassActorable {

    public enum Message: ActorMessage { 
        case hello(_replyTo: ActorRef<String>) 
    }
    
}
// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Generated ClassActorable behavior

extension ClassActorable {

    public static func makeBehavior(instance: ClassActorable) -> Behavior<Message> {
        return .setup { _context in
            let context = Actor<ClassActorable>.Context(underlying: _context)
            let instance = instance

            /* await */ instance.preStart(context: context)

            return Behavior<Message>.receiveMessage { message in
                switch message { 
                
                case .hello(let _replyTo):
                    let result = instance.hello()
                    _replyTo.tell(result)
 
                
                }
                return .same
            }.receiveSignal { _context, signal in 
                let context = Actor<ClassActorable>.Context(underlying: _context)

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
// MARK: Extend Actor for ClassActorable

extension Actor where A.Message == ClassActorable.Message {

     func hello() -> Reply<String> {
        // TODO: FIXME perhaps timeout should be taken from context
        Reply.from(askResponse: 
            self.ref.ask(for: String.self, timeout: .effectivelyInfinite) { _replyTo in
                .hello(_replyTo: _replyTo)}
        )
    }
 

}
