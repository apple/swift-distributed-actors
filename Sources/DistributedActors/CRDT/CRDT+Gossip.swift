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

import Logging
import NIO

extension CRDT {
    struct Gossip {
        // TODO: would we want a simplified seen table -- perhaps a "seen set" with members whom we know have seen this...?

        let deltas: [CRDT.Identity: Delta]
    }
}

extension CRDT.Gossip: Codable {
    // Codable: synthesized conformance
}
