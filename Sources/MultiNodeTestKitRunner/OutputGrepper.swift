import Distributed
import DistributedCluster
import class Foundation.Pipe
//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIOCore
import NIOFoundationCompat
import NIOPosix

internal struct OutputGrepper {
    internal var result: EventLoopFuture<ProgramOutput>
    internal var processOutputPipe: NIOFileHandle

    internal static func make(
        nodeName: String,
        group: EventLoopGroup,
        programLogRecipient: (any ProgramLogReceiver)? = nil
    ) -> OutputGrepper {
        let processToChannel = Pipe()
        let deadPipe = Pipe() // just so we have an output...

        let eventLoop = group.next()
        let outputPromise = eventLoop.makePromise(of: ProgramOutput.self)

        // We gotta `dup` everything because Pipe is bad and closes file descriptors on `deinit` :(
        let channelFuture = NIOPipeBootstrap(group: group)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .channelInitializer { channel in
                channel.pipeline.addHandlers(
                    [
                        ByteToMessageHandler(NewlineFramer()),
                        GrepHandler(
                            nodeName: nodeName,
                            promise: outputPromise,
                            programLogRecipient: programLogRecipient
                        ),
                    ]
                )
            }
            .withPipes(
                inputDescriptor: dup(processToChannel.fileHandleForReading.fileDescriptor),
                outputDescriptor: dup(deadPipe.fileHandleForWriting.fileDescriptor)
            )
        let processOutputPipe = NIOFileHandle(descriptor: dup(processToChannel.fileHandleForWriting.fileDescriptor))
        processToChannel.fileHandleForReading.closeFile()
        processToChannel.fileHandleForWriting.closeFile()
        deadPipe.fileHandleForReading.closeFile()
        deadPipe.fileHandleForWriting.closeFile()
        channelFuture.cascadeFailure(to: outputPromise)
        return OutputGrepper(
            result: outputPromise.futureResult,
            processOutputPipe: processOutputPipe
        )
    }
}

struct ProgramOutput: Sendable {
    let logs: [String]
    var expectedExit: Bool = false

    init(logs: [String]) {
        self.logs = logs
    }

    init(logs: [String], expectedExit: Bool) {
        self.logs = logs
        self.expectedExit = expectedExit
    }
}

private final class GrepHandler: ChannelInboundHandler {
    typealias InboundIn = String

    private let promise: EventLoopPromise<ProgramOutput>

    let nodeName: String
    var logs: [String] = []
    var programLogReceiver: (any ProgramLogReceiver)?

    init(nodeName: String,
         promise: EventLoopPromise<ProgramOutput>,
         programLogRecipient: ProgramLogReceiver?)
    {
        self.nodeName = nodeName
        self.promise = promise
        self.programLogReceiver = programLogRecipient
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.promise.fail(error)
        context.close(promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let line = self.unwrapInboundIn(data)

        if let receiver = self.programLogReceiver {
            // send to receiver
            Task { // FIXME: ordering is messed up here, isn't it.
                try await receiver.logProgramOutput(line: line)
            }
        } else {
            // accumulate locally
            logs.append(line)
        }
        // TODO: send to log recipient

        // Detect crashes
        if line.lowercased().contains("fatal error") ||
            line.lowercased().contains("precondition failed") ||
            line.lowercased().contains("assertion failed")
        {
            if line.contains("MULTI-NODE-EXPECTED-EXIT") {
                self.promise.succeed(.init(logs: logs, expectedExit: true))
                context.close(promise: nil)
                return
             } else {
                self.promise.fail(MultiNodeProgramError(message: line, completeOutput: self.logs))
                self.logs = []
                context.close(promise: nil)
            }
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .some(.inputClosed) = event as? ChannelEvent {
            self.promise.succeed(.init(logs: self.logs))
            context.close(promise: nil)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.promise.fail(ChannelError.alreadyClosed)
    }
}

protocol ProgramLogReceiver {
    func logProgramOutput(line: String) async throws
}

distributed actor DistributedProgramLogReceiver: ProgramLogReceiver {
    typealias ActorSystem = ClusterSystem

    var logs: [String] = []

    distributed func logProgramOutput(line: String) {
        self.logs.append(line)
    }

    func dumpOutput() {
        for line in self.logs {
            print("[dump] \(line)")
        }
    }
}

struct MultiNodeProgramError: Error, CustomStringConvertible {
    let message: String
    let completeOutput: [String]
    var description: String {
        "\(Self.self)(\(self.message), completeOutput: <\(self.completeOutput.count) lines>)"
    }
}

private struct NewlineFramer: ByteToMessageDecoder {
    typealias InboundOut = String

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        if let firstNewline = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) {
            let length = firstNewline - buffer.readerIndex + 1
            context.fireChannelRead(self.wrapInboundOut(String(buffer.readString(length: length)!.dropLast())))
            return .continue
        } else {
            return .needMoreData
        }
    }
}
