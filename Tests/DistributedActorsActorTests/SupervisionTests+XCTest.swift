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

import XCTest

///
/// NOTE: This file was generated by generate_linux_tests.rb
///
/// Do NOT edit this file directly as it will be regenerated automatically when needed.
///

extension SupervisionTests {

   static var allTests : [(String, (SupervisionTests) -> () throws -> Void)] {
      return [
                ("test_compile", test_compile),
                ("test_stopSupervised_throws_shouldStop", test_stopSupervised_throws_shouldStop),
                ("test_restartSupervised_throws_shouldRestart", test_restartSupervised_throws_shouldRestart),
                ("test_stopSupervised_fatalError_shouldStop", test_stopSupervised_fatalError_shouldStop),
                ("test_restartSupervised_fatalError_shouldRestart", test_restartSupervised_fatalError_shouldRestart),
                ("test_wrappingWithSupervisionStrategy_shouldNotInfinitelyKeepGrowingTheBehaviorDepth", test_wrappingWithSupervisionStrategy_shouldNotInfinitelyKeepGrowingTheBehaviorDepth),
                ("test_wrappingWithSupervisionStrategy_shouldWrapProperlyIfDifferentStrategy", test_wrappingWithSupervisionStrategy_shouldWrapProperlyIfDifferentStrategy),
           ]
   }
}

