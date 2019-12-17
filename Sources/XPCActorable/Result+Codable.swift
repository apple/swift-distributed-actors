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

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)

import DistributedActors
import CXPCActorable
import XPC
import NIO
import Logging
import Files

// TODO: Offering such by default may be "tricky" or "wrong"...

extension Result: Codable where Success: Codable, Failure: Error {

    public enum DiscriminatorKeys: String, Codable {
        case success
        case failure
    }

    public enum CodingKeys: CodingKey {
        case _case
        case success_value
        case failure_value
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .success(let success):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(DiscriminatorKeys.success, forKey: ._case)
            try container.encode(success, forKey: .success_value)

        case .failure(let error):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(DiscriminatorKeys.failure, forKey: ._case)
            try container.encode(XPCGenericError(error: type(of: error)), forKey: .failure_value)
        }
    }

    public  init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(DiscriminatorKeys.self, forKey: ._case) {
        case .success:
            self = .success(try container.decode(Success.self, forKey: .success_value))
        case .failure:
            let error = try container.decode(XPCGenericError.self, forKey: .failure_value)
            self = Result<Success, Error>.failure(error) as! Result<Success, Failure> // FIXME: this is broken...
        }
    }
}

public struct XPCGenericError: Error, Codable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public init<E: Error>(error errorType: E.Type) {
        self.reason = "\(errorType)"
    }
}

#else
/// XPC is only available on Apple platforms
#endif

