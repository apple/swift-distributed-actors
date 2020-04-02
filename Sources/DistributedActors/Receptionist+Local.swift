/// /===----------------------------------------------------------------------===//
/// /
/// / This source file is part of the Swift Distributed Actors open source project
/// /
/// / Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
/// / Licensed under Apache License v2.0
/// /
/// / See LICENSE.txt for license information
/// / See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
/// /
/// / SPDX-License-Identifier: Apache-2.0
/// /
/// /===----------------------------------------------------------------------===//
//
// import Logging
//
/// // Receptionist for local execution. Does not depend on a cluster being available.
// internal enum LocalReceptionist {
//    static var behavior: Behavior<Receptionist.Message> {
//        return .setup { context in
//            let storage = Receptionist.Storage()
//
//            // TODO: implement configurable logging (to log if it gets registers etc)
//            // TODO: since all states access all the same state, allocating a local receptionist would result in less passing around storage
//            return .receiveMessage { message in
//                switch message {
//                case let message as _Register:
//                    try LocalReceptionist.onRegister(context: context, message: message, storage: storage)
//
//                case let message as _Lookup:
//                    try LocalReceptionist.onLookup(context: context, message: message, storage: storage)
//
//                case let message as _Subscribe:
//                    try LocalReceptionist.onSubscribe(context: context, message: message, storage: storage)
//
//                default:
//                    context.log.warning("Received unexpected message \(message)")
//                }
//                return .same
//            }
//        }
//    }
//
//    private static func onRegister(context: ActorContext<Receptionist.Message>, message: _Register, storage: Receptionist.Storage) throws {
//        let key = message._key.boxed
//        let addressable = message._addressableActorRef
//
//        context.log.debug("Registering \(addressable) under key: \(key)")
//
//        if storage.addRegistration(key: key, ref: addressable) {
//            let terminatedCallback = LocalReceptionist.makeRemoveRegistrationCallback(context: context, message: message, storage: storage)
//            try LocalReceptionist.startWatcher(ref: addressable, context: context, terminatedCallback: terminatedCallback.invoke(()))
//
//            if let subscribed = storage.subscriptions(forKey: key) {
//                let registrations = storage.registrations(forKey: key) ?? []
//                for subscription in subscribed {
//                    subscription._replyWith(registrations)
//                }
//            }
//        }
//
//        message.replyRegistered()
//    }
//
//    private static func onSubscribe(context: ActorContext<Receptionist.Message>, message: _Subscribe, storage: Receptionist.Storage) throws {
//        let boxedMessage = message._boxed
//        let key = AnyRegistrationKey(from: message._key)
//
//        context.log.debug("Subscribing \(message._addressableActorRef) to: \(key)")
//
//        if storage.addSubscription(key: key, subscription: boxedMessage) {
//            let terminatedCallback = LocalReceptionist.makeRemoveSubscriptionCallback(context: context, message: message, storage: storage)
//            try LocalReceptionist.startWatcher(ref: message._addressableActorRef, context: context, terminatedCallback: terminatedCallback.invoke(()))
//
//            boxedMessage.replyWith(storage.registrations(forKey: key) ?? [])
//        }
//    }
//
//    private static func onLookup(context: ActorContext<Receptionist.Message>, message: _Lookup, storage: Receptionist.Storage) throws {
//        if let registered = storage.registrations(forKey: message._key.boxed) {
//            message.replyWith(registered)
//        } else {
//            message.replyWith([])
//        }
//    }
//
//    // TODO: use context aware watch once implemented. See: issue #544
//    private static func startWatcher<M>(ref: AddressableActorRef, context: ActorContext<M>, terminatedCallback: @autoclosure @escaping () -> Void) throws {
//        let behavior: Behavior<Never> = .setup { context in
//            context.watch(ref)
//            return .receiveSpecificSignal(Signals.Terminated.self) { _, terminated in
//                if terminated.address == ref.address {
//                    terminatedCallback()
//                    return .stop
//                }
//                return .same
//            }
//        }
//
//        _ = try context.spawn(.anonymous, behavior)
//    }
//
//    private static func makeRemoveRegistrationCallback(context: ActorContext<Receptionist.Message>, message: _Register, storage: Receptionist.Storage) -> AsynchronousCallback<Void> {
//        context.makeAsynchronousCallback {
//            let remainingRegistrations = storage.removeRegistration(key: message._key.boxed, ref: message._addressableActorRef) ?? []
//
//            if let subscribed = storage.subscriptions(forKey: message._key.boxed) {
//                for subscription in subscribed {
//                    subscription._replyWith(remainingRegistrations)
//                }
//            }
//        }
//    }
//
//    private static func makeRemoveSubscriptionCallback(context: ActorContext<Receptionist.Message>, message: _Subscribe, storage: Receptionist.Storage) -> AsynchronousCallback<Void> {
//        context.makeAsynchronousCallback {
//            storage.removeSubscription(key: message._key.boxed, subscription: message._boxed)
//        }
//    }
// }
