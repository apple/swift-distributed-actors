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

import NIO
import class Dispatch.DispatchQueue


/// For internal purposes, an actor cell can act-as-if an EventLoop.
///
/// This feature should not be exposed, and thus is defined on the cell itself, rather than the context.
extension ActorCell: EventLoop {

    public var inEventLoop: Bool {
        return false // effectively meaning "always go through maibox loop"
    }

    public func execute(_ task: @escaping () -> Void) {
        self._myselfInACell.sendClosure(task)
    }

    public func scheduleTask<T>(in: NIO.TimeAmount, _ task: @escaping () throws -> T) -> Scheduled<T> {
        // TODO: implement EventLoops scheduling API in terms of Timers?
        fatalError("\"I'm sorry Dave, I'm afraid I can't do that.\" `EventLoop.scheduleTask` is not implemented on ActorContext.")
    }

    public func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        // TODO: a bit scary, do we want to support this? Would have to kill the dispatcher hm...
        fatalError("\"I'm sorry Dave, I'm afraid I can't do that.\" `EventLoop.shutdownGracefully` is not implemented on ActorContext.")
    }

}
