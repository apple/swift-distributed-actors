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

internal struct ActorUID: Equatable, Hashable {
    let value: UInt32
}

extension ActorUID {
    static let undefined: ActorUID = ActorUID(value: 0)

    static func random() -> ActorUID {
        return ActorUID(value: UInt32.random(in: 1 ... .max))
    }
}
