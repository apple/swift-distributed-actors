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

public struct ClusterSingleton {
    private let system: ActorSystem

    internal init(system: ActorSystem) {
        self.system = system
    }

    public func ref<Message>(_ name: String, props: Props = Props(), _ behavior: Behavior<Message>) throws -> ActorRef<Message> {
        let settings = Settings(name: name)
        return try self.ref(settings: settings, props: props, behavior)
    }

    public func ref<Message>(settings: Settings, props: Props = Props(), _ behavior: Behavior<Message>) throws -> ActorRef<Message> {
        // TODO: keep track of existing refs so we don't spawn dupes
        let managerRef = try self.system.spawn(
            .prefixed(with: "$singletonManager-\(settings.name)"),
            ClusterSingletonManager(settings: settings, props: props, behavior).behavior
        )
        let proxyRef = try self.system.spawn(.prefixed(with: "$singletonProxy-\(settings.name)"), ClusterSingletonProxy(settings: settings, managerRef: managerRef).behavior)
        return proxyRef
    }
}

extension ClusterSingleton {
    public struct Settings {
        public let name: String

        public var bufferSize: Int = 100

        public init(name: String) {
            self.name = name
        }
    }
}
