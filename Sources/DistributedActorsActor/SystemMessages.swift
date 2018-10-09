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
internal enum SystemMessage {
  case terminate
  case watch(from: ActorRef<Nothing>)
  case unwatch(from: ActorRef<Nothing>)

     // TODO this is incomplete
}