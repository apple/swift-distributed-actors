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

import ArgumentParser
import DistributedActors
import DistributedActorsMultiNodeTests
import class Foundation.FileHandle
import class Foundation.Process
import struct Foundation.URL
import NIOCore
import NIOPosix

let MultiNodeTestSuites: [String: Any] = [
    "_ConductorMultiNodeTests": _ConductorMultiNodeTests(),
]
