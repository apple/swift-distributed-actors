//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2021 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorAddress

/// Uniquely identifies an Actor within a (potentially clustered) Actor System.
/// Most of the time, using an `_ActorRef` is the right thing for identifying actors however, as it also allows sending messages.
///
/// ## Identity
/// The address is the source of truth with regards to referring to a _specific_ actor in the system.
/// This is in contrast to an `ActorPath` which can be thought of as paths in a filesystem, however without any uniqueness
/// or identity guarantees about the files those paths point to.
///
/// ## Lifecycle
/// Note, that an ActorAddress is a pure value, and as such does not "participate" in an actors lifecycle;
/// Thus, it may represent an address of an actor that has already terminated, so attempts to locate (resolve)
/// an `_ActorRef` for this address may result with a reference to dead letters (meaning, that the actor this address
/// had pointed to does not exist, and most likely is dead / terminated).
///
/// ## Serialization
///
/// An address can be serialized using `Codable` or other serialization mechanisms, and when shared over the network
/// it shall include its local system's address. When using Codable serialization this is done automatically,
/// and when implementing custom serializers the `Serialization.Context` should be used to access the node address
/// to include while serializing the address.
///
/// ## Format
/// The address consists of the following parts:
///
/// ```
/// |              node                 | path              | incarnation |
///  (  protocol | name | host | port  ) ( [segments] name ) (  uint32   )
/// ```
///
/// For example: `sact://human-readable-name@127.0.0.1:7337/user/wallet/id-121242`.
/// Note that the `ActorIncarnation` is not printed by default in the String representation of a path, yet may be inspected on demand.
@available(macOS 10.15, *)
public struct ActorAddress: @unchecked Sendable {
    /// Knowledge about a node being `local` is purely an optimization, and should not be relied on by actual code anywhere.
    /// It is on purpose not exposed to end-user code as well, and must remain so to not break the location transparency promises made by the runtime.
    ///
    /// Internally, this knowledge sometimes is necessary however.
    ///
    /// As far as end users are concerned, local/remote manifests mostly in the address being hidden in a `description` of a local actor,
    /// this way it is not noisy to print actors when running in local only mode, or when listing actors and some of them are local.
    @usableFromInline
    internal var _location: ActorLocation

    public var uniqueNode: UniqueNode {
        switch self._location {
        case .local(let node): return node
        case .remote(let node): return node
        }
    }

    /// Underlying path representation, not attached to a specific Actor instance.
    public var path: ActorPath

    /// Returns the name of the actor represented by this path.
    /// This is equal to the last path segments string representation.
    public var name: String {
        self.path.name
    }

    /// Uniquely identifies the specific "incarnation" of this actor.
    public let incarnation: ActorIncarnation

    /// :nodoc:
    public init(local node: UniqueNode, path: ActorPath, incarnation: ActorIncarnation) {
        self._location = .local(node)
        self.incarnation = incarnation
        self.path = path
    }

    /// :nodoc:
    public init(remote node: UniqueNode, path: ActorPath, incarnation: ActorIncarnation) {
        self._location = .remote(node)
        self.incarnation = incarnation
        self.path = path
    }
}

extension ActorAddress: Hashable {
    public static func == (lhs: ActorAddress, rhs: ActorAddress) -> Bool {
        lhs.incarnation == rhs.incarnation && // quickest to check if the incarnations are the same
            // if they happen to be equal, we don't know yet for sure if it's the same actor or not, as incarnation is just a random ID
            // thus we need to compare the node and path as well
            lhs.uniqueNode == rhs.uniqueNode && lhs.path == rhs.path
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.incarnation)
        hasher.combine(self.uniqueNode)
        hasher.combine(self.path)
    }
}

extension ActorAddress: CustomStringConvertible {
    public var description: String {
        var res = ""
        if self._isRemote {
            res += "\(self.uniqueNode)"
        }
        res += "\(self.path)"
        return res
    }

    public var detailedDescription: String {
        var res = ""
        if self._isRemote {
            res += "\(reflecting: self.uniqueNode)"
        }
        res += "\(self.path)"

        if self.incarnation == ActorIncarnation.wellKnown {
            return res
        } else {
            return "\(res)#\(self.incarnation.value)"
        }
    }

    public var fullDescription: String {
        var res = ""
        res += "\(reflecting: self.uniqueNode)"
        res += "\(self.path)"

        if self.incarnation == ActorIncarnation.wellKnown {
            return res
        } else {
            return "\(res)#\(self.incarnation.value)"
        }
    }
}

extension ActorAddress {
    /// Local root (also known as: "/") actor address.
    /// Only to be used by the "/" root "actor"
    static func _localRoot(on node: UniqueNode) -> ActorAddress {
        ActorPath._root.makeLocalAddress(on: node, incarnation: .wellKnown)
    }

    /// Local dead letters address.
    static func _deadLetters(on node: UniqueNode) -> ActorAddress {
        ActorPath._deadLetters.makeLocalAddress(on: node, incarnation: .wellKnown)
    }
}

public extension ActorAddress {
    /// :nodoc:
    @inlinable
    var _isLocal: Bool {
        switch self._location {
        case .local: return true
        default: return false
        }
    }

    /// :nodoc:
    @inlinable
    var _isRemote: Bool {
        !self._isLocal
    }

    /// :nodoc:
    @inlinable
    var _asRemote: Self {
        let remote = Self(remote: self.uniqueNode, path: self.path, incarnation: self.incarnation)
        return remote
    }

    /// :nodoc:
    @inlinable
    var _asLocal: Self {
        let local = Self(local: self.uniqueNode, path: self.path, incarnation: self.incarnation)
        return local
    }
}

extension ActorAddress: _PathRelationships {
    public var segments: [ActorPathSegment] {
        self.path.segments
    }

    func makeChildAddress(name: String, incarnation: ActorIncarnation) throws -> ActorAddress {
        switch self._location {
        case .local(let node):
            return try .init(local: node, path: self.makeChildPath(name: name), incarnation: incarnation)
        case .remote(let node):
            return try .init(remote: node, path: self.makeChildPath(name: name), incarnation: incarnation)
        }
    }

    /// Creates a new path with `segment` appended
    public func appending(segment: ActorPathSegment) -> ActorAddress {
        switch self._location {
        case .remote(let node):
            return .init(remote: node, path: self.path.appending(segment: segment), incarnation: self.incarnation)
        case .local(let node):
            return .init(local: node, path: self.path.appending(segment: segment), incarnation: self.incarnation)
        }
    }
}

/// Offers arbitrary ordering for predictable ordered printing of things keyed by addresses.
extension ActorAddress: Comparable {
    public static func < (lhs: ActorAddress, rhs: ActorAddress) -> Bool {
        lhs.uniqueNode < rhs.uniqueNode ||
            (lhs.uniqueNode == rhs.uniqueNode && lhs.path < rhs.path) ||
            (lhs.uniqueNode == rhs.uniqueNode && lhs.path == rhs.path && lhs.incarnation < rhs.incarnation)
    }
}

extension Optional: Comparable where Wrapped == UniqueNode {
    public static func < (lhs: UniqueNode?, rhs: UniqueNode?) -> Bool {
        switch (lhs, rhs) {
        case (.some, .none):
            return false
        case (.none, .some):
            return true
        case (.some(let l), .some(let r)):
            return l < r
        case (.none, .none):
            return false
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorLocation

@usableFromInline
internal enum ActorLocation: Hashable, Sendable {
    case local(UniqueNode)
    case remote(UniqueNode)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorPath

/// Represents the name and placement within the actor hierarchy of a given actor.
///
/// Names of user actors MUST:
/// - not start with `$` (those names are reserved for Swift Distributed Actors internal system actors)
/// - contain only ASCII characters and select special characters (listed in `ValidPathSymbols.extraSymbols`)
///
/// - Example: `/user/lightbulbCommander/lightbulb-2012`
public struct ActorPath: _PathRelationships, Hashable, Sendable {
    // TODO: instead back with a String and keep a pos to index quickly into the name for Substring?
    public var segments: [ActorPathSegment]

    public init(root: String) throws {
        try self.init([ActorPathSegment(root)])
    }

    public init(_ segments: [ActorPathSegment]) throws {
        guard !segments.isEmpty else {
            throw ActorPathError.illegalEmptyActorPath
        }
        self.segments = segments
    }

    /// Only the core module may define roots.
    internal init(root: ActorPathSegment) throws {
        try self.init([root])
    }

    /// Special purpose initializer, only for the "/" path. None other may use such path.
    private init() {
        self.segments = []
    }

    /// Appends a segment to this actor path
    internal mutating func append(segment: ActorPathSegment) {
        self.segments.append(segment)
    }

    /// Appends a segment to this actor path
    public mutating func append(_ segment: String) throws {
        try self.segments.append(ActorPathSegment(segment))
    }

    /// Creates a new path with `segment` appended
    public func appending(segment: ActorPathSegment) -> ActorPath {
        var path = self
        path.append(segment: segment)
        return path
    }

    /// Creates a new path with `segment` appended
    public func appending(_ name: String) throws -> ActorPath {
        try self.appending(segment: ActorPathSegment(name))
    }

    /// Creates a new path with a known-to-be-unique naming appended, otherwise faults
    internal func appendingKnownUnique(_ unique: ActorNaming) throws -> ActorPath {
        guard case .unique(let name) = unique.naming else {
            fatalError("Expected known-to-be-unique ActorNaming in this unsafe call; Was: \(unique)")
        }
        return try self.appending(segment: ActorPathSegment(name))
    }

    /// Creates a new path with `segments` appended
    public func appending(segments: [ActorPathSegment]) -> ActorPath {
        var path = self
        for segment in segments {
            path.append(segment: segment)
        }
        return path
    }

    /// Returns the name of the actor represented by this path.
    /// This is equal to the last path segments string representation.
    public var name: String {
        // the only path which has no segments is the "root"
        let lastSegmentName = self.segments.last?.description ?? "/"
        return "\(lastSegmentName)"
    }
}

extension ActorPath: CustomStringConvertible {
    public var description: String {
        let pathSegments: String = self.segments.map(\.value).joined(separator: "/")
        return "/\(pathSegments)"
    }
}

public extension ActorPath {
    static let _root: ActorPath = .init() // also known as "/"
    static let _user: ActorPath = try! ActorPath(root: "user")
    static let _system: ActorPath = try! ActorPath(root: "system")

    internal func makeLocalAddress(on node: UniqueNode, incarnation: ActorIncarnation) -> ActorAddress {
        .init(local: node, path: self, incarnation: incarnation)
    }

    internal func makeRemoteAddress(on node: UniqueNode, incarnation: ActorIncarnation) -> ActorAddress {
        .init(remote: node, path: self, incarnation: incarnation)
    }
}

extension ActorPath: Comparable {
    public static func < (lhs: ActorPath, rhs: ActorPath) -> Bool {
        "\(lhs)" < "\(rhs)"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Path relationships

public protocol _PathRelationships {
    /// Individual segments of the `ActorPath`.
    var segments: [ActorPathSegment] { get }
    func appending(segment: ActorPathSegment) -> Self
}

public extension _PathRelationships {
    /// Combines the base path with a child segment returning the concatenated path.
    internal static func / (base: Self, child: ActorPathSegment) -> Self {
        base.appending(segment: child)
    }

    /// Checks whether this path starts with the passed in `path`.
    func starts(with path: ActorPath) -> Bool {
        self.segments.starts(with: path.segments)
    }

    /// Checks whether this [ActorPath] is a direct descendant of the passed in path.
    ///
    /// Note: Path relationships only take into account the path segments, and can not be used
    ///       to confirm whether or not a specific actor is the child of another another (identified by another unique path).
    ///       Such relationships must be confirmed by using the `_ActorContext.children.hasChild(:UniqueActorPath)` method. TODO: this does not exist yet
    ///
    /// - Parameter path: The path that is suspected to be the parent of `self`
    /// - Returns: `true` if this [ActorPath] is a direct descendant of `maybeParentPath`, `false` otherwise
    func isChildPathOf(_ maybeParentPath: _PathRelationships) -> Bool {
        Array(self.segments.dropLast()) == maybeParentPath.segments // TODO: more efficient impl, without the copying
    }

    /// Checks whether this [ActorPath] is a direct ancestor of the passed in path.
    ///
    /// Note: Path relationships only take into account the path segments, and can not be used
    ///       to confirm whether or not a specific actor is the child of another another (identified by another unique path).
    ///       Such relationships must be confirmed by using the `_ActorContext.children.hasChild(:UniqueActorPath)` method. TODO: this does not exist yet
    ///
    /// - Parameter path: The path that is suspected to be a child of `self`
    /// - Returns: `true` if this [ActorPath] is a direct ancestor of `maybeChildPath`, `false` otherwise
    func isParentOf(_ maybeChildPath: _PathRelationships) -> Bool {
        maybeChildPath.isChildPathOf(self)
    }

    /// Create a generic path to identify a child path of the current path.
    internal func makeChildPath(name: String) throws -> ActorPath {
        try ActorPath(self.segments).appending(name)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Path segments

/// Represents a single segment (actor name) of an ActorPath.
public struct ActorPathSegment: Hashable, Sendable {
    public let value: String

    public init(_ name: String) throws {
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
            (scalar >= ValidActorPathSymbols.a && scalar <= ValidActorPathSymbols.z) ||
                (scalar >= ValidActorPathSymbols.A && scalar <= ValidActorPathSymbols.Z) ||
                (scalar >= ValidActorPathSymbols.zero && scalar <= ValidActorPathSymbols.nine) ||
                ValidActorPathSymbols.extraSymbols.contains(scalar)
        }

        // TODO: accept hex and url encoded things as well
        // http://www.ietf.org/rfc/rfc2396.txt
        var pos = 0
        for c in name {
            let f = c.unicodeScalars.first

            guard f?.isASCII ?? false, isValidASCII(f!) else {
                // TODO: used to be but too much hassle: throw ActorPathError.illegalActorPathElement(name: name, illegal: "\(c)", index: pos)

                throw ActorPathError.illegalActorPathElement(name: name, illegal: "\(c)", index: pos)
            }
            pos += 1
        }
    }
}

extension ActorPathSegment {
    static let _user: ActorPathSegment = try! ActorPathSegment("user")
    static let _system: ActorPathSegment = try! ActorPathSegment("system")
}

extension ActorPathSegment: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "\(self.value)"
    }

    public var debugDescription: String {
        "\(self.value)"
    }
}

private enum ValidActorPathSymbols {
    static let a: UnicodeScalar = "a"
    static let z: UnicodeScalar = "z"
    static let A: UnicodeScalar = "A"
    static let Z: UnicodeScalar = "Z"
    static let zero: UnicodeScalar = "0"
    static let nine: UnicodeScalar = "9"

    static let extraSymbols: String.UnicodeScalarView = "-_.*$+:@&=,!~';<>()".unicodeScalars
}

struct ActorName {
    let name: String
    let incarnation: UInt32
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor Incarnation number

/// Used to uniquely identify a specific "incarnation" of an Actor and therefore provide unique identity to `ActorAddress` and `_ActorRef`s.
///
/// ## Example
/// The incarnation number is a crucial part of actor identity and is used to disambiguate actors which may have resided on the same `ActorPath` at some point.
/// Consider the following example:
///
/// 1. We spawn an actor under the following path `/user/example/something`; in reality the full and unique `ActorAddress`
///    is actually `/user/example/something#546982` (which one can see by printing an actor or address using its `debugDescription`);
///    The trailing `#546982` is the actors incarnation number, which is a randomly assigned number used for identification purposes.
/// 2. This specific actor terminates; so we are free to spawn another actor (usually of the same behavior) on the same path.
/// 3. We spawn another _new actor_ under the same `ActorPath`, yet if we'd inspect its address we would realise that
///    the incarnation number is different: `/user/example/something#11742311`. Thanks to this, even if messages are still
///    being sent to the "previous" occupant of this path, we know they are not intended for the "new" actor to process,
///    and thus shall be delivered to the dead letters queue.
///
/// In short, the incarnation number is used to guarantee that messages are always delivered to their intended recipient,
/// and not another actor which happens to reside on the same path in the actor hierarchy.
///
/// Another way to visualize this mechanism is think about this is like house addresses and sending letters to your friends.
/// If you know your friend's address, you can send them a post card from your vacation. When writing the address, you'd
/// also include your friends name on the postcard. If you had used an old address of your friend even if someone new lived
/// under this address, they would by that name realize that the postcard was intended for the previous tenant of the apartment,
/// rather than being confused because they don't know you. In this scenario the "house address" is an `ActorPath` (like street name),
/// and the `ActorAddress` is the "full intended recipient address" including not only street name, but also your friends unique name.
public struct ActorIncarnation: Equatable, Hashable, ExpressibleByIntegerLiteral, Sendable {
    let value: UInt32

    public init(_ value: Int) {
        self.init(UInt32(value))
    }

    public init(_ value: UInt32) {
        self.value = value
    }

    public init(integerLiteral value: IntegerLiteralType) {
        self.init(UInt32(value))
    }
}

public extension ActorIncarnation {
    /// To be used ONLY by special actors whose existence is wellKnown and identity never-changing.
    /// Examples: `/system/deadLetters` or `/system/cluster`.
    static let wellKnown: ActorIncarnation = .init(0)

    static func random() -> ActorIncarnation {
        ActorIncarnation(UInt32.random(in: UInt32(1) ... UInt32.max))
    }
}

internal extension ActorIncarnation {
    init?(_ value: String?) {
        guard let int = (value.flatMap {
            Int($0)
        }), int >= 0 else {
            return nil
        }
        self.init(int)
    }
}

extension ActorIncarnation: Comparable {
    public static func < (lhs: ActorIncarnation, rhs: ActorIncarnation) -> Bool {
        lhs.value < rhs.value
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Node

// TODO: Would want to rename; this is really protocol + host + port, and a "cute name for humans" we on purpose do not take the name as part or identity
/// A `Node` is a triplet of protocol, host and port that a node is bound to.
///
/// Unlike `UniqueNode`, it does not carry identity (`NodeID`) of a specific incarnation of an actor system node,
/// and represents an address of _any_ node that could live under this address. During the handshake process between two nodes,
/// the remote `Node` that the local side started out to connect with is "upgraded" to a `UniqueNode`, as soon as we discover
/// the remote side's unique node identifier (`NodeID`).
///
/// ### System name / human readable name
/// The `systemName` is NOT taken into account when comparing nodes. The system name is only utilized for human readability
/// and debugging purposes and participates neither in hashcode nor equality of a `Node`, as a node specifically is meant
/// to represent any unique node that can live on specific host & port. System names are useful for human operators,
/// intending to use some form of naming scheme, e.g. adopted from a cloud provider, to make it easier to map nodes in
/// actor system logs, to other external systems. TODO: Note also node roles, which we do not have yet... those are dynamic key/value pairs paired to a unique node.
///
/// - SeeAlso: For more details on unique node ids, refer to: `UniqueNode`.
public struct Node: Hashable, Sendable {
    // TODO: collapse into one String and index into it?
    public var `protocol`: String
    public var systemName: String // TODO: some other name, to signify "this is just for humans"?
    public var host: String
    public var port: Int

    public init(protocol: String, systemName: String, host: String, port: Int) {
        precondition(port > 0, "port MUST be > 0")
        self.protocol = `protocol`
        self.systemName = systemName
        self.host = host
        self.port = port
    }

    public init(systemName: String, host: String, port: Int) {
        self.init(protocol: "sact", systemName: systemName, host: host, port: port)
    }

    public init(host: String, port: Int) {
        self.init(protocol: "sact", systemName: "", host: host, port: port)
    }
}

extension Node: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "\(self.protocol)://\(self.systemName)@\(self.host):\(self.port)"
    }

    public var debugDescription: String {
        self.description
    }
}

extension Node: Comparable {
    // Silly but good enough comparison for deciding "who is lower node"
    // as we only use those for "tie-breakers" any ordering is fine to be honest here.
    public static func < (lhs: Node, rhs: Node) -> Bool {
        "\(lhs)" < "\(rhs)"
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.protocol)
        hasher.combine(self.host)
        hasher.combine(self.port)
    }

    public static func == (lhs: Node, rhs: Node) -> Bool {
        lhs.protocol == rhs.protocol && lhs.host == rhs.host && lhs.port == rhs.port
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: UniqueNode

/// A _unique_ node which includes also the node's unique `UID` which is used to disambiguate
/// multiple incarnations of a system on the same host/port part -- similar to how an `ActorIncarnation`
/// is used on the per-actor level.
///
/// ### Implementation details
/// The unique address of a remote node can only be obtained by performing the handshake with it.
/// Once the remote node accepts our handshake, it offers the other node its unique address.
/// Only once this address has been obtained can a node communicate with actors located on the remote node.
public struct UniqueNode: Hashable, Sendable {
    public typealias ID = UniqueNodeID

    public var node: Node
    public let nid: UniqueNodeID

    public init(node: Node, nid: UniqueNodeID) {
        precondition(node.port > 0, "port MUST be > 0")
        self.node = node
        self.nid = nid
    }

    public init(protocol: String, systemName: String, host: String, port: Int, nid: UniqueNodeID) {
        self.init(node: Node(protocol: `protocol`, systemName: systemName, host: host, port: port), nid: nid)
    }

    public init(systemName: String, host: String, port: Int, nid: UniqueNodeID) {
        self.init(protocol: "sact", systemName: systemName, host: host, port: port, nid: nid)
    }

    public var host: String {
        set {
            self.node.host = newValue
        }
        get {
            self.node.host
        }
    }

    public var port: Int {
        set {
            self.node.port = newValue
        }
        get {
            self.node.port
        }
    }
}

extension UniqueNode: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "\(self.node)"
    }

    public var debugDescription: String {
        let a = self.node
        return "\(a.protocol)://\(a.systemName):\(self.nid)@\(a.host):\(a.port)"
    }
}

extension UniqueNode: Comparable {
    public static func == (lhs: UniqueNode, rhs: UniqueNode) -> Bool {
        // we first compare the NodeIDs since they're quicker to compare and for diff systems always would differ, even if on same physical address
        lhs.nid == rhs.nid && lhs.node == rhs.node
    }

    // Silly but good enough comparison for deciding "who is lower node"
    // as we only use those for "tie-breakers" any ordering is fine to be honest here.
    public static func < (lhs: UniqueNode, rhs: UniqueNode) -> Bool {
        if lhs.node == rhs.node {
            return lhs.nid < rhs.nid
        } else {
            return lhs.node < rhs.node
        }
    }
}

public struct UniqueNodeID: Hashable, Sendable {
    let value: UInt64

    public init(_ value: UInt64) {
        self.value = value
    }
}

extension UniqueNodeID: Comparable {
    public static func < (lhs: UniqueNodeID, rhs: UniqueNodeID) -> Bool {
        lhs.value < rhs.value
    }
}

extension UniqueNodeID: CustomStringConvertible {
    public var description: String {
        "\(self.value)"
    }
}

public extension UniqueNodeID {
    static func random() -> UniqueNodeID {
        UniqueNodeID(UInt64.random(in: 1 ... .max))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Path errors

public enum ActorPathError: Error {
    case illegalEmptyActorPath
    case illegalLeadingSpecialCharacter(name: String, illegal: Character)
    case illegalActorPathElement(name: String, illegal: String, index: Int)
    case rootPathSegmentRequiredToStartWithSlash(segment: ActorPathSegment)
    case invalidPath(String)
}
