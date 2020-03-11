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
//

@testable import DistributedActors
import DistributedActorsTestKit
import Foundation
import NIO
import NIOFoundationCompat
import XCTest

final class SerializationEvolutionClusteredTests: ClusteredNodesTestBase {
    func test_one() {
        let first = self.setUpNode("first") { _ in
        }
        let second = self.setUpNode("first") { _ in
        }
    }

    func test_serialization_evolution() throws {
        let oldFirst = self.setUpNode("oldFirst") { _ in
        }
        let newSecond = self.setUpNode("newSecond") { _ in
//            settings.serialization.safeList(Top.self)
//            settings.serialization.safeList(OldMid.self)
//            settings.serialization.safeList(Mid.self)
//
//            settings.serialization.mapInbound(manifest: .init(serializerID: .jsonCodable, hint: "Mid"), as: .init(serializerID: .jsonCodable, hint: "OldMid"))
        }

        let p = self.testKit(oldFirst).spawnTestProbe(expecting: String.self)

        let newTwo = try newSecond.spawn("newTwo", of: Mid.self.receive { context, message in
            p.ref.tell("\(context.path.name):\(message)")
            return .stop
        })

        _ = oldFirst.spawn("oldOne", of: Mid.self.setup { _ in
            two.tell(Mid())
            return .stop
        })

        try p.expectMessage("x")
    }
}

// MARK: Example types for serialization tests

private protocol Top: Hashable, Codable {
    var path: ActorPath { get }
}

private class OldMid: Top, Hashable {
    let oldPathName: ActorPath
}

private class Mid: Top, Hashable {
    let _path: ActorPath

    init() {
        self._path = try! ActorPath(root: "hello")
    }

    var path: ActorPath {
        return self._path
    }

    func hash(into hasher: inout Hasher) {
        self._path.hash(into: &hasher)
    }

    static func == (lhs: Mid, rhs: Mid) -> Bool {
        return lhs.path == rhs.path
    }
}

private struct HasStringRef: Codable, Equatable {
    let containedRef: ActorRef<String>
}

private struct HasIntRef: Codable, Equatable {
    let containedRef: ActorRef<Int>
}

private struct InterestingMessage: Codable, Equatable {}
private struct HasInterestingMessageRef: Codable, Equatable {
    let containedInterestingRef: ActorRef<InterestingMessage>
}

/// This is quite an UNUSUAL case, as `ReceivesSystemMessages` is internal, and thus, no user code shall ever send it
/// verbatim like this. We may however, need to send them for some reason internally, and it might be nice to use Codable if we do.
///
/// Since the type is internal, the automatic derivation does not function, and some manual work is needed, which is fine,
/// as we do not expect this case to happen often (or at all), however if the need were to arise, the ReceivesSystemMessagesDecoder
/// enables us to handle this rather easily.
private struct HasReceivesSystemMsgs: Codable {
    let sysRef: _ReceivesSystemMessages

    init(sysRef: _ReceivesSystemMessages) {
        self.sysRef = sysRef
    }

    init(from decoder: Decoder) throws {
        self.sysRef = try ReceivesSystemMessagesDecoder.decode(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try self.sysRef.encode(to: encoder)
    }
}

private struct NotCodableHasInt: Equatable {
    let containedInt: Int
}

private struct NotCodableHasIntRef: Equatable {
    let containedRef: ActorRef<Int>
}

private struct NotSerializable {
    let pos: String

    init(_ pos: String) {
        self.pos = pos
    }
}
