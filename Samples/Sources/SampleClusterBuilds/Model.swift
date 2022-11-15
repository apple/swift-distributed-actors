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

import _PrettyLogHandler
import Distributed
import DistributedCluster
import struct Foundation.UUID
import Logging
import NIO
import OpenTelemetry
import OtlpGRPCSpanExporting
import Tracing

struct BuildTask: Sendable, Codable, Hashable {
    let id: BuildTaskID

    // this would have some state about "what to build"

    init() {
        self.id = .init()
    }

    init(id: BuildTaskID) {
        self.id = id
    }
}

/// A trivial "build result" representation, not carrying additional information, just for demonstration purposes.
enum BuildResult: Sendable, Codable, Equatable {
    case successful
    case failed
    case rejected
}

struct BuildTaskID: Sendable, Codable, Hashable, CustomStringConvertible {
    let id: UUID
    init() {
        self.id = UUID()
    }

    var description: String {
        "\(id)"
    }
}
