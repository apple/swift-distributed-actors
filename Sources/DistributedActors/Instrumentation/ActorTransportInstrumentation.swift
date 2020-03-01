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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorTransportInstrumentation

// TODO: all these to accept trace context or something similar
public protocol ActorTransportInstrumentation {
    // FIXME: recipient address, not just path
    func remoteActorMessageSerializeStart(id: AnyObject, recipient: ActorPath, message: Any)
    func remoteActorMessageSerializeEnd(id: AnyObject, bytes: Int)
    // TODO: func remoteActorMessageSerializeFailed

    func remoteActorMessageDeserializeStart(id: AnyObject, recipient: ActorPath, bytes: Int)
    func remoteActorMessageDeserializeEnd(id: AnyObject, message: Any?)
    // TODO: func remoteActorMessageDeserializeEndFailed
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Noop ActorTransportInstrumentation

struct NoopActorTransportInstrumentation: ActorTransportInstrumentation {
    func remoteActorMessageSerializeStart(id: AnyObject, recipient: ActorPath, message: Any) {}

    func remoteActorMessageSerializeEnd(id: AnyObject, bytes: Int) {}

    func remoteActorMessageDeserializeStart(id: AnyObject, recipient: ActorPath, bytes: Int) {}

    func remoteActorMessageDeserializeEnd(id: AnyObject, message: Any?) {}
}
