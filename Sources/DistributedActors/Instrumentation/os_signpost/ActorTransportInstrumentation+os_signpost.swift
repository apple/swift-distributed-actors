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
// MARK: Instrumentation

#if os(macOS) || os(tvOS) || os(iOS) || os(watchOS)
import Foundation
import os.log
import os.signpost

@available(OSX 10.14, *)
@available(iOS 12.0, *)
@available(tvOS 12.0, *)
@available(watchOS 3.0, *)
public struct OSSignpost_InternalActorTransportInstrumentation: _InternalActorTransportInstrumentation {
    static let subsystem: StaticString = "com.apple.actors"
    static let category: StaticString = "Serialization"

    static let logTransportSerialization = OSLog(subsystem: "\(Self.subsystem)", category: "\(Self.category)")

    static let nameSerialization: StaticString = "Transport (Serialization)"
    static let nameDeserialization: StaticString = "Transport (Deserialization)"

    let signpostID: OSSignpostID

    public init() {
        self.signpostID = OSSignpostID(
            log: OSSignpost_InternalActorTransportInstrumentation.logTransportSerialization
        )
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Instrumentation: Serialization

@available(OSX 10.14, *)
@available(iOS 12.0, *)
@available(tvOS 12.0, *)
@available(watchOS 3.0, *)
extension OSSignpost_InternalActorTransportInstrumentation {
    static let actorMessageSerializeStartPattern: StaticString =
        """
        serialize;\
        recipient-node:%{public}s;\
        recipient-path:%{public}s;\
        message-type:%{public}s;\
        message:%{public}s
        """
    static let actorMessageSerializeEndPattern: StaticString =
        """
        serialized;\
        bytes:%{public}d
        """

    static let actorMessageDeserializeStartPattern: StaticString =
        """
        deserialize;\
        recipient-node:%{public}s;\
        recipient-path:%{public}s;\
        bytes:%{public}d
        """
    static let actorMessageDeserializeEndPattern: StaticString =
        """
        deserialized;\
        message:%{public}s;\
        message-type:%{public}s
        """

    public func remoteActorMessageSerializeStart(id: AnyObject, recipient: ActorPath, message: Any) {
        guard OSSignpost_InternalActorTransportInstrumentation.logTransportSerialization.signpostsEnabled else {
            return
        }

        os_signpost(
            .begin,
            log: OSSignpost_InternalActorTransportInstrumentation.logTransportSerialization,
            name: Self.nameSerialization,
            signpostID: .init(log: OSSignpost_InternalActorTransportInstrumentation.logTransportSerialization, object: id),
            Self.actorMessageSerializeStartPattern,
            "todo", "\(recipient)", String(reflecting: type(of: message)), "\(message)"
        )
    }

    public func remoteActorMessageSerializeEnd(id: AnyObject, bytes: Int) {
        guard OSSignpost_InternalActorTransportInstrumentation.logTransportSerialization.signpostsEnabled else {
            return
        }

        os_signpost(
            .end,
            log: OSSignpost_InternalActorTransportInstrumentation.logTransportSerialization,
            name: Self.nameSerialization,
            signpostID: .init(log: OSSignpost_InternalActorTransportInstrumentation.logTransportSerialization, object: id),
            Self.actorMessageSerializeEndPattern,
            bytes
        )
    }

    public func remoteActorMessageDeserializeStart(id: AnyObject, recipient: ActorPath, bytes: Int) {
        guard OSSignpost_InternalActorTransportInstrumentation.logTransportSerialization.signpostsEnabled else {
            return
        }

        os_signpost(
            .begin,
            log: OSSignpost_InternalActorTransportInstrumentation.logTransportSerialization,
            name: Self.nameDeserialization,
            signpostID: .init(log: OSSignpost_InternalActorTransportInstrumentation.logTransportSerialization, object: id),
            Self.actorMessageDeserializeStartPattern,
            "todo", "\(recipient)", bytes
        )
    }

    public func remoteActorMessageDeserializeEnd(id: AnyObject, message: Any?) {
        guard OSSignpost_InternalActorTransportInstrumentation.logTransportSerialization.signpostsEnabled else {
            return
        }

        os_signpost(
            .end,
            log: OSSignpost_InternalActorTransportInstrumentation.logTransportSerialization,
            name: Self.nameDeserialization,
            signpostID: .init(log: OSSignpost_InternalActorTransportInstrumentation.logTransportSerialization, object: id),
            Self.actorMessageDeserializeEndPattern,
            "\(message.map { "\($0)" } ?? "<nil>")", "\(message.map { String(reflecting: type(of: $0)) } ?? "<unknown-type>")"
        )
    }
}

#endif
