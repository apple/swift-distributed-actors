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
// MARK: Greeter Messages

extension Greeter {
    enum Message {
        case greet(name: String)
    }

    public static func makeBehavior(context: ActorContext<Message>) -> Behavior<Message> {
        return .setup { context in

            var instance = Self(context: context)

            // /* await */ self.instance.preStart(context: context) // TODO: enable preStart

            return .receiveMessage { message in
                switch message {
                case .greet(let name):
                    instance.greet(name: name)
                }
                return .same
            }
        }
    }

}


// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Extend Actor for Greeter

// extension Actor where Message: Greetings { // FIXME would be nicer
extension Actor where Myself.Message == Greeter.Message {

    func greet(name: String) {
        self.ref.tell(Greeter.Message.greet(name: name))
    }

}
