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

/// Forbidden tools for use only internally in Swift Distributed Actors.
internal extension ActorRef {

  /// INTERNAL API: UNSAFE, DO NOT TOUCH.
  internal var internal_downcast: ActorRefWithCell<Message> {
    switch self {
    case let withCell as ActorRefWithCell<Message>: return withCell
    default: fatalError("Illegal downcast attempt from \(self) to ActorRefWithCell. This is a Swift Distributed Actors bug, please report this on the issue tracker.")
    }
  }

}

