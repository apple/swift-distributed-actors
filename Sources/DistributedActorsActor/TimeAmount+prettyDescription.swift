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


import Foundation
import NIO

/// "Pretty" time amount rendering, useful for human readable durations in tests
extension TimeAmount {

  public var prettyDescription: String {
    return self.prettyDescription()
  }

  public func prettyDescription(precision: Int = 2) -> String {
    assert(precision > 0, "precision MUST BE > 0")
    var res = ""

    var remaining = self
    var i = 0
    while i < precision {
      let unit = chooseUnit(remaining.nanoseconds)

      let rounded: Int = remaining.nanoseconds / unit.rawValue
      if rounded > 0 {
        res += i > 0 ? " " : ""
        res += "\(rounded)\(unit.abbreviated)"

        remaining = TimeAmount.nanoseconds(remaining.nanoseconds - unit.timeAmount(rounded).nanoseconds)
        i += 1
      } else {
        break
      }
    }

    return res
  }

  private func chooseUnit(_ ns: Value) -> TimeUnit {
    //@formatter:off
    if ns / TimeUnit.days.rawValue > 0 { return TimeUnit.days }
    else if ns / TimeUnit.hours.rawValue > 0 { return TimeUnit.hours }
    else if ns / TimeUnit.minutes.rawValue > 0 { return TimeUnit.minutes }
    else if ns / TimeUnit.seconds.rawValue > 0 { return TimeUnit.seconds }
    else if ns / TimeUnit.milliseconds.rawValue > 0 { return TimeUnit.milliseconds }
    else if ns / TimeUnit.microseconds.rawValue > 0 { return TimeUnit.microseconds }
    else { return TimeUnit.nanoseconds }
    //@formatter:on
  }

  #if arch(arm) || arch(i386)
  // Int64 is the correct type here but we don't want to break SemVer so can't change it for the 64-bit platforms.
  // To be fixed in NIO 2.0
  public typealias Value = Int64
  #else
  // 64-bit, keeping that at Int for SemVer in the 1.x line.
  public typealias Value = Int
  #endif

  /// Represents number of nanoseconds within given time unit
  enum TimeUnit: Value {
    //@formatter:off
    case days         = 86_400_000_000_000
    case hours        =  3_600_000_000_000
    case minutes      =     60_000_000_000
    case seconds      =      1_000_000_000
    case milliseconds =          1_000_000
    case microseconds =              1_000
    case nanoseconds  =                  1
    //@formatter:on

    var abbreviated: String {
      switch self {
      case .nanoseconds: return "ns"
      case .microseconds: return "μs"
      case .milliseconds: return "ms"
      case .seconds: return "s"
      case .minutes: return "m"
      case .hours: return "h"
      case .days: return "d"
      }
    }

    func timeAmount(_ amount: Int) -> TimeAmount {
      switch self {
      case .nanoseconds: return .nanoseconds(amount)
      case .microseconds: return .microseconds(amount)
      case .milliseconds: return .milliseconds(amount)
      case .seconds: return .seconds(amount)
      case .minutes: return .minutes(amount)
      case .hours: return .hours(amount)
      case .days: return .hours(amount * 24)
      }
    }

  }
}
