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

@testable import DistributedActors
import NIO

final class ReadRecorder: ChannelInboundHandler {
    typealias InboundIn = TransportEnvelope

    var reads: [TransportEnvelope] = []

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.reads.append(self.unwrapInboundIn(data))
        context.fireChannelRead(data)
    }
}

final class WriteRecorder: ChannelOutboundHandler {
    typealias OutboundIn = TransportEnvelope

    var writes: [TransportEnvelope] = []

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        self.writes.append(self.unwrapOutboundIn(data))

        context.write(data, promise: promise)
    }
}
