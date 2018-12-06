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

// MARK: UniqueActorPath

/// Uniquely identifies an actor within the actor hierarchy.
///
/// It may represent an actor that has already terminated, so attempts to locate
/// an `ActorRef` for this unique path may yield with not being able to find it,
/// even if previously at some point in time it existed.
// TODO: we could reconsider naming here; historical naming is that "address is the entire thing" by Hewitt...
// TODO: sadly "address" is super overloaded and ActorAddress sounds a bit weird... We also will have "Address" for the node, so "NodeAddress"?
public struct UniqueActorPath: Equatable, Hashable {

    /// Underlying path representation, not attached to a specific Actor instance.
    let path: ActorPath

    /// Unique identified associated with a specific actor "incarnation" under this path.
    let uid: ActorUID

    public init(path: ActorPath, uid: ActorUID) {
        self.path = path
        self.uid = uid
    }

    /// Only to be used by the "/" root "actor"
    internal static let _rootPath: UniqueActorPath = ActorPath._rootPath.makeUnique(uid: .opaque)

    /// Returns the name of the actor represented by this path.
    /// This is equal to the last path segments string representation.
    var name: String {
        return path.name
    }
}

extension UniqueActorPath: CustomStringConvertible {
    public var description: String {
        return "\(path.description)#\(uid.value)"
    }
}

extension UniqueActorPath: PathRelationships {
    var segments: [ActorPathSegment] {
        return path.segments
    }
}

// MARK: ActorPath

/// Represents the name and placement within the actor hierarchy of a given actor.
///
/// Names of user actors MUST:
/// - not start with `$` (those names are reserved for Swift Distributed Actors internal system actors)
/// - contain only ASCII characters and select special characters (listed in [[ValidPathSymbols.extraSymbols]]
///
/// - Example: `/user/master/worker`
public struct ActorPath: PathRelationships, Equatable, Hashable {

    internal var segments: [ActorPathSegment]

    init(_ segments: [ActorPathSegment]) throws {
        guard !segments.isEmpty else {
            throw ActorPathError.illegalEmptyActorPath
        }
        self.segments = segments
    }

    init(root: String) throws {
        try self.init([ActorPathSegment(root)])
    }

    init(root: ActorPathSegment) throws {
        try self.init([root])
    }

    /// INTERNAL API: Special purpose initializer, only for the "/" path. None other may use such path.
    private init() {
        self.segments = []
    }

    internal static let _rootPath: ActorPath = .init()

    /// Appends a segment to this actor path
    mutating func append(segment: ActorPathSegment) {
        self.segments.append(segment)
    }

    func makeUnique(uid: ActorUID) -> UniqueActorPath {
        return UniqueActorPath(path: self, uid: uid)
    }

    /// Returns the name of the actor represented by this path.
    /// This is equal to the last path segments string representation.
    var name: String {
        // the only path which has no segments is the "root"
        let lastSegmentName = segments.last?.description ?? "/"
        return "\(lastSegmentName)"
    }
}

// TODO
extension ActorPath: CustomStringConvertible {
    public var description: String {
        let pathSegments: String = self.segments.map({ $0.value }).joined(separator: "/")
        return "/\(pathSegments)"
    }
}

// MARK: Path relationships

protocol PathRelationships {
    var segments: [ActorPathSegment] { get }
}

extension PathRelationships {

    /// Combines the base path with a child segment returning the concatenated path.
    static func /(base: Self, child: ActorPathSegment) -> ActorPath {
        var segments = base.segments
        segments.append(child)

        // try safe: because we know that `segments` is not empty
        return try! ActorPath(segments)
    }

    /// Checks whether this [ActorPath] is a direct descendant of the passed in path.
    ///
    /// - Parameter path: The path that is suspected to be the parent of `self`
    /// - Returns: `true` if this [ActorPath] is a direct descendant of `maybeParentPath`, `false` otherwise
    @usableFromInline
    func isChildPathOf(_ maybeParentPath: PathRelationships) -> Bool {
        return Array(self.segments.dropLast()) == maybeParentPath.segments
    }
    /// Checks whether this [ActorPath] is a direct ancestor of the passed in path.
    ///
    /// Note: Path relationships only take into account the path segments, and can not be used
    ///       to confirm whether or not a specific actor is the child of another another (identified by another unique path).
    ///       Such relationships must be confirmed by using the [[ActorContext.children.hasChild(:UniqueActorPath)]] method. TODO: this does not exist yet
    ///
    /// - Parameter path: The path that is suspected to be a child of `self`
    /// - Returns: `true` if this [ActorPath] is a direct ancestor of `maybeChildPath`, `false` otherwise
    func isParentOf(_ maybeChildPath: PathRelationships) -> Bool {
        return maybeChildPath.isChildPathOf(self)
    }

    /// Create a unique path identifying a specific child actor.
    func makeChildPath(name: String, uid: ActorUID) throws -> UniqueActorPath {
        return try self.makeChildPath(name: name).makeUnique(uid: uid)
    }
    /// Create a generic path to identify a child path of the current path.
    func makeChildPath(name: String) throws -> ActorPath {
        let base = try ActorPath(self.segments)
        let nameSegment = try ActorPathSegment(name)
        return base / nameSegment
    }
    
}

// MARK: Path segments

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

// MARK: Actor UID

public struct ActorUID: Equatable, Hashable {
    let value: UInt32
}

public extension ActorUID {
    /// To be used ONLY by special actors whose existence is perpetual, such as `/system/deadLetters`
    static let opaque: ActorUID = ActorUID(value: 0) // TODO need better name, plz help?

    public static func random() -> ActorUID {
        return ActorUID(value: UInt32.random(in: 1 ... .max))
    }
}

// MARK: Path errors

public enum ActorPathError: Error {
    case illegalEmptyActorPath
    case illegalLeadingSpecialCharacter(name: String, illegal: Character)
    case illegalActorPathElement(name: String, illegal: String, index: Int)
    case rootPathSegmentRequiredToStartWithSlash(segment: ActorPathSegment)
}
