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

@testable import DistributedActors
import DistributedActorsTestKit
import XCTest

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Generated TestMembershipOwner messages 

/// DO NOT EDIT: Generated TestMembershipOwner messages
extension TestMembershipOwner {
    public enum Message { 
        case replyMembership(_replyTo: ActorRef<Membership?>) 
    }

    
}
// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Generated TestMembershipOwner behavior

extension TestMembershipOwner {

    public static func makeBehavior(instance: TestMembershipOwner) -> Behavior<Message> {
        return .setup { _context in
            let context = Actor<TestMembershipOwner>.Context(underlying: _context)
            let instance = instance

            /* await */ instance.preStart(context: context)

            return Behavior<Message>.receiveMessage { message in
                switch message { 
                
                case .replyMembership(let _replyTo):
                    let result = instance.replyMembership()
                    _replyTo.tell(result)
 
                
                }
                return .same
            }.receiveSignal { _context, signal in 
                let context = Actor<TestMembershipOwner>.Context(underlying: _context)

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
// MARK: Extend Actor for TestMembershipOwner

extension Actor where A.Message == TestMembershipOwner.Message {

    func replyMembership() -> Reply<Membership?> {
        // TODO: FIXME perhaps timeout should be taken from context
        Reply(nioFuture:
            self.ref.ask(for: Membership?.self, timeout: .effectivelyInfinite) { _replyTo in
                .replyMembership(_replyTo: _replyTo)}
            .nioFuture
            )
    }
 

}
