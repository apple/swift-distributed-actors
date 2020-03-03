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
@available(iOS 10.0, *)
@available(tvOS 10.0, *)
@available(watchOS 3.0, *)
public struct OSSignpostActorTransportInstrumentation: ActorTransportInstrumentation {
    static let logTransportSerialization = OSLog(subsystem: "com.apple.actors", category: "Transport Serialization")

    let signpostID: OSSignpostID

    public init() {
        self.signpostID = OSSignpostID(
            log: OSSignpostActorTransportInstrumentation.logTransportSerialization
        )
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Instrumentation: Serialization

@available(OSX 10.14, *)
@available(iOS 10.0, *)
@available(tvOS 10.0, *)
@available(watchOS 3.0, *)
extension OSSignpostActorTransportInstrumentation {
    public func remoteActorMessageSerializeStart(id: AnyObject, recipient: ActorPath, message: Any) {
        guard OSSignpostActorTransportInstrumentation.logTransportSerialization.signpostsEnabled else {
            return
        }

        os_signpost(
            .begin,
            log: OSSignpostActorTransportInstrumentation.logTransportSerialization,
            name: "Actor Transport (Serialization)",
            signpostID: .init(log: OSSignpostActorTransportInstrumentation.logTransportSerialization, object: id),
            "serialize,recipient-node:%{public}s,recipient-path:%{public}s,type:%{public}s,message:%{public}s",
            "<node: todo>", "\(recipient)", String(reflecting: type(of: message)), "\(message)"
        )
    }

    public func remoteActorMessageSerializeEnd(id: AnyObject, bytes: Int) {
        guard OSSignpostActorTransportInstrumentation.logTransportSerialization.signpostsEnabled else {
            return
        }

        os_signpost(
            .end,
            log: OSSignpostActorTransportInstrumentation.logTransportSerialization,
            name: "Actor Transport (Serialization)",
            signpostID: .init(log: OSSignpostActorTransportInstrumentation.logTransportSerialization, object: id),
            "serialized,bytes:%ld",
            bytes
        )
    }

    public func remoteActorMessageDeserializeStart(id: AnyObject, recipient: ActorPath, bytes: Int) {
        guard OSSignpostActorTransportInstrumentation.logTransportSerialization.signpostsEnabled else {
            return
        }

        os_signpost(
            .begin,
            log: OSSignpostActorTransportInstrumentation.logTransportSerialization,
            name: "Actor Transport (Deserialization)",
            signpostID: .init(log: OSSignpostActorTransportInstrumentation.logTransportSerialization, object: id),
            "deserialize,recipient-node:%{public}s,recipient-path:%{public}s,bytes:%ld", // TODO: could carry type from manifest
            "<node: todo>", "\(recipient)", bytes
        )
    }

    public func remoteActorMessageDeserializeEnd(id: AnyObject, message: Any?) {
        guard OSSignpostActorTransportInstrumentation.logTransportSerialization.signpostsEnabled else {
            return
        }

        os_signpost(
            .end,
            log: OSSignpostActorTransportInstrumentation.logTransportSerialization,
            name: "Actor Transport (Deserialization)",
            signpostID: .init(log: OSSignpostActorTransportInstrumentation.logTransportSerialization, object: id),
            "deserialized,message:%{public}s,type:%{public}s",
            "\(message.map { "\($0)" } ?? "<nil>")", "\(message.map { String(reflecting: type(of: $0)) } ?? "<unknown-type>")"
        )
    }
}

#endif
