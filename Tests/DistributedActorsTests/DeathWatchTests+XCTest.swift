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

extension DeathWatchTests {
    static var allTests: [(String, (DeathWatchTests) -> () throws -> Void)] {
        return [
            ("test_watch_shouldTriggerTerminatedWhenWatchedActorStops", test_watch_shouldTriggerTerminatedWhenWatchedActorStops),
            ("test_watch_fromMultipleActors_shouldTriggerTerminatedWhenWatchedActorStops", test_watch_fromMultipleActors_shouldTriggerTerminatedWhenWatchedActorStops),
            ("test_watch_fromMultipleActors_shouldNotifyOfTerminationOnlyCurrentWatchers", test_watch_fromMultipleActors_shouldNotifyOfTerminationOnlyCurrentWatchers),
            ("test_minimized_deathPact_shouldTriggerForWatchedActor", test_minimized_deathPact_shouldTriggerForWatchedActor),
            ("test_minimized_deathPact_shouldNotTriggerForActorThatWasWatchedButIsNotAnymoreWhenTerminatedArrives", test_minimized_deathPact_shouldNotTriggerForActorThatWasWatchedButIsNotAnymoreWhenTerminatedArrives),
            ("test_watch_anAlreadyStoppedActorRefShouldReplyWithTerminated", test_watch_anAlreadyStoppedActorRefShouldReplyWithTerminated),
            ("test_deathPact_shouldMakeWatcherKillItselfWhenWatcheeStops", test_deathPact_shouldMakeWatcherKillItselfWhenWatcheeStops),
            ("test_deathPact_shouldMakeWatcherKillItselfWhenWatcheeThrows", test_deathPact_shouldMakeWatcherKillItselfWhenWatcheeThrows),
            ("test_sendingToStoppedRef_shouldNotCrash", test_sendingToStoppedRef_shouldNotCrash),
        ]
    }
}
