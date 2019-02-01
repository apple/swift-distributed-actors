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
                ("test_stopSupervised_throws_shouldStop", test_stopSupervised_throws_shouldStop),
                ("test_stopSupervised_fatalError_shouldStop", test_stopSupervised_fatalError_shouldStop),
                ("test_restartSupervised_fatalError_shouldRestart", test_restartSupervised_fatalError_shouldRestart),
                ("test_restartSupervised_throws_shouldRestart", test_restartSupervised_throws_shouldRestart),
                ("test_restartAtMostWithin_throws_shouldRestartNoMoreThanAllowedWithinPeriod", test_restartAtMostWithin_throws_shouldRestartNoMoreThanAllowedWithinPeriod),
                ("test_restartAtMostWithin_fatalError_shouldRestartNoMoreThanAllowedWithinPeriod", test_restartAtMostWithin_fatalError_shouldRestartNoMoreThanAllowedWithinPeriod),
                ("test_stopSupervised_divideByZero_shouldStop", test_stopSupervised_divideByZero_shouldStop),
                ("test_restartSupervised_divideByZero_shouldRestart", test_restartSupervised_divideByZero_shouldRestart),
                ("test_compositeSupervisor_shouldHandleUsingTheRightHandler", test_compositeSupervisor_shouldHandleUsingTheRightHandler),
                ("test_compositeSupervisor_shouldFaultHandleUsingTheRightHandler", test_compositeSupervisor_shouldFaultHandleUsingTheRightHandler),
                ("test_throwInSignalHandling_shouldRestart", test_throwInSignalHandling_shouldRestart),
                ("test_faultInSignalHandling_shouldRestart", test_faultInSignalHandling_shouldRestart),
                ("test_supervise_notSuperviseStackOverflow", test_supervise_notSuperviseStackOverflow),
                ("test_supervisor_shouldOnlyHandle_throwsOfSpecifiedErrorType", test_supervisor_shouldOnlyHandle_throwsOfSpecifiedErrorType),
                ("test_supervisor_shouldOnlyHandle_anyThrows", test_supervisor_shouldOnlyHandle_anyThrows),
                ("test_supervisor_shouldOnlyHandle_anyFault", test_supervisor_shouldOnlyHandle_anyFault),
                ("test_supervisor_shouldOnlyHandle_anyFailure", test_supervisor_shouldOnlyHandle_anyFailure),
                ("test_supervisor_throws_shouldCausePreRestartSignalBeforeRestarting", test_supervisor_throws_shouldCausePreRestartSignalBeforeRestarting),
                ("test_supervisor_fatalError_shouldCausePreRestartSignalBeforeRestarting", test_supervisor_fatalError_shouldCausePreRestartSignalBeforeRestarting),
                ("test_supervisedActor_shouldNotRestartedWhenCrashingInPostStop", test_supervisedActor_shouldNotRestartedWhenCrashingInPostStop),
                ("test_supervisor_throws_shouldRestartWhenFailingInDispatcheClosure", test_supervisor_throws_shouldRestartWhenFailingInDispatcheClosure),
                ("test_supervisor_fatalError_shouldRestartWhenFailingInDispatcheClosure", test_supervisor_fatalError_shouldRestartWhenFailingInDispatcheClosure),
           ]
   }
}

