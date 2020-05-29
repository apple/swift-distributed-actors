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
import DistributedActorsConcurrencyHelpers
import Foundation
import Logging

import XCTest

extension ActorTestKit {
    public func expect<Value>(
        _ reply: Reply<Value>,
        within timeout: TimeAmount? = nil,
        file: StaticString = #file, line: UInt = #line, column: UInt = #column
    ) throws -> Value {
        let callSite = CallSiteInfo(file: file, line: line, column: column, function: #function)
        let timeout = timeout ?? self.settings.expectationTimeout

        let receptacle = BlockingReceptacle<Result<Value, Error>>()
        reply._onComplete(receptacle.offerOnce)
        if let value = receptacle.wait(atMost: timeout) {
            switch value {
            case .success(let value):
                return value
            case .failure(let error):
                throw callSite.error("Did not receive reply [\(Value.self)] within [\(timeout.prettyDescription)], error: \(error)")
            }
        } else {
            throw callSite.error("Did not receive reply [\(Value.self)] within [\(timeout.prettyDescription)]")
        }
    }

    public func expect<Value>(
        _ reply: Reply<Value>,
        _ toEqual: Value,
        within timeout: TimeAmount? = nil,
        file: StaticString = #file, line: UInt = #line, column: UInt = #column
    ) throws where Value: Equatable {
        let got = try self.expect(reply, file: file, line: line, column: column)
        got.shouldEqual(toEqual, file: file, line: line, column: column)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: AskResponse

extension AskResponse {
    /// Blocks and waits until there is a response or fails with an error.
    public func wait() throws -> Value {
        switch self {
        case .completed(let result):
            return try result.get()
        case .nioFuture(let nioFuture):
            return try nioFuture.wait()
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ResultReply

extension Reply {
    /// Blocks and waits until there is a reply or fails with an error.
    public func wait() throws -> Value {
        switch self {
        case .completed(let result):
            return try result.get()
        case .nioFuture(let nioFuture):
            return try nioFuture.wait()
        }
    }
}
