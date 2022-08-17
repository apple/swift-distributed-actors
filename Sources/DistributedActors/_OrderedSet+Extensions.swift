//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import OrderedCollections

extension OrderedSet {
    // FIXME(collections): implemented for real in https://github.com/apple/swift-collections/pull/159
    @inlinable
    internal func _filter(
        _ isIncluded: (Element) throws -> Bool
    ) rethrows -> Self {
        var set = try self.filter(isIncluded)
        return OrderedSet(uncheckedUniqueElements: set)
    }
}
