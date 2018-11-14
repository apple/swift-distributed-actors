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

/// Signals are system messages which may be handled by actors.
///
/// They are separate from the message protocol of an Actor (the `M` in `ActorRef<M>`)
/// since these signals are independently useful regardless of protocol that an actor speaks externally.
///
/// Signals will never be "dropped", as a special mailbox is used to store them, so even in presence of
/// bounded mailbox configurations, signals are retained and handled as a priority during mailbox runs.m
// FIXME system messages vs signals
public enum Signal {
  // TODO I think we will indeed want to separate "system message" from "signal" and "signal" be those that users see

  // case terminated(ref: ActorRef<Never>, reason: String) // TODO figure out types for reason // TODO "existenceConfirmed: Bool"
  // case preRestart
  // case postStop
}
