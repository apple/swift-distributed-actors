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
import DistributedActorsXPC
import Foundation
import it_XPCActorable_echo_api

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Generated ActorableWatcher messages 

/// DO NOT EDIT: Generated ActorableWatcher messages
extension ActorableWatcher {

    public enum Message { 
        case noop 
    }
    
}
// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Generated ActorableWatcher behavior

extension ActorableWatcher {

    public static func makeBehavior(instance: ActorableWatcher) -> Behavior<Message> {
        return .setup { _context in
            let context = Actor<ActorableWatcher>.Context(underlying: _context)
            let instance = instance

            /* await */ instance.preStart(context: context)

            return Behavior<Message>.receiveMessage { message in
                switch message { 
                
                case .noop:
                    instance.noop()
 
                
                }
                return .same
            }.receiveSignal { _context, signal in 
                let context = Actor<ActorableWatcher>.Context(underlying: _context)

                switch signal {
                case is Signals.PostStop: 
                    instance.postStop(context: context)
                    return .same
                case let terminated as Signals.Terminated:
                    switch  instance.receiveTerminated(context: context, terminated: terminated) {
                    case .unhandled: 
                        return .unhandled
                    case .stop: 
                        return .stop
                    case .ignore: 
                        return .same
                    }
                default:
                     instance.receiveSignal(context: context, signal: signal)
                    return .same
                }
            }
        }
    }
}
// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Extend Actor for ActorableWatcher

extension Actor where A.Message == ActorableWatcher.Message {

     func noop() {
        self.ref.tell(.noop)
    }
 

}
