//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

extension _OperationLogClusterReceptionist.ReceptionistOp {
    public enum DiscriminatorKeys: String, Codable {
        case register
        case remove
    }

    public enum CodingKeys: CodingKey {
        case _case
        case key
        case address
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key = try container.decode(AnyReceptionKey.self, forKey: .key)
        let address = try container.decode(ActorAddress.self, forKey: .address)
        switch try container.decode(DiscriminatorKeys.self, forKey: ._case) {
        case .register:
            self = .register(key: key, address: address)
        case .remove:
            self = .remove(key: key, address: address)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .register(let key, let address):
            try container.encode(DiscriminatorKeys.register, forKey: ._case)
            try container.encode(key, forKey: .key)
            try container.encode(address, forKey: .address)
        case .remove(let key, let address):
            try container.encode(DiscriminatorKeys.remove, forKey: ._case)
            try container.encode(key, forKey: .key)
            try container.encode(address, forKey: .address)
        }
    }
}
