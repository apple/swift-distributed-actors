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


import SwiftBenchmarkTools

assert({
    print("==========================================================")
    print("= YOU ARE RUNNING Swift Distributed ActorsPerformanceTester IN DEBUG MODE =")
    print("==========================================================")
    return true
}())

@inline(__always)
private func registerBenchmark(_ bench: BenchmarkInfo) {
    registeredBenchmarks.append(bench)
}
@inline(__always)
private func registerBenchmark(_ benches: [BenchmarkInfo]) {
    benches.forEach(registerBenchmark)
}
@inline(__always)
private func registerBenchmark(_ name: String, _ function: @escaping (Int) -> (), _ tags: [BenchmarkCategory]) {
    registerBenchmark(BenchmarkInfo(name: name, runFunction: function, tags: tags))
}

registerBenchmark(ActorPathBenchmarks)

main()
