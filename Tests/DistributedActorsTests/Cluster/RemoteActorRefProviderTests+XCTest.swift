//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
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

extension RemoteActorRefProviderTests {
    static var allTests: [(String, (RemoteActorRefProviderTests) -> () throws -> Void)] {
        return [
            ("test_remoteActorRefProvider_shouldMakeRemoteRef_givenSomeRemotePath", test_remoteActorRefProvider_shouldMakeRemoteRef_givenSomeRemotePath),
            ("test_remoteActorRefProvider_shouldResolveDeadRef_forTypeMismatchOfActorAndResolveContext", test_remoteActorRefProvider_shouldResolveDeadRef_forTypeMismatchOfActorAndResolveContext),
            ("test_remoteActorRefProvider_shouldResolveSameAsLocalNodeDeadLettersRef_forTypeMismatchOfActorAndResolveContext", test_remoteActorRefProvider_shouldResolveSameAsLocalNodeDeadLettersRef_forTypeMismatchOfActorAndResolveContext),
            ("test_remoteActorRefProvider_shouldResolveRemoteDeadLettersRef_forTypeMismatchOfActorAndResolveContext", test_remoteActorRefProvider_shouldResolveRemoteDeadLettersRef_forTypeMismatchOfActorAndResolveContext),
            ("test_remoteActorRefProvider_shouldResolveRemoteAlreadyDeadRef_forTypeMismatchOfActorAndResolveContext", test_remoteActorRefProvider_shouldResolveRemoteAlreadyDeadRef_forTypeMismatchOfActorAndResolveContext),
            ("test_remoteActorRefProvider_shouldResolveDeadRef_forSerializedDeadLettersRef", test_remoteActorRefProvider_shouldResolveDeadRef_forSerializedDeadLettersRef),
        ]
    }
}
