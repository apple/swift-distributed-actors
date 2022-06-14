//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//


import Distributed
import DistributedActors
import XCTest

public nonisolated func assertRemoteActor<DA: DistributedActor>(_ actor: DA) throws {
    if __isRemoteActor(actor) {
        return
    } else {
        throw DistributedActorAssertError.expectedRemote(actor)
    }
}

public nonisolated func assertLocalActor<DA: DistributedActor>(_ actor: DA) throws {
    if !__isRemoteActor(actor) {
        return
    } else {
        throw DistributedActorAssertError.expectedRemote(actor)
    }
}

public enum DistributedActorAssertError: Error {
    case expectedRemote(any DistributedActor)
    case expectedLocal(any DistributedActor)
}
