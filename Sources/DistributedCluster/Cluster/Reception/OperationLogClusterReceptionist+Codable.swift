//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

extension _OperationLogClusterReceptionist.ReceptionistOp {
    enum DiscriminatorKeys: String, Codable {
        case register
        case remove
    }

    enum CodingKeys: CodingKey {
        case _case
        case key
        case id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key = try container.decode(AnyReceptionKey.self, forKey: .key)
        let id = try container.decode(ActorID.self, forKey: .id)
        switch try container.decode(DiscriminatorKeys.self, forKey: ._case) {
        case .register:
            self = .register(key: key, id: id)
        case .remove:
            self = .remove(key: key, id: id)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .register(let key, let id):
            try container.encode(DiscriminatorKeys.register, forKey: ._case)
            try container.encode(key, forKey: .key)
            try container.encode(id, forKey: .id)
        case .remove(let key, let id):
            try container.encode(DiscriminatorKeys.remove, forKey: ._case)
            try container.encode(key, forKey: .key)
            try container.encode(id, forKey: .id)
        }
    }
}
