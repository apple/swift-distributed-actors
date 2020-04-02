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

import Dispatch
import Logging
import NIO

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Codable Receptionist + Actor Listings

/// Custom Codable conformance is necessary since `Listing<MyActorable>` does not type-wise seem to be `Codable`,
/// but in reality it absolutely is, because we never pass around "the" `MyActorable` but rather a reference to one,
/// which absolutely is Codable.
extension Reception.Listing {
    enum CodingKeys: String, CodingKey {
        case refs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.refs = try container.decode(Set<ActorRef<Act.Message>>.self, forKey: .refs)
    }

    public func encode(to encoder: Encoder) throws {
        var encoder = encoder.container(keyedBy: CodingKeys.self)
        try encoder.encode(self.refs, forKey: .refs)
    }
}
