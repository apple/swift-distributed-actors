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
import Logging
import NIO
import OpenTelemetry
import OtlpGRPCSpanExporting
import Tracing

struct Meal: Sendable, Codable {}

struct Meat: Sendable, Codable {}

struct Oven: Sendable, Codable {}

enum Vegetable: Sendable, Codable {
    case potato(chopped: Bool)
    case carrot(chopped: Bool)

    var asChopped: Self {
        switch self {
        case .carrot: return .carrot(chopped: true)
        case .potato: return .potato(chopped: true)
        }
    }
}
