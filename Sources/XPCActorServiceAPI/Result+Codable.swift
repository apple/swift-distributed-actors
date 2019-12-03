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

extension Result: Codable where Success: Codable, Failure: Error {
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .success(let success):
            var container = encoder.singleValueContainer()
            try container.encode(success)
        default:
            fatalError("NOT IMPLEMENTED")
        }
    }

    public  init(from decoder: Decoder) throws {
        self = .success(try decoder.singleValueContainer().decode(Success.self))
    }
}
