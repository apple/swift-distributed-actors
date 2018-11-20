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


/// Messages sent only internally by the `ActorSystem` and actor internals.
/// These messages MUST NOT ever be sent directly by user-land.
///
/// System messages get preferential processing treatment as well as re-delivery in face of remote communication.
public /* but really internal... */ enum SystemMessage: Equatable {

  /// Sent to an Actor for it to "start", i.e. inspect and potentially evaluate a behavior wrapper that should
  /// be executed immediately e.g. `setup` or similar ones.
  case start

  /// Usually the actor sends this message to itself once it has processed other things.
  case tombstone // also known as "terminate"
  // TODO do we need poison pill?

  /// Notifies an actor that it is being watched by the `from` actor
  case watch(from: AnyReceivesSignals)
  /// Notifies an actor that it is no longer being watched by the `from` actor
  case unwatch(from: AnyReceivesSignals)

  /// Received after [[watch]] was issued to an actor ref
  case terminated(ref: AnyAddressableActorRef) // TODO there's usually additional ifo: existenceConfirmed: Bool, reason: etc

  // TODO this is incomplete

  // exciting future ideas:
  // case setLogLevel(_ level: LogLevel)
}

// Implementation notes:
// Need to implement Equatable manually since we have associated values
extension SystemMessage {
  public static func ==(lhs: SystemMessage, rhs: SystemMessage) -> Bool {
    switch (lhs, rhs) {
    case (.start, .start): return true
    case let (.watch(l), .watch(r)): return l.path == r.path
    case let (.unwatch(l), .unwatch(r)): return l.path == r.path
    case (.tombstone, .tombstone): return true
    case let (.terminated(lref), .terminated(rref)): return lref.path == rref.path

    // listing cases rather than a full-on `default` to get an error when we add a new system message
    case (.start, _),
    (.watch, _),
    (.unwatch, _),
    (.tombstone, _),
    (.terminated, _): return false
    }
  }
}
