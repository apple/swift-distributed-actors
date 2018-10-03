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

public class Supervision {

  public struct Failure {
    // TODO figure out how to represent failures, carry error code, actor path etc I think
  }

  // TODO settings for all of those
  public enum Directive {
    case resume
    case restart
    case backoffRestart // TODO exponential backoff settings, best as config object for easier extension?
    case stop
  }

}