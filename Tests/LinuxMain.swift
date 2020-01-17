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

#if os(Linux) || os(FreeBSD)
@testable import ActorSingletonPluginTests
@testable import CDistributedActorsMailboxTests
@testable import DistributedActorsConcurrencyHelpersTests
@testable import DistributedActorsTestKitTests
@testable import DistributedActorsTests
@testable import GenActorsTests

XCTMain([
    testCase(ActorAddressTests.allTests),
    testCase(ActorAskTests.allTests),
    testCase(ActorContextReceptionTests.allTests),
    testCase(ActorDeferTests.allTests),
    testCase(ActorIsolationFailureHandlingTests.allTests),
    testCase(ActorLeakingTests.allTests),
    testCase(ActorLifecycleTests.allTests),
    testCase(ActorLoggingTests.allTests),
    testCase(ActorMemoryTests.allTests),
    testCase(ActorNamingTests.allTests),
    testCase(ActorRefAdapterTests.allTests),
    testCase(ActorSingletonPluginTests.allTests),
    testCase(ActorSubReceiveTests.allTests),
    testCase(ActorSystemTests.allTests),
    testCase(ActorTestKitTests.allTests),
    testCase(ActorTestProbeTests.allTests),
    testCase(ActorableOwnedMembershipTests.allTests),
    testCase(BackoffStrategyTests.allTests),
    testCase(BehaviorCanonicalizeTests.allTests),
    testCase(BehaviorTests.allTests),
    testCase(BlockingReceptacleTests.allTests),
    testCase(CMPSCLinkedQueueTests.allTests),
    testCase(CRDTActorOwnedTests.allTests),
    testCase(CRDTAnyTypesTests.allTests),
    testCase(CRDTEnvelopeSerializationTests.allTests),
    testCase(CRDTGCounterTests.allTests),
    testCase(CRDTLWWMapTests.allTests),
    testCase(CRDTLWWRegisterTests.allTests),
    testCase(CRDTORMapTests.allTests),
    testCase(CRDTORSetTests.allTests),
    testCase(CRDTReplicationSerializationTests.allTests),
    testCase(CRDTReplicatorInstanceTests.allTests),
    testCase(CRDTReplicatorShellTests.allTests),
    testCase(CRDTSerializationTests.allTests),
    testCase(CRDTVersioningTests.allTests),
    testCase(ClusterAssociationTests.allTests),
    testCase(ClusterEventStreamTests.allTests),
    testCase(ClusterEventsSerializationTests.allTests),
    testCase(ClusterLeaderActionsTests.allTests),
    testCase(ClusterMembershipGossipTests.allTests),
    testCase(ClusterOnDownActionTests.allTests),
    testCase(ClusterReceptionistTests.allTests),
    testCase(ConcurrencyHelpersTests.allTests),
    testCase(CustomStringInterpolationTests.allTests),
    testCase(DeadLetterTests.allTests),
    testCase(DeadlineTests.allTests),
    testCase(DeathWatchTests.allTests),
    testCase(DispatcherTests.allTests),
    testCase(EventStreamTests.allTests),
    testCase(FixedThreadPoolTests.allTests),
    testCase(GenCodableTests.allTests),
    testCase(GenerateActorsTests.allTests),
    testCase(HeapTests.allTests),
    testCase(InterceptorTests.allTests),
    testCase(LamportClockTests.allTests),
    testCase(LeadershipTests.allTests),
    testCase(MPSCLinkedQueueTests.allTests),
    testCase(MailboxTests.allTests),
    testCase(MembershipGossipSeenTableTests.allTests),
    testCase(MembershipGossipTests.allTests),
    testCase(MembershipSerializationTests.allTests),
    testCase(MembershipTests.allTests),
    testCase(NIOExtensionTests.allTests),
    testCase(NodeDeathWatcherTests.allTests),
    testCase(NodeTests.allTests),
    testCase(ParentChildActorTests.allTests),
    testCase(PeriodicBroadcastTests.allTests),
    testCase(ProtoEnvelopeTests.allTests),
    testCase(ProtobufRoundTripTests.allTests),
    testCase(ReceptionistTests.allTests),
    testCase(RemoteActorRefProviderTests.allTests),
    testCase(RemoteHandshakeStateMachineTests.allTests),
    testCase(RemoteMessagingTests.allTests),
    testCase(RemotingTLSTests.allTests),
    testCase(RingBufferTests.allTests),
    testCase(SWIMInstanceClusterTests.allTests),
    testCase(SWIMInstanceTests.allTests),
    testCase(SWIMSerializationTests.allTests),
    testCase(SWIMShellTests.allTests),
    testCase(SerializationPoolTests.allTests),
    testCase(SerializationTests.allTests),
    testCase(ShootTheOtherNodeClusteredTests.allTests),
    testCase(StashBufferTests.allTests),
    testCase(SupervisionTests.allTests),
    testCase(SystemMessageRedeliveryHandlerTests.allTests),
    testCase(SystemMessagesRedeliveryTests.allTests),
    testCase(TimeAmountTests.allTests),
    testCase(TimeSpecTests.allTests),
    testCase(TimeoutBasedDowningInstanceTests.allTests),
    testCase(TimersTests.allTests),
    testCase(TraversalTests.allTests),
    testCase(VersionVectorSerializationTests.allTests),
    testCase(VersionVectorTests.allTests),
    testCase(WorkerPoolTests.allTests),
])
#endif
