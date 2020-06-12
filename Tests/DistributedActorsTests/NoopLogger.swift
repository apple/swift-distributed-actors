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

import Logging

public struct NoopLogger {
    public static func make() -> Logger {
        .init(label: "noop", factory: { _ in NoopLogHandler() })
    }
}

public struct NoopLogHandler: LogHandler {
    public func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, file: String, function: String, line: UInt) {
        // ignore
    }

    public subscript(metadataKey _: String) -> Logger.MetadataValue? {
        get {
            nil // ignore
        }
        set {
            // ignore
        }
    }

    public var metadata: Logger.Metadata = [:]
    public var logLevel: Logger.Level = .critical
}
