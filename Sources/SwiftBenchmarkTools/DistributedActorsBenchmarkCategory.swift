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

public enum BenchmarkCategory : String {
    // Serialization benchmarks
    case serialization

    // Most benchmarks are assumed to be "stable" and will be regularly tracked at
    // each commit. A handful may be marked unstable if continually tracking them is
    // counterproductive.
    case unstable

    // Explicit skip marker
    case skip
}
