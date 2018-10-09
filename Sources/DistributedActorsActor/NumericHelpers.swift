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
// Created by Konrad Malawski on 2018-10-10.
//

import Foundation

extension Int {

  var binaryStringRepresentation: String {
    var repr = ""
    for bit in 0...self.bitWidth {
      repr += (self & bit) == 0 ? "0" : "1"
    }

    return repr
  }

}