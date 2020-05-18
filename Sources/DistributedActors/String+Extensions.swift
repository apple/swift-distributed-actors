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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Pretty String Descriptions

/// Marks a type that can be "pretty" printed, meaning often multi-line well formatted/aligned.
public protocol CustomPrettyStringConvertible {
    /// Pretty representation of the type, intended for inspection in command line and "visual" inspection.
    /// Not to be used in log statements or otherwise persisted formats.
    var prettyDescription: String { get }
    func prettyDescription(depth: Int) -> String
}

extension CustomPrettyStringConvertible {
    public var prettyDescription: String {
        self.prettyDescription(depth: 0)
    }
    public func prettyDescription(depth: Int) -> String {
        self.prettyDescription(of: self, depth: depth)
    }

    public func prettyDescription(of value: Any, depth: Int) -> String {
        let mirror = Mirror(reflecting: value)
        let padding0 = String(repeating: " ", count: depth * 2)
        let padding1 = String(repeating: " ", count: (depth + 1) * 2)

        var res = "\(Self.self)(\n"
        for member in mirror.children {
            res += "\(padding1)"
            res += "\(CONSOLE_BOLD)\(optional: member.label)\(CONSOLE_RESET): "
            switch member.value {
            case let v as CustomPrettyStringConvertible:
                res += v.prettyDescription(depth: depth + 1)
            case let v as ExpressibleByNilLiteral:
                let description = "\(v)"
                if description.starts(with: "Optional(") {
                    var r = description.dropFirst("Optional(".count)
                    r = r.dropLast(1)
                    res += "\(r)"
                } else {
                    res += "nil"
                }
            case let v as CustomDebugStringConvertible:
                res += v.debugDescription
            default:
                res += "\(member.value)"
            }
            res += ",\n"
        }
        res += "\(padding0))"

        return res
    }
}

extension Set: CustomPrettyStringConvertible {
    public var prettyDescription: String {
        self.prettyDescription(depth: 0)
    }
    public func prettyDescription(depth: Int) -> String {
        self.prettyDescription(of: self, depth: depth)
    }

    public func prettyDescription(of value: Any, depth: Int) -> String {
        let padding0 = String(repeating: " ", count: depth * 2)
        let padding1 = String(repeating: " ", count: (depth + 1) * 2)

        var res = "[\n"
        for element in self {
            res += "\(padding1)\(element),\n"
        }
        res += "\(padding0)]"
        return res
    }
}

extension Array: CustomPrettyStringConvertible {
    public var prettyDescription: String {
        self.prettyDescription(depth: 0)
    }
    public func prettyDescription(depth: Int) -> String {
        self.prettyDescription(of: self, depth: depth)
    }

    public func prettyDescription(of value: Any, depth: Int) -> String {
        let padding0 = String(repeating: " ", count: depth * 2)
        let padding1 = String(repeating: " ", count: (depth + 1) * 2)

        var res = "Set([\n"
        for element in self {
            res += "\(padding1)\(element),\n"
        }
        res += "\(padding0)])"
        return res
    }
}
extension Dictionary: CustomPrettyStringConvertible {
    public var prettyDescription: String {
        self.prettyDescription(depth: 0)
    }
    public func prettyDescription(depth: Int) -> String {
        self.prettyDescription(of: self, depth: depth)
    }

    public func prettyDescription(of value: Any, depth: Int) -> String {
        let padding0 = String(repeating: " ", count: depth * 2)
        let padding1 = String(repeating: " ", count: (depth + 1) * 2)

        var res = "[\n"
        for (key, value) in self {
            res += "\(padding1)\(key): \(value),\n"
        }
        res += "\(padding0)]"
        return res
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: String Interpolation: _:leftPad:

internal extension String.StringInterpolation {
    mutating func appendInterpolation(_ value: CustomStringConvertible, leftPadTo totalLength: Int) {
        let s = "\(value)"
        let pad = String(repeating: " ", count: max(totalLength - s.count, 0))
        self.appendLiteral("\(pad)\(s)")
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: String Interpolation: Message printing [contents]:type which is useful for enums

internal extension String.StringInterpolation {
    mutating func appendInterpolation(message: Any) {
        self.appendLiteral("[\(message)]:\(String(reflecting: type(of: message)))")
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: String Interpolation: reflecting:

internal extension String.StringInterpolation {
    mutating func appendInterpolation(pretty subject: CustomPrettyStringConvertible) {
        self.appendLiteral(subject.prettyDescription)
    }

    mutating func appendInterpolation(reflecting subject: Any?) {
        self.appendLiteral(String(reflecting: subject))
    }

    mutating func appendInterpolation(reflecting subject: Any) {
        self.appendLiteral(String(reflecting: subject))
    }
}

internal extension String.StringInterpolation {
    mutating func appendInterpolation(lineByLine subject: [Any]) {
        self.appendLiteral("\n    \(subject.map { "\($0)" }.joined(separator: "\n    "))")
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: String Interpolation: _:orElse:

public extension String.StringInterpolation {
    mutating func appendInterpolation<T>(_ value: T?, orElse defaultValue: String) {
        self.appendLiteral("\(value.map { "\($0)" } ?? defaultValue)")
    }

    mutating func appendInterpolation<T>(optional value: T?) {
        self.appendLiteral("\(value.map { "\($0)" } ?? "nil")")
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor Ref custom interpolations

public extension String.StringInterpolation {
    mutating func appendInterpolation<Message>(name ref: ActorRef<Message>) {
        self.appendLiteral("[\(ref.address.name)]")
    }

    mutating func appendInterpolation<Message>(uniquePath ref: ActorRef<Message>) {
        self.appendLiteral("[\(ref.address)]") // TODO: make those address
    }

    mutating func appendInterpolation<Message>(path ref: ActorRef<Message>) {
        self.appendLiteral("[\(ref.address.path)]")
    }
}
