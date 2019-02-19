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

#if swift(>=5)
// no need to define Result type
#else
public enum Result<Success, Failure: Error> {
    case success(Success)
    case failure(Failure)
}

extension Result {
    func map<B>(_ f: (Success) -> B) -> Result<B, Failure> {
        switch self {
        case .success(let v):
            return .success(f(v))
        case .failure(let error):
            return .failure(error)
        }
    }
}
#endif
