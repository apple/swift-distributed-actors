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

import Foundation

/// Allows an actor to "own", and automatically keep a value "up to date",
/// without having to perform the dance of receiving a value updating message and updating the value manually.
///
/// All functions on an owned MUST only be invoked by the actor itself.
public final class ActorableOwned<T> {
    private struct ValueCell {
        let value: T
        let updatedAt: Date
    }

    public var ref: ActorRef<T> {
        self._ref
    }

    private var _ref: ActorRef<T>!

    private var _cell: ValueCell?
    private var __onUpdate: (T) -> Void

    public init<Owner>(_ context: Owner.Myself.Context, type: T.Type = T.self) where Owner: Actorable {
        let typeName = String(reflecting: T.self)
            .replacingOccurrences(of: "<", with: "-")
            .replacingOccurrences(of: ">", with: "-") // TODO: workaround this since names will be gone...?

        self._cell = nil
        self.__onUpdate = { _ in () }
        self._ref = nil
        let subReceiveId: SubReceiveId<T> = SubReceiveId(T.self, id: "ActorOwned-\(typeName)")
        self._ref = context.underlying.subReceive(subReceiveId, T.self) { newValue in
            self._cell = ValueCell(value: newValue, updatedAt: Date())
            self.__onUpdate(newValue)
        }
    }

    /// Update the owned value.
    /// The update can be performed by any thread.
    public func update(newValue: T) {
        self._ref.tell(newValue)
    }

    /// MUST be invoked on actor context, so NOT in a Future or other execution context.
    ///
    /// If a value is needed in another context, read it by calling `lastObservedValue` before moving on to the other execution context.
    ///
    /// The value is automatically kept up to date.
    public var lastObservedValue: T? {
        self._cell?.value
    }

    public var lastUpdatedAt: Date? {
        self._cell?.updatedAt
    }

    /// Sets a callback to be executed whenever the underlying owned value is updated (by an `update` invocation).
    /// The callback is guaranteed to execute on the actors context, and thus can access and even mutate the actors state.
    ///
    /// Setting the onUpdate callback MUST be invoked by the actor itself.
    public func onUpdate(_ callback: @escaping (T) -> Void) {
        self.__onUpdate = callback
    }
}
