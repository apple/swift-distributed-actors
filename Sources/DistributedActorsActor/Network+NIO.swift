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

private final class PrintHandler<Message>: ChannelInboundHandler {
    typealias InboundIn = Message

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let event = self.unwrapInboundIn(data)
        print("Received: \(event)")
    }

    func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        fputs("Caught error: \(error)\n", stderr)
    }
}

private final class MessageParser: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    public typealias InboundOut = Message


    var state = MessageParserState()

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        var bytes = self.unwrapInboundIn(data)

        if self.accumulator == nil {
            self.accumulator = bytes
        } else {
            self.accumulator!.write(buffer: &bytes)
        }

        do {
            repeat {
                if try self.parse(ctx: ctx) {
                    self.accumulator?.discardReadBytes()
                    let message = Message(version: self.state.version, headers: self.state.headers, message: self.state.message)
                    _ = ctx.fireChannelRead(self.wrapInboundOut(message))
                    ctx.write(<#T##data: NIOAny##NIOAny#>, promise: <#T##EventLoopPromise<Void>?##EventLoopPromise<Swift.Void>?#>)
                    let buffer: ByteBuffer?
                    if (self.accumulator?.readableBytes ?? 0) > 0 {
                        buffer = self.accumulator
                    } else {
                        buffer = nil
                    }
                    self.state = MessageParserState()
                    self.accumulator = buffer
                } else {
                    return
                }
            } while self.accumulator != nil
        } catch {
            self.accumulator = nil
            ctx.fireErrorCaught(error)
            ctx.close(promise: nil)
        }
    }

    func channelReadComplete(ctx: ChannelHandlerContext) {
        ctx.flush()
    }

    private func parse(ctx: ChannelHandlerContext) throws -> Bool {
        if self.accumulator == nil {
            return false
        }

        var keepRunning = true
        while keepRunning {
            switch self.state.dataAwaitingState {
            case .version:
                keepRunning = self.readVersion(&self.accumulator!)
            case .headerLength:
                keepRunning = self.readHeaderCount(&self.accumulator!)
            case .headers:
                keepRunning = try self.readHeaders(&self.accumulator!)
            case .messageLength:
                keepRunning = self.readMessageLength(&self.accumulator!)
            case .message:
                keepRunning = self.readMessage(&self.accumulator!)
            case .terminator:
                keepRunning = try self.readTerminator(&self.accumulator!)
            case .done:
                return true
            }

            self.accumulator?.discardReadBytes()
        }

        return false
    }

    private func readVersion(_ buffer: inout ByteBuffer) -> Bool {
        if buffer.readableBytes < 4 {
            return false
        }
        let versionBytes = buffer.readBytes(length: 4)!
        self.state.version.reserved = versionBytes[0]
        self.state.version.major = versionBytes[1]
        self.state.version.minor = versionBytes[2]
        self.state.version.patch = versionBytes[3]
        self.state.dataAwaitingState = .headerLength
        return true
    }

    private func readHeaderCount(_ buffer: inout ByteBuffer) -> Bool {
        guard let length = buffer.readInteger(endianness: .big, as: UInt16.self) else {
            return false
        }

        self.state.headerCount = length
        if length > 0 {
            self.state.dataAwaitingState = .headers
        } else {
            self.state.dataAwaitingState = .messageLength
        }

        return true
    }

    private func readHeaders(_ buffer: inout ByteBuffer) throws -> Bool {
        repeat {
            if let headerLength = self.state.currentHeaderLength {
                guard let header = buffer.readString(length: Int(headerLength)) else {
                    return false
                }

                let splitted = header.split(separator: ":")
                if splitted.count != 2 {
                    throw ParserError.malformedHeader
                }

                let key = String(splitted[0])

                if self.state.headers.keys.contains(key) {
                    throw ParserError.duplicateHeader(key)
                }

                self.state.headers[key] = String(splitted[1])
            } else if let headerLength = buffer.readInteger(endianness: .big, as: UInt16.self) {
                self.state.currentHeaderLength = headerLength
            } else {
                return false
            }
        } while self.state.headers.count != self.state.headerCount

        if self.state.headers.count == self.state.headerCount {
            self.state.dataAwaitingState = .messageLength
            return true
        } else {
            return false
        }
    }

    private func readMessageLength(_ buffer: inout ByteBuffer) -> Bool {
        guard let length = buffer.readInteger(endianness: .big, as: Int.self) else {
            return false
        }
        self.state.messageLength = length
        if length > 0 {
            self.state.dataAwaitingState = .message
        } else {
            self.state.dataAwaitingState = .terminator
        }
        return true
    }

    private func readMessage(_ buffer: inout ByteBuffer) -> Bool {
        guard let bytes = buffer.readBytes(length: self.state.messageLength) else {
            return false
        }
        self.state.message = bytes
        self.state.dataAwaitingState = .terminator
        return true
    }

    private func readTerminator(_ buffer: inout ByteBuffer) throws -> Bool {
        guard let bytes = buffer.readBytes(length: 1) else {
            return false
        }

        if bytes[0] != 59 {
            throw ParserError.invalidTerminator(bytes[0])
        }
        self.state.dataAwaitingState = .done

        return true
    }
}


