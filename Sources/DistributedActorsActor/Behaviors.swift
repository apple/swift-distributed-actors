//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
// Created by Konrad Malawski on 2018-09-28.
//


/// A `Behavior` is what executes then an `Actor` handles messages.
///
/// The most important behavior is `Behavior.receive` since it allows handling incoming messages with a simple block.
/// Various other predefined behaviors exist, such as "stopping" or "ignoring" a message.
public enum Behavior<Message> {

    /// Defines a behavior that will be executed with an incoming message by its hosting actor.
    case receive(handle: (Message) -> Behavior<Message>)

    /// Defines that the same behavior should remain
    case same

}

//public struct Behavior<Message> {
//
//}
//
//// MARK: default provided behaviors
//
//public extension Behavior {
//    static func receive<T>(_ onMessage: (T) -> Behavior<T>) -> Behavior<T> {
//        return TODO("not implemented yet")
//    }
//
//    static func same<T>() -> Behavior<T> {
//
//    }
//
//}
//

