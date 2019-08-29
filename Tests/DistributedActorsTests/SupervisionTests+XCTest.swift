//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
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
    static var allTests: [(String, (SupervisionTests) -> () throws -> Void)] {
        return [
            ("test_stopSupervised_throws_shouldStop", test_stopSupervised_throws_shouldStop),
            ("test_restartSupervised_throws_shouldRestart", test_restartSupervised_throws_shouldRestart),
            ("test_restartAtMostWithin_throws_shouldRestartNoMoreThanAllowedWithinPeriod", test_restartAtMostWithin_throws_shouldRestartNoMoreThanAllowedWithinPeriod),
            ("test_restartSupervised_throws_shouldRestart_andCreateNewInstanceOfClassBehavior", test_restartSupervised_throws_shouldRestart_andCreateNewInstanceOfClassBehavior),
            ("test_restart_throws_shouldHandleFailureWhenInterpretingStart", test_restart_throws_shouldHandleFailureWhenInterpretingStart),
            ("test_restartSupervised_throws_shouldRestartWithConstantBackoff", test_restartSupervised_throws_shouldRestartWithConstantBackoff),
            ("test_restartSupervised_throws_shouldRestartWithExponentialBackoff", test_restartSupervised_throws_shouldRestartWithExponentialBackoff),
            ("test_restart_throws_shouldHandleFailureWhenInterpretingStartAfterFailure", test_restart_throws_shouldHandleFailureWhenInterpretingStartAfterFailure),
            ("test_restart_throws_shouldFailAfterMaxFailuresInSetup", test_restart_throws_shouldFailAfterMaxFailuresInSetup),
            ("test_compositeSupervisor_shouldHandleUsingTheRightHandler", test_compositeSupervisor_shouldHandleUsingTheRightHandler),
            ("test_throwInSignalHandling_shouldRestart", test_throwInSignalHandling_shouldRestart),
            ("test_supervise_notSuperviseStackOverflow", test_supervise_notSuperviseStackOverflow),
            ("test_supervisor_shouldOnlyHandle_throwsOfSpecifiedErrorType", test_supervisor_shouldOnlyHandle_throwsOfSpecifiedErrorType),
            ("test_supervisor_shouldOnlyHandle_anyThrows", test_supervisor_shouldOnlyHandle_anyThrows),
            ("test_supervisor_throws_shouldCausePreRestartSignalBeforeRestarting", test_supervisor_throws_shouldCausePreRestartSignalBeforeRestarting),
            ("test_supervisor_throws_shouldFailIrrecoverablyIfFailingToHandle_PreRestartSignal", test_supervisor_throws_shouldFailIrrecoverablyIfFailingToHandle_PreRestartSignal),
            ("test_supervisor_throws_shouldFailIrrecoverablyIfFailingToHandle_PreRestartSignal_withBackoff", test_supervisor_throws_shouldFailIrrecoverablyIfFailingToHandle_PreRestartSignal_withBackoff),
            ("test_supervisedActor_shouldNotRestartedWhenCrashingInPostStop", test_supervisedActor_shouldNotRestartedWhenCrashingInPostStop),
            ("test_supervisor_throws_shouldRestartWhenFailingInDispatchedClosure", test_supervisor_throws_shouldRestartWhenFailingInDispatchedClosure),
            ("test_supervisor_awaitResult_shouldInvokeSupervisionOnThrow", test_supervisor_awaitResult_shouldInvokeSupervisionOnThrow),
            ("test_supervisor_awaitResultThrowing_shouldInvokeSupervisionOnFailure", test_supervisor_awaitResultThrowing_shouldInvokeSupervisionOnFailure),
        ]
    }
}
