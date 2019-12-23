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

/// Causes `GenActors` to generate a `...Stub` for the protocol, so it may be consumed without knowing that the exact implementation class is.
public protocol XPCActorableProtocol: Actorable {
    // TODO: validations in source-gen that this may ONLY be used on a protocol?
}
