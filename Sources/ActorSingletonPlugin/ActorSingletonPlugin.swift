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

import DistributedActors

extension Plugin {
    public static func singleton(_ settings: ActorSingletonPluginSettings = .default) -> ActorSingletonPlugin {
        ActorSingletonPlugin(settings: settings)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor singleton plugin

public final class ActorSingletonPlugin {
    /// All singletons defined in `ActorSingletonPluginSettings`
    private let singletons: [String: BoxedActorSingleton]

    private var ref: ActorRef<ActorSingletonShell.Message>!

    /// Creates `ActorSingletonPlugin` from `settings`.
    public init(settings: ActorSingletonPluginSettings) {
        self.singletons = settings.singletons
    }

    /// Returns `ActorRef` for the singleton identified by `name`.
    ///
    /// The singleton must have been set up via `ActorSingletonPluginSettings`.
    public func ref<Message>(name: String) -> Result<ActorRef<Message>, ActorSingletonError> {
        guard let boxed = self.singletons[name] else {
            return .failure(.unknown(name: name))
        }
        return .success(boxed.unsafeUnwrapAs(Message.self).proxy)
    }

    /// Adds `subscriber` to `AllocationStrategy`-relevant events, sent by `ActorSingletonShell`.
    internal func subscribeToAllocationStrategyEvents(_ subscriber: ActorRef<AllocationStrategyEvent>) {
        self.ref.tell(.subscribeToAllocationStrategyEvents(subscriber))
    }
}

extension ActorSingletonPlugin: Plugin {
    public static let key: PluginKey<ActorSingletonPlugin> = "actorSingleton"

    public func start(_ system: ActorSystem) -> Result<Void, Error> {
        do {
            self.ref = try! system.spawn(ActorSingletonShell.naming, ActorSingletonShell().behavior)

            try self.singletons.values.forEach { singleton in
                try singleton.spawnProxy(system)
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    public func stop(_: ActorSystem) -> Result<Void, Error> {
        self.ref?.tell(.stop)
        return .success(())
    }
}

public enum ActorSingletonError: Error {
    /// A singleton with `name` already exists.
    case nameAlreadyExists(String)
    /// There is no registered singleton identified by `name`.
    case unknown(name: String)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Settings for `ActorSingletonPlugin`

public struct ActorSingletonPluginSettings {
    public static var `default`: ActorSingletonPluginSettings {
        .init()
    }

    internal var singletons: [String: BoxedActorSingleton] = [:]

    public init() {}

    /// Adds a `ActorSingleton`.
    public mutating func add<Message>(_ singleton: ActorSingleton<Message>) -> Result<Void, ActorSingletonError> {
        guard self.singletons[singleton.settings.name] == nil else {
            return .failure(.nameAlreadyExists(singleton.settings.name))
        }

        self.singletons[singleton.settings.name] = BoxedActorSingleton(singleton)

        return .success(())
    }

    /// Adds a `behavior` as singleton with `settings`.
    public mutating func add<Message>(settings: ActorSingletonSettings, props: Props = Props(), _ behavior: Behavior<Message>) -> Result<Void, ActorSingletonError> {
        let singleton = ActorSingleton(settings: settings, props: props, behavior)
        return self.add(singleton)
    }

    /// Adds a `behavior` as singleton identified by `name`.
    public mutating func add<Message>(_ name: String, props: Props = Props(), _ behavior: Behavior<Message>) -> Result<Void, ActorSingletonError> {
        let singleton = ActorSingleton(name, props: props, behavior)
        return self.add(singleton)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor singleton shell

internal class ActorSingletonShell {
    static let naming: ActorNaming = .unique("actorSingleton")

    init() {}

    var behavior: Behavior<Message> {
        .setup { context in
            var subscribers: [ActorAddress: ActorRef<AllocationStrategyEvent>] = [:]

            // Publish `AllocationStrategy`-relevant events to `subscribers`
            context.system.cluster.events.subscribe(context.subReceive(ClusterEvent.self) { event in
                subscribers.values.forEach { $0.tell(.clusterEvent(event)) }
            })

            return Behavior<Message>.receiveMessage { message in
                switch message {
                case .subscribeToAllocationStrategyEvents(let ref):
                    subscribers[ref.address] = ref
                    context.watch(ref)
                    context.log.trace("Successfully subscribed [\(ref)] to AllocationStrategyEvent stream")
                    return .same
                case .stop:
                    return .stop
                }
            }.receiveSpecificSignal(Signals.Terminated.self) { context, signal in
                if subscribers.removeValue(forKey: signal.address) != nil {
                    context.log.trace("Removed subscriber [\(signal.address)] because it terminated")
                } else {
                    context.log.warning("Received unexpected termination signal for non-subscriber [\(signal.address)]")
                }
                return .same
            }
        }
    }

    enum Message {
        case subscribeToAllocationStrategyEvents(ActorRef<AllocationStrategyEvent>)
        case stop
    }
}

internal enum AllocationStrategyEvent {
    case clusterEvent(ClusterEvent)
}
