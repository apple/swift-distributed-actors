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

extension BehaviorTests {

   static var allTests : [(String, (BehaviorTests) -> () throws -> Void)] {
      return [
                ("test_setup_executesImmediatelyOnStartOfActor", test_setup_executesImmediatelyOnStartOfActor),
                ("test_single_actor_should_wakeUp_on_new_message_lockstep", test_single_actor_should_wakeUp_on_new_message_lockstep),
                ("test_two_actors_should_wakeUp_on_new_message_lockstep", test_two_actors_should_wakeUp_on_new_message_lockstep),
                ("test_receive_shouldReceiveManyMessagesInExpectedOrder", test_receive_shouldReceiveManyMessagesInExpectedOrder),
                ("test_ClassBehavior_receivesMessages", test_ClassBehavior_receivesMessages),
                ("test_ClassBehavior_receivesSignals", test_ClassBehavior_receivesSignals),
                ("test_ClassBehavior_executesInitOnStartSignal", test_ClassBehavior_executesInitOnStartSignal),
                ("test_receiveSpecificSignal_shouldReceiveAsExpected", test_receiveSpecificSignal_shouldReceiveAsExpected),
                ("test_receiveSpecificSignal_shouldNotReceiveOtherSignals", test_receiveSpecificSignal_shouldNotReceiveOtherSignals),
                ("test_orElse_shouldExecuteFirstBehavior", test_orElse_shouldExecuteFirstBehavior),
                ("test_orElse_shouldExecuteSecondBehavior", test_orElse_shouldExecuteSecondBehavior),
                ("test_orElse_shouldNotExecuteSecondBehaviorOnIgnore", test_orElse_shouldNotExecuteSecondBehaviorOnIgnore),
                ("test_orElse_shouldProperlyHandleDeeplyNestedBehaviors", test_orElse_shouldProperlyHandleDeeplyNestedBehaviors),
                ("test_orElse_shouldProperlyApplyTerminatedToSecondBehaviorBeforeCausingDeathPactError", test_orElse_shouldProperlyApplyTerminatedToSecondBehaviorBeforeCausingDeathPactError),
                ("test_orElse_shouldCanonicalizeNestedSetupInAlternative", test_orElse_shouldCanonicalizeNestedSetupInAlternative),
                ("test_stoppedWithPostStop_shouldTriggerPostStopCallback", test_stoppedWithPostStop_shouldTriggerPostStopCallback),
                ("test_stoppedWithPostStopThrows_shouldTerminate", test_stoppedWithPostStopThrows_shouldTerminate),
                ("test_makeAsynchronousCallback_shouldExecuteClosureInActorContext", test_makeAsynchronousCallback_shouldExecuteClosureInActorContext),
                ("test_myself_shouldStayValidAfterActorStopped", test_myself_shouldStayValidAfterActorStopped),
                ("test_suspendedActor_shouldBeUnsuspendedOnResumeSystemMessage", test_suspendedActor_shouldBeUnsuspendedOnResumeSystemMessage),
                ("test_suspendedActor_shouldStaySuspendedWhenResumeHandlerSuspendsAgain", test_suspendedActor_shouldStaySuspendedWhenResumeHandlerSuspendsAgain),
                ("test_suspendedActor_shouldBeUnsuspendedOnFailedResumeSystemMessage", test_suspendedActor_shouldBeUnsuspendedOnFailedResumeSystemMessage),
                ("test_awaitResult_shouldResumeActorWithSuccessResultWhenFutureSucceeds", test_awaitResult_shouldResumeActorWithSuccessResultWhenFutureSucceeds),
                ("test_awaitResult_shouldResumeActorWithFailureResultWhenFutureFails", test_awaitResult_shouldResumeActorWithFailureResultWhenFutureFails),
                ("test_awaitResultThrowing_shouldResumeActorSuccessResultWhenFutureSucceeds", test_awaitResultThrowing_shouldResumeActorSuccessResultWhenFutureSucceeds),
                ("test_awaitResultThrowing_shouldCrashActorWhenFutureFails", test_awaitResultThrowing_shouldCrashActorWhenFutureFails),
                ("test_awaitResult_shouldResumeActorWithFailureResultWhenFutureTimesOut", test_awaitResult_shouldResumeActorWithFailureResultWhenFutureTimesOut),
                ("test_awaitResult_shouldWorkWhenReturnedInsideInitialSetup", test_awaitResult_shouldWorkWhenReturnedInsideInitialSetup),
                ("test_awaitResult_shouldCrashWhenReturnedInsideInitialSetup_andReturnSameOnResume", test_awaitResult_shouldCrashWhenReturnedInsideInitialSetup_andReturnSameOnResume),
                ("test_awaitResultThrowing_shouldCrashActorWhenFutureTimesOut", test_awaitResultThrowing_shouldCrashActorWhenFutureTimesOut),
                ("test_suspendedActor_shouldKeepProcessingSystemMessages", test_suspendedActor_shouldKeepProcessingSystemMessages),
                ("test_suspendedActor_shouldKeepProcessingSignals", test_suspendedActor_shouldKeepProcessingSignals),
                ("test_suspendedActor_shouldStopWhenSignalHandlerReturnsStopped", test_suspendedActor_shouldStopWhenSignalHandlerReturnsStopped),
                ("test_onResultAsync_shouldExecuteContinuationWhenFutureSucceeds", test_onResultAsync_shouldExecuteContinuationWhenFutureSucceeds),
                ("test_onResultAsync_shouldExecuteContinuationWhenFutureFails", test_onResultAsync_shouldExecuteContinuationWhenFutureFails),
                ("test_onResultAsync_shouldAssignBehaviorFromContinuationWhenFutureSucceeds", test_onResultAsync_shouldAssignBehaviorFromContinuationWhenFutureSucceeds),
                ("test_onResultAsync_shouldCanonicalizeBehaviorFromContinuationWhenFutureSucceeds", test_onResultAsync_shouldCanonicalizeBehaviorFromContinuationWhenFutureSucceeds),
                ("test_onResultAsync_shouldKeepProcessingMessagesWhileFutureIsNotCompleted", test_onResultAsync_shouldKeepProcessingMessagesWhileFutureIsNotCompleted),
                ("test_onResultAsync_shouldAllowChangingBehaviorWhileFutureIsNotCompleted", test_onResultAsync_shouldAllowChangingBehaviorWhileFutureIsNotCompleted),
                ("test_onResultAsyncThrowing_shouldExecuteContinuationWhenFutureSucceeds", test_onResultAsyncThrowing_shouldExecuteContinuationWhenFutureSucceeds),
                ("test_onResultAsyncThrowing_shouldFailActorWhenFutureFails", test_onResultAsyncThrowing_shouldFailActorWhenFutureFails),
           ]
   }
}

