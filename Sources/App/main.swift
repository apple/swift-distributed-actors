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


import Swift Distributed ActorsActor
import NIOConcurrencyHelpers
import Foundation

// MARK: Test Harness

var warning: String = ""
assert({
  print("======================================================")
  print("= YOU ARE RUNNING NIOPerformanceTester IN DEBUG MODE =")
  print("======================================================")
  warning = " <<< DEBUG MODE >>>"
  return true
  }())

public func measure(_ fn: () throws -> Int) rethrows -> [TimeInterval] {
  func measureOne(_ fn: () throws -> Int) rethrows -> TimeInterval {
    let start = Date()
    _ = try fn()
    let end = Date()
    return end.timeIntervalSince(start)
  }

  _ = try measureOne(fn) /* pre-heat and throw away */
  var measurements = Array(repeating: 0.0, count: 10)
  for i in 0..<10 {
     measurements[i] = try measureOne(fn)
  }
  return measurements
}

public func measureAndPrint(desc: String, fn: () throws -> Int) rethrows -> Void {
  print("measuring\(warning): \(desc): ", terminator: "")
  let measurements = try measure(fn)
  print(measurements.reduce("") { $0 + "\($1), " })
}



let system = ActorSystem()

let n = 5_000_000

measureAndPrint(desc: "receive \(n) messages") {
  let l = Swift Distributed ActorsActor.Mutex()
  let c = Swift Distributed ActorsActor.Condition()

  let ref: ActorRef<Int> = try! system.spawnAnonymous(.receiveMessage { msg in
    if msg == n {
      c.signal()
    }
    return .same
    })

  l.lock()
  for i in 1 ... n {
    ref ! i
  }
  c.wait(l)

  return n
}
