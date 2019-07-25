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

internal extension String.StringInterpolation {
    mutating func appendInterpolation(_ value: CustomStringConvertible, leftPadTo totalLength: Int) {
        let s = "\(value)"
        let pad = String(repeating: " ", count: max(totalLength - s.count, 0))
        self.appendLiteral("\(pad)\(s)")
    }
}

internal extension String.StringInterpolation {
    mutating func appendInterpolation(reflecting subject: CustomDebugStringConvertible) {
        self.appendLiteral("[\(String(reflecting: subject))]")
    }
}


// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Quality of life for printing optional values

public extension String.StringInterpolation {
    mutating func appendInterpolation<T>(_ value: Optional<T>, orElse defaultValue: String) {
        self.appendLiteral("[\(value.map({ "\($0)" }) ?? defaultValue)]")
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor Ref custom interpolations

public extension String.StringInterpolation {
    mutating func appendInterpolation<Message>(name ref: ActorRef<Message>) {
        self.appendLiteral("[\(ref.address.name)]")
    }

    mutating func appendInterpolation<Message>(uniquePath ref: ActorRef<Message>) {
        self.appendLiteral("[\(ref.address)]") // TODO make those address
    }

    mutating func appendInterpolation<Message>(path ref: ActorRef<Message>) {
        self.appendLiteral("[\(ref.address.path)]")
    }
}
