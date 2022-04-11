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

import Distributed
@preconcurrency import struct Foundation.Data

/// Representation of the distributed invocation in the Behavior APIs.
/// This needs to be removed eventually as we remove behaviors.
public struct InvocationMessage: Sendable, Codable, CustomStringConvertible {
  let targetIdentifier: String
  let arguments: [Data]
  var replyToAddress: ActorAddress

  var target: RemoteCallTarget {
    RemoteCallTarget(targetIdentifier)
  }

  public var description: String {
    "InvocationMessage(target: \(target), arguments: \(arguments.count))"
  }
}

struct InvocationBehavior {
    static func behavior(instance: some DistributedActor) -> _Behavior<InvocationMessage> {
        return _Behavior.setup { context in
            return ._receiveMessageAsync({ (message) async throws -> _Behavior<InvocationMessage> in
                await context.system.receiveInvocation(actor: instance, message: message)
                return .same
            })
        }
    }
}

