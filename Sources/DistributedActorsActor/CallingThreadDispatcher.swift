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

/// Use with great caution!! Hijacks the calling thread to execute the actor.
///
/// Can cause severe and bad interactions with supervision.
internal struct CallingThreadDispatcher: MessageDispatcher {
    public var name: String {
        return "callingThread:\(_hackyPThreadThreadId())"
    }

    @inlinable
    public func execute(_ f: @escaping () -> Void) {
        f()
    }
}
