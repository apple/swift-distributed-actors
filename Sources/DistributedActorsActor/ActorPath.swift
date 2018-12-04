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

/// Represents the name and placement within the actor hierarchy of a given actor.
///
/// Names of user actors MUST:
/// - not start with `$` (those names are reserved for Swift Distributed Actors internal system actors)
/// - contain only ASCII characters and select special characters (listed in [[ValidPathSymbols.extraSymbols]]
///
/// - Example: `/user/master/worker`
public struct ActorPath {

    // TODO: we could reconsider naming here; historical naming is that "address is the entire thing" by Hewitt,
    //      Akka wanted to get closer to that but we had historical naming to take into account so we didn't
    // private var address: Address = "swift-distributed-actors://10.0.0.1:2552
    private var segments: [ActorPathSegment]
    let uid: ActorUID

    init(_ segments: [ActorPathSegment], uid: ActorUID) throws {
        guard !segments.isEmpty else {
            throw ActorPathError.illegalEmptyActorPath
        }
        self.segments = segments
        self.uid = uid
    }

    init(root: String) throws {
        try self.init([ActorPathSegment(root)], uid: ActorUID.undefined)
    }

    public init(root: ActorPathSegment) throws {
        try self.init([root], uid: ActorUID.undefined)
    }

    /// Appends a segment to this actor path
    mutating func append(segment: ActorPathSegment) {
        self.segments.append(segment)
    }

    /// Returns the name of the actor represented by this path.
    /// This is equal to the last path segments string representation.
    var name: String {
        return nameSegment.value
    }

    var nameSegment: ActorPathSegment {
        return segments.last! // it is guaranteed by construction that we have at least one segment
    }
}

extension ActorPath: Equatable {
    public static func == (lhs: ActorPath, rhs: ActorPath) -> Bool {
        return lhs.segments == rhs.segments
    }
}

extension ActorPath: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(segments)
    }
}

extension ActorPath {
    static func /(base: ActorPath, child: ActorPathSegment) -> ActorPath {
        var segments = base.segments
        segments.append(child)
        // safe because we know that segments is not empty
        return try! ActorPath(segments, uid: ActorUID.random())
    }

    /// Checks whether this [ActorPath] is a direct descendant of the passed in path
    ///
    /// - Parameter path: The path to check against
    /// - Returns: `true` if this [ActorPath] is a direct descendant of `path`, `false` otherwise
    func isChildOf(_ path: ActorPath) -> Bool {
        return Array(segments.dropLast()) == path.segments
    }
}

// TODO
extension ActorPath: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        let pathSegments: String = self.segments.map({ $0.value }).joined(separator: "/")
        let pathString = "/\(pathSegments)"
        switch uid.value {
        case ActorUID.undefined.value:
            return pathString
        default:
            return "\(pathString)#\(uid.value)"
        }
    }
    public var debugDescription: String {
        return "ActorPath(\(description))"
    }
}

/// Represents a single segment (actor name) of an ActorPath.
public struct ActorPathSegment: Equatable, Hashable {
    let value: String

    public init(_ name: String) throws {
        // TODO: may want to separate validation out, in case we create it from "known safe" strings
        try ActorPathSegment.validatePathSegment(name)
        self.value = name
    }

    static func validatePathSegment(_ name: String) throws {
        if name.isEmpty {
            throw ActorPathError.illegalActorPathElement(name: name, illegal: "", index: 0)
        }

        // TODO: benchmark
        func isValidASCII(_ scalar: Unicode.Scalar) -> Bool {
            return (scalar >= ValidActorPathSymbols.a && scalar <= ValidActorPathSymbols.z) ||
                (scalar >= ValidActorPathSymbols.A && scalar <= ValidActorPathSymbols.Z) ||
                (scalar >= ValidActorPathSymbols.zero && scalar <= ValidActorPathSymbols.nine) ||
                (ValidActorPathSymbols.extraSymbols.contains(scalar))
        }

        // TODO: accept hex and url encoded things as well
        // http://www.ietf.org/rfc/rfc2396.txt
        var pos = 0
        for c in name {
            let f = c.unicodeScalars.first

            if (f?.isASCII ?? false) && isValidASCII(f!) {
                pos += 1
                continue
            } else {
                throw ActorPathError.illegalActorPathElement(name: name, illegal: "\(c)", index: pos)
            }
        }
    }
}

extension ActorPathSegment: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        return "\(self.value)"
    }
    public var debugDescription: String {
        return "ActorPathSegment(\(self))"
    }
}

private struct ValidActorPathSymbols {
    // TODO: I suspect having those as numeric constants may be better for perf?
    static let a: UnicodeScalar = "a"
    static let z: UnicodeScalar = "z"
    static let A: UnicodeScalar = "A"
    static let Z: UnicodeScalar = "Z"
    static let zero: UnicodeScalar = "0"
    static let nine: UnicodeScalar = "9"

    static let extraSymbols: String.UnicodeScalarView = "-_.*$+:@&=,!~';".unicodeScalars
}

// MARK: --

public enum ActorPathError: Error {
    case illegalEmptyActorPath
    case illegalLeadingSpecialCharacter(name: String, illegal: Character)
    case illegalActorPathElement(name: String, illegal: String, index: Int)
    case rootPathSegmentRequiredToStartWithSlash(segment: ActorPathSegment)
}
