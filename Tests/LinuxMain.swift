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

#if os(Linux) || os(FreeBSD)
   @testable import CSwiftDistributedActorsMailboxTests
   @testable import DistributedActorsConcurrencyHelpersTests
   @testable import SwiftDistributedActorsActorTestKitTests
   @testable import Swift Distributed ActorsActorTests

   XCTMain([
         testCase(ActorAddressTests.allTests),
         testCase(ActorAskTests.allTests),
         testCase(ActorDeferTests.allTests),
         testCase(ActorIsolationFailureHandlingTests.allTests),
         testCase(ActorLeakingTests.allTests),
         testCase(ActorLifecycleTests.allTests),
         testCase(ActorLoggingTests.allTests),
         testCase(ActorRefAdapterTests.allTests),
         testCase(ActorSubReceiveTests.allTests),
         testCase(ActorSystemTests.allTests),
         testCase(ActorTestKitTests.allTests),
         testCase(ActorTestProbeTests.allTests),
         testCase(AnonymousNamesGeneratorTests.allTests),
         testCase(BackoffStrategyTests.allTests),
         testCase(BehaviorCanonicalizeTests.allTests),
         testCase(BehaviorTests.allTests),
         testCase(BlockingReceptacleTests.allTests),
         testCase(CMPSCLinkedQueueTests.allTests),
         testCase(CMailboxTests.allTests),
         testCase(ClusterAssociationTests.allTests),
         testCase(ClusterReceptionistTests.allTests),
         testCase(ConcurrencyHelpersTests.allTests),
         testCase(CustomStringInterpolationTests.allTests),
         testCase(DeadLetterTests.allTests),
         testCase(DeadlineTests.allTests),
         testCase(DeathWatchTests.allTests),
         testCase(DispatcherTests.allTests),
         testCase(FailureDetectorTests.allTests),
         testCase(FixedThreadPoolTests.allTests),
         testCase(HeapTests.allTests),
         testCase(InterceptorTests.allTests),
         testCase(MPSCLinkedQueueTests.allTests),
         testCase(MembershipTests.allTests),
         testCase(NIOExtensionTests.allTests),
         testCase(ParentChildActorTests.allTests),
         testCase(ProtoEnvelopeTests.allTests),
         testCase(ProtobufRoundTripTests.allTests),
         testCase(ReceptionistTests.allTests),
         testCase(RemoteActorRefProviderTests.allTests),
         testCase(RemoteHandshakeStateMachineTests.allTests),
         testCase(RemotingMessagingTests.allTests),
         testCase(RemotingTLSTests.allTests),
         testCase(RingBufferTests.allTests),
         testCase(SWIMInstanceClusterTests.allTests),
         testCase(SWIMInstanceTests.allTests),
         testCase(SWIMMembershipShellTests.allTests),
         testCase(SWIMSerializationTests.allTests),
         testCase(SerializationPoolTests.allTests),
         testCase(SerializationTests.allTests),
         testCase(StashBufferTests.allTests),
         testCase(SupervisionTests.allTests),
         testCase(SystemMessageRedeliveryHandlerTests.allTests),
         testCase(SystemMessagesRedeliveryTests.allTests),
         testCase(TimeAmountTests.allTests),
         testCase(TimeSpecTests.allTests),
         testCase(TimeoutBasedDowningInstanceTests.allTests),
         testCase(TimersTests.allTests),
         testCase(TraversalTests.allTests),
         testCase(UniqueNodeTests.allTests),
         testCase(WorkerPoolTests.allTests),
    ])
#endif
