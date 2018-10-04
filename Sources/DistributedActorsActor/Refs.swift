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

protocol ReceivesMessages {
  associatedtype Message

  func tell(_ message: Message) -> ()
}

public struct ActorRef<Message>: ReceivesMessages {

  /// Actors need names. We might want to discuss if we can optimize the names keeping somehow...
  /// The runtime does not care about the names really, and "lookup by name at runtime" has shown to be an anti-pattern in Akka over the years (will explain in depth elsewhere)
  /// Yet they are tremendously useful in debugging and understanding systems: "Which actor is blowing up?! Oh the "transaction-23232" consistently fails; even in presence of not so good log statements etc.
  ///
  /// Since we need the names mostly for debugging; perhaps we can register paths<->ids in some place and fetch them when needed rather than carry them in an ActorRef? -- TODO measure if this would kill logging since contention on the getting names...? tho could be enabled at will or maybe "post processed" even
  ///    -- post processing id -> names could also work; AFAIR aeron logs similarily, to a high performance format, to them obtain full names with a tool out of it; we could also support a debug mode, where names are always around etc...
  /// The thing is that actor refs are EVERYWHERE, so having them light could be beneficial -- TODO measure how much so
  ///
  /// Bottom line: I feel we may gain some performance by straying from the Akka way of carrying the names, yet at the same time, we need to guarantee some way for users to get names; they're incredibly important.


  let path: String // TODO this is if we want them in a hierarchy, otherwise it would be "name" but I think hierarchy has been pretty successful for Akka
  let uid: Int // TODO think about it

  // TODO decide where tell should live
  public func tell(_ message: Message) { // yes we do want to keep ! and tell, it allows teaching people about the meanings and "how to read !" and also eases the way into other operations
    return TODO("not implemented yet")
  }

}

extension ActorRef: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String {
    return "ActorRef(\(path))"
  }
  public var debugDescription: String {
    return "ActorRef(\(path)#\(uid)"
  }
}

// TODO decide where to put tell
// TODO decide where to put ask // later though

// Dario's ideas:
//infix operator !
//
//public func !<R : ActorRef, T>(ref: inout R, msg: T) -> Void where R.T == T {
//    ref.tell(msg)
//}

infix operator !

public extension ActorRef {
  static func !(ref: ActorRef<Message>, message: Message) {
  }
}

