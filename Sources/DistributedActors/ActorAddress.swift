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
// MARK: ActorAddress

/// Uniquely identifies an Actor within a (potentially clustered) Actor System.
/// Most of the time, using an `ActorRef` is the right thing for identifying actors however, as it also allows sending messages.
///
/// ## Identity
/// The address is the source of truth with regards to referring to a _specific_ actor in the system.
/// This is in contrast to an `ActorPath` which can be thought of as paths in a filesystem, however without any uniqueness
/// or identity guarantees about the files those paths point to.
///
/// ## Lifecycle
/// Note, that an ActorAddress is a pure value, and as such does not "participate" in an actors lifecycle;
/// Thus, it may represent an address of an actor that has already terminated, so attempts to locate (resolve)
/// an `ActorRef` for this address may result with a reference to dead letters (meaning, that the actor this address
/// had pointed to does not exist, and most likely is dead / terminated).
///
/// ## Serialization
///
/// An address can be serialized using `Codable` or other serialization mechanisms, and when shared over the network
/// it shall include its local system's address. When using Codable serialization this is done automatically,
/// and when implementing custom serializers the `ActorSerializationContext` should be used to access the node address
/// to include while serializing the address.
///
/// ## Format
/// The address consists of the following parts:
///
/// ```
/// |              node                | path              | incarnation |
/// ( protocol | (name) | host | port ) ( [segments] name ) (   uint32   )
/// ```
///
/// For example: `sact://human-readable-name@127.0.0.1:7337/user/wallet/id-121242`.
/// Note that the `ActorIncarnation` is not printed by default in the String representation of a path, yet may be inspected on demand.
public struct ActorAddress: Equatable, Hashable {
    @usableFromInline
    internal var _location: ActorLocation

    /// Returns a remote node's address if the address points to a remote actor,
    /// or `nil` if the referred to actor is local to the system the address was obtained from.
    public var node: UniqueNode? {
        switch self._location {
        case .local:
            return nil // TODO: we could make it such that we return the owning address :thinking:
        case .remote(let remote):
            return remote
        }
    }

    // TODO: public var identity: ActorIdentity = Path + Name

    /// Underlying path representation, not attached to a specific Actor instance.
    public var path: ActorPath

    /// Returns the name of the actor represented by this path.
    /// This is equal to the last path segments string representation.
    public var name: String {
        return self.path.name
    }

    /// Uniquely identifies the specific "incarnation" of this actor.
    public let incarnation: ActorIncarnation

    /// Creates a _local_ actor address.
    ///
    /// Usually NOT intended to be used directly in user code.
    public init(path: ActorPath, incarnation: ActorIncarnation) {
        self._location = .local
        self.path = path
        self.incarnation = incarnation
    }

    /// Creates an actor address referring to an address on a _remote_ `node`.
    ///
    /// Usually NOT intended to be used directly in user code, but rather obtained from the serialization infrastructure.
    public init(node: UniqueNode, path: ActorPath, incarnation: ActorIncarnation) {
        self._location = .remote(node)
        self.path = path
        self.incarnation = incarnation
    }
}

extension ActorAddress: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        var res = ""
        switch self._location {
        case .local:
            () // ok
        case .remote(let addr):
            res.reserveCapacity(64) // estimate based on fact that we'll have an node address part
            res += "\(addr)"
        }

        res += "\(self.path)"

        return res
    }

    public var debugDescription: String {
        if self.incarnation == ActorIncarnation.perpetual {
            return "\(self.description)"
        } else {
            return "\(self.description)#\(self.incarnation.value)"
        }
    }
}

extension ActorAddress {
    /// Local root (also known as: "/") actor address.
    /// Only to be used by the "/" root "actor"
    internal static let _localRoot: ActorAddress = ActorPath._root.makeLocalAddress(incarnation: .perpetual)
    internal static let _deadLetters: ActorAddress = ActorPath._deadLetters.makeLocalAddress(incarnation: .perpetual)
    internal static let _cluster: ActorAddress = ActorPath._cluster.makeLocalAddress(incarnation: .perpetual)
}

extension ActorAddress {
    @inlinable
    internal var isLocal: Bool {
        switch self._location {
        case .local: return true
        default: return false
        }
    }

    @inlinable
    internal var isRemote: Bool {
        return !self.isLocal
    }
}

extension ActorAddress: PathRelationships {
    public var segments: [ActorPathSegment] {
        return self.path.segments
    }

    func makeChildAddress(name: String, incarnation: ActorIncarnation) throws -> ActorAddress {
        if let node = self.node {
            return try .init(node: node, path: self.makeChildPath(name: name), incarnation: incarnation)
        } else {
            return try .init(path: self.makeChildPath(name: name), incarnation: incarnation)
        }
    }

    /// Creates a new path with `segment` appended
    public func appending(segment: ActorPathSegment) -> ActorAddress {
        switch self._location {
        case .remote(let node):
            return .init(node: node, path: self.path.appending(segment: segment), incarnation: self.incarnation)
        case .local:
            return .init(path: self.path.appending(segment: segment), incarnation: self.incarnation)
        }
    }
}

/// Offers arbitrary ordering for predictable ordered printing of things keyed by addresses.
extension ActorAddress: Comparable {
    public static func < (lhs: ActorAddress, rhs: ActorAddress) -> Bool {
        switch (lhs.node?.node, rhs.node?.node) {
        case (.some(let lhsNode), .some(let rhsNode)):
            // we do this to avoid using the random node id to impact how we sort actors by the "visible" section of a node address
            return lhsNode < rhsNode || lhs.path < rhs.path || lhs.incarnation < rhs.incarnation
        default:
            return lhs.path < rhs.path || lhs.incarnation < rhs.incarnation
        }
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
internal enum ActorLocation: Hashable {
    case local
    case remote(UniqueNode)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorPath

/// Represents the name and placement within the actor hierarchy of a given actor.
///
/// Names of user actors MUST:
/// - not start with `$` (those names are reserved for Swift Distributed Actors internal system actors)
/// - contain only ASCII characters and select special characters (listed in `ValidPathSymbols.extraSymbols`
///
/// - Example: `/user/lightbulbMaster/lightbulb-2012`
public struct ActorPath: PathRelationships, Hashable {
    // TODO: instead back with a String and keep a pos to index quickly into the name for Substring?
    public var segments: [ActorPathSegment]

    public init(root: String) throws {
        try self.init([ActorPathSegment(root)])
    }

    init(_ segments: [ActorPathSegment]) throws {
        guard !segments.isEmpty else {
            throw ActorPathError.illegalEmptyActorPath
        }
        self.segments = segments
    }

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
    internal func appending(segment: ActorPathSegment) -> ActorPath {
        var path = self
        path.append(segment: segment)
        return path
    }

    /// Creates a new path with `segment` appended
    public func appending(_ name: String) throws -> ActorPath {
        return try self.appending(segment: ActorPathSegment(name))
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
        let pathSegments: String = self.segments.map { $0.value }.joined(separator: "/")
        return "/\(pathSegments)"
    }
}

extension ActorPath {
    internal static let _root: ActorPath = .init() // also known as "/"
    internal static let _user: ActorPath = try! ActorPath(root: "user")
    internal static let _system: ActorPath = try! ActorPath(root: "system")

    internal func makeLocalAddress(incarnation: ActorIncarnation) -> ActorAddress {
        return .init(path: self, incarnation: incarnation)
    }

    internal func makeRemoteAddress(on node: UniqueNode, incarnation: ActorIncarnation) -> ActorAddress {
        return .init(node: node, path: self, incarnation: incarnation)
    }
}

extension ActorPath: Comparable {
    public static func < (lhs: ActorPath, rhs: ActorPath) -> Bool {
        return "\(lhs)" < "\(rhs)"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Path relationships

protocol PathRelationships {
    /// Individual segments of the `ActorPath`.
    var segments: [ActorPathSegment] { get }
    func appending(segment: ActorPathSegment) -> Self
}

extension PathRelationships {
    /// Combines the base path with a child segment returning the concatenated path.
    static func / (base: Self, child: ActorPathSegment) -> Self {
        return base.appending(segment: child)
    }

    /// Checks whether this path starts with the passed in `path`.
    func starts(with path: ActorPath) -> Bool {
        return self.segments.starts(with: path.segments)
    }

    /// Checks whether this [ActorPath] is a direct descendant of the passed in path.
    ///
    /// Note: Path relationships only take into account the path segments, and can not be used
    ///       to confirm whether or not a specific actor is the child of another another (identified by another unique path).
    ///       Such relationships must be confirmed by using the `ActorContext.children.hasChild(:UniqueActorPath)` method. TODO: this does not exist yet
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
    ///       Such relationships must be confirmed by using the `ActorContext.children.hasChild(:UniqueActorPath)` method. TODO: this does not exist yet
    ///
    /// - Parameter path: The path that is suspected to be a child of `self`
    /// - Returns: `true` if this [ActorPath] is a direct ancestor of `maybeChildPath`, `false` otherwise
    func isParentOf(_ maybeChildPath: PathRelationships) -> Bool {
        return maybeChildPath.isChildPathOf(self)
    }

    /// Create a generic path to identify a child path of the current path.
    func makeChildPath(name: String) throws -> ActorPath {
        return try ActorPath(self.segments).appending(name)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Path segments

/// Represents a single segment (actor name) of an ActorPath.
public struct ActorPathSegment: Hashable {
    let value: String

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
            return (scalar >= ValidActorPathSymbols.a && scalar <= ValidActorPathSymbols.z) ||
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
    internal static let _user: ActorPathSegment = try! ActorPathSegment("user")
    internal static let _system: ActorPathSegment = try! ActorPathSegment("system")
}

extension ActorPathSegment: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        return "\(self.value)"
    }

    public var debugDescription: String {
        return "\(self.value)"
    }
}

private struct ValidActorPathSymbols {
    static let a: UnicodeScalar = "a"
    static let z: UnicodeScalar = "z"
    static let A: UnicodeScalar = "A"
    static let Z: UnicodeScalar = "Z"
    static let zero: UnicodeScalar = "0"
    static let nine: UnicodeScalar = "9"

    static let extraSymbols: String.UnicodeScalarView = "-_.*$+:@&=,!~';".unicodeScalars
}

struct ActorName {
    let name: String
    let incarnation: UInt32
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor Incarnation number

/// Used to uniquely identify a specific "incarnation" of an Actor and therefore provide unique identity to `ActorAddress` and `ActorRef`s.
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
public struct ActorIncarnation: Equatable, Hashable {
    let value: UInt32

    public init(_ value: Int) {
        self.init(UInt32(value))
    }

    public init(_ value: UInt32) {
        self.value = value
    }
}

public extension ActorIncarnation {
    /// To be used ONLY by special actors whose existence is perpetual and identity never-changing.
    /// Examples: `/system/deadLetters` or `/system/cluster`.
    static let perpetual: ActorIncarnation = ActorIncarnation(0)

    static func random() -> ActorIncarnation {
        return ActorIncarnation(UInt32.random(in: UInt32(1) ... UInt32.max))
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
        return lhs.value < rhs.value
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Node

public struct Node: Hashable {
    // TODO: collapse into one String and index into it?
    public let `protocol`: String
    public var systemName: String
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
}

extension Node: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        return "\(self.protocol)://\(self.systemName)@\(self.host):\(self.port)"
    }

    public var debugDescription: String {
        return self.description
    }
}

extension Node: Comparable {
    // Silly but good enough comparison for deciding "who is lower node"
    // as we only use those for "tie-breakers" any ordering is fine to be honest here.
    public static func < (lhs: Node, rhs: Node) -> Bool {
        return "\(lhs)" < "\(rhs)"
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
public struct UniqueNode: Hashable {
    public var node: Node
    public let nid: NodeID

    public init(node: Node, nid: NodeID) {
        precondition(node.port > 0, "port MUST be > 0")
        self.node = node
        self.nid = nid
    }

    public init(protocol: String, systemName: String, host: String, port: Int, nid: NodeID) {
        self.init(node: Node(protocol: `protocol`, systemName: systemName, host: host, port: port), nid: nid)
    }

    public init(systemName: String, host: String, port: Int, nid: NodeID) {
        self.init(protocol: "sact", systemName: systemName, host: host, port: port, nid: nid)
    }

    var host: String {
        set {
            self.node.host = newValue
        }
        get {
            return self.node.host
        }
    }

    var port: Int {
        set {
            self.node.port = newValue
        }
        get {
            return self.node.port
        }
    }
}

extension UniqueNode: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        return "\(self.node)"
    }

    public var debugDescription: String {
        let a = self.node
        return "\(a.protocol)://\(a.systemName):\(self.nid)@\(a.host):\(a.port)"
    }
}

extension UniqueNode: Comparable {
    public static func == (lhs: UniqueNode, rhs: UniqueNode) -> Bool {
        // we first compare the NodeIDs since they're quicker to compare and for diff systems always would differ, even if on same physical address
        return lhs.nid == rhs.nid && lhs.node == rhs.node
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

public struct NodeID: Hashable {
    let value: UInt32 // TODO: redesign / reconsider exact size

    public init(_ value: UInt32) {
        self.value = value
    }
}

extension NodeID: Comparable {
    public static func < (lhs: NodeID, rhs: NodeID) -> Bool {
        return lhs.value < rhs.value
    }
}

extension NodeID: CustomStringConvertible {
    public var description: String {
        return "\(self.value)"
    }
}

public extension NodeID {
    static func random() -> NodeID {
        return NodeID(UInt32.random(in: 1 ... .max))
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
