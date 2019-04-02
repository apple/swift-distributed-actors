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

import Foundation

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: UniqueActorPath

/// Uniquely identifies an actor within the actor hierarchy.
///
/// It may represent an actor that has already terminated, so attempts to locate
/// an `ActorRef` for this unique path may yield with not being able to find it,
/// even if previously at some point in time it existed.
// TODO: we could reconsider naming here; historical naming is that "address is the entire thing" by Hewitt...
// TODO: sadly "address" is super overloaded and ActorAddress sounds a bit weird... We also will have "NodeAddress" for the node, so "NodeAddress"?
public struct UniqueActorPath: Equatable, Hashable {

    /// Underlying path representation, not attached to a specific Actor instance.
    var path: ActorPath

    /// Unique identified associated with a specific actor "incarnation" under this path.
    let uid: ActorUID

    public init(path: ActorPath, uid: ActorUID) {
        self.path = path
        self.uid = uid
    }

    /// Only to be used by the "/" root "actor"
    public static let _rootPath: UniqueActorPath = ActorPath._rootPath.makeUnique(uid: .opaque)

    /// Returns the name of the actor represented by this path.
    /// This is equal to the last path segments string representation.
    public var name: String {
        return path.name
    }

    /// If set, the address of node to which this actor path belongs.
    /// Or `nil`, meaning this actors residing under this path shall be assumed local.
    public var address: UniqueNodeAddress? {
        get {
            return self.path.address
        }
        set {
            self.path.address = newValue
        }
    }
}

extension UniqueActorPath: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        var res = ""
        res.reserveCapacity(256) // TODO estimate length somehow?

        if let addr = self.address {
            res += "\(addr)"
        }

        res += "\(self.path)"

        if self.uid.value != 0 {
            res += "#\(self.uid.value)"
        }

        return res
    }

    public var debugDescription: String {
        var res = ""

        if let addr = self.address {
            res += "\(addr.debugDescription)"
        }

        res += "\(self.path)"

        if self.uid.value != 0 {
            res += "#\(self.uid.value)"
        }

        return res
    }
}

extension UniqueActorPath: PathRelationships {
    public var segments: [ActorPathSegment] {
        return path.segments
    }
}

extension UniqueActorPath {
    static func parse(fromString pathString: String) throws -> UniqueActorPath {
        // TODO: avoid Foundation. Maybe add proto representations of paths?
        if let url = URL(string: pathString) {
            let uniqueNodeAddress: UniqueNodeAddress?
            if url.user != nil && url.host != nil && url.port != nil {
                let nodeAddress = NodeAddress(protocol: url.scheme ?? "sact", systemName: url.user!, host: url.host!, port: url.port!)
                uniqueNodeAddress = UniqueNodeAddress(address: nodeAddress, uid: NodeUID(url.password.flatMap { UInt32($0) } ?? 0))
            } else {
                uniqueNodeAddress = nil
            }
            let segments = try url.path.split(separator: "/").map { c in
                try ActorPathSegment(c)
            }
            let path = try ActorPath(segments, address: uniqueNodeAddress)

            return UniqueActorPath(path: path, uid: ActorUID(Int(url.fragment!)!))
        }

        throw ActorPathError.invalidPath(pathString)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorPath

/// Represents the name and placement within the actor hierarchy of a given actor.
///
/// Names of user actors MUST:
/// - not start with `$` (those names are reserved for Swift Distributed Actors internal system actors)
/// - contain only ASCII characters and select special characters (listed in [[ValidPathSymbols.extraSymbols]]
///
/// - Example: `/user/master/worker`
public struct ActorPath: PathRelationships, Equatable, Hashable {

    /// If set, the address of node to which this actor path belongs.
    /// Or `nil`, meaning this actors residing under this path shall be assumed local.
    public var address: UniqueNodeAddress?
    
    public var segments: [ActorPathSegment]

    init(_ segments: [ActorPathSegment], address: UniqueNodeAddress? = nil) throws {
        self.address = address
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

    public static let _rootPath: ActorPath = .init()

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

extension ActorPath: CustomStringConvertible {
    public var description: String {
        let pathSegments: String = self.segments.map({ $0.value }).joined(separator: "/")
        return "/\(pathSegments)"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Remote ActorPath utilities

extension ActorPath: PossiblyRemotePath {

}
extension UniqueActorPath: PossiblyRemotePath {
}

public protocol PossiblyRemotePath {

    var address: UniqueNodeAddress? { get }

    /// Returns true if it is known that the ref is pointing to an actor on a remote node,
    /// i.e. if it has an address defined, it must be other than the passed in system's one.
    /// For refs which do not contain an address, it is known that they point to a local path.
    ///
    /// - Returns: `true` if this [ActorPath] is known to be pointing to a remote address direct ancestor of `maybeChildPath`, `false` otherwise
    func isKnownRemote(localAddress: UniqueNodeAddress) -> Bool
}

extension PossiblyRemotePath {
    public func isKnownRemote(localAddress: UniqueNodeAddress) -> Bool {
        switch self.address {
        case .some(let refAddress): return refAddress != localAddress
        default:                    return false
        }
    }
}


// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Path relationships

public protocol PathRelationships {
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
    /// Note: Path relationships only take into account the path segments, and can not be used
    ///       to confirm whether or not a specific actor is the child of another another (identified by another unique path).
    ///       Such relationships must be confirmed by using the [[ActorContext.children.hasChild(:UniqueActorPath)]] method. TODO: this does not exist yet
    ///
    /// - Parameter path: The path that is suspected to be the parent of `self`
    /// - Returns: `true` if this [ActorPath] is a direct descendant of `maybeParentPath`, `false` otherwise
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

    // FIXME: optimize so we don't alloc into the String() here
    internal init(_ name: Substring) throws {
        try self.init(String(name))
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
    let value: Int // TODO redesign

    public init(_ value: Int) {
        self.value = value
    }
}

public extension ActorUID {
    /// To be used ONLY by special actors whose existence is perpetual, such as `/system/deadLetters`
    static let opaque: ActorUID = ActorUID(0)

    static func random() -> ActorUID {
        return ActorUID(Int.random(in: 1 ... .max))
    }
}

// MARK: Addresses

// TODO reconsider calling paths addresses and this being authority etc...
// TODO: "ActorAddress" could be the core concept... what would be the node addresses? 
public struct NodeAddress: Hashable {
    let `protocol`: String 
    var systemName: String
    var host: String
    var port: Int

    public init(`protocol`: String, systemName: String, host: String, port: Int) {
        precondition(port > 0, "port MUST be > 0")
        self.protocol = `protocol`
        self.systemName = systemName
        self.host = host
        self.port = port
    }
    public init(systemName: String, host: String, port: Int) {
        self.init(protocol: "sact", systemName: systemName, host: host, port: port)
    }
}
extension NodeAddress: CustomStringConvertible {
    public var description: String {
        return "\(self.`protocol`)://\(self.systemName)@\(self.host):\(self.port)"
    }
}

public struct UniqueNodeAddress: Hashable {
    let address: NodeAddress
    let uid: NodeUID // TODO ponder exact value here here

    public init(address: NodeAddress, uid: NodeUID) {
        precondition(address.port > 0, "port MUST be > 0")
        self.address = address
        self.uid = uid
    }
    public init(`protocol`: String, systemName: String, host: String, port: Int, uid: NodeUID) {
        self.init(address: NodeAddress(protocol: `protocol`, systemName: systemName, host: host, port: port), uid: uid)
    }
    public init(systemName: String, host: String, port: Int, uid: NodeUID) {
        self.init(protocol: "sact", systemName: systemName, host: host, port: port, uid: uid)
    }

}
extension UniqueNodeAddress: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        return "\(self.address)"
    }
    public var debugDescription: String {
        // TODO this somewhat abuses userinfo's password to carry the system UID... double check how we want to render
        let a = self.address
        return "\(a.protocol)://\(a.systemName):\(self.uid)@\(a.host):\(a.port)" 
    }
}

public struct NodeUID: Hashable {
    let value: UInt32 // TODO redesign / reconsider exact size

    public init(_ value: UInt32) {
        self.value = value
    }
}

extension NodeUID: CustomStringConvertible {
    public var description: String {
        return "\(value)"
    }
}
public extension NodeUID {
    static func random() -> NodeUID {
        return NodeUID(UInt32.random(in: 1 ... .max))
    }
}

extension NodeUID: Equatable {
}

// MARK: Path errors

public enum ActorPathError: Error {
    case illegalEmptyActorPath
    case illegalLeadingSpecialCharacter(name: String, illegal: Character)
    case illegalActorPathElement(name: String, illegal: String, index: Int)
    case rootPathSegmentRequiredToStartWithSlash(segment: ActorPathSegment)
    case invalidPath(String)
}
