//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActorsMultiNodeTests
import MultiNodeTestKit

let MultiNodeTestSuites: [any MultiNodeTestSuite.Type] = [
    MultiNodeConductorTests.self,
    MultiNodeClusterSingletonTests.self,
]
