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
// Dario's ideas:
//infix operator !
//
//public func !<R : ActorRef, T>(ref: inout R, msg: T) -> Void where R.T == T {
//    ref.tell(msg)
//}

infix operator !

public extension ActorRef {
  // public func !<R : ActorRef, T>(ref: inout R, msg: T) -> Void where R.T == T {
  static func !(ref: ActorRef<Message>, message: Message) {
    ref.tell(message)
  }
}
