//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed
import Foundation

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorID

/// Convenience alias for ``ClusterSystem/ActorID``.
public typealias ActorID = ClusterSystem.ActorID

extension ClusterSystem.ActorID {
    @propertyWrapper
    public struct Metadata<Value: Sendable & Codable> {
        let keyType: Any.Type
        let id: String

        public init(_ keyPath: KeyPath<ActorMetadataKeys, ActorMetadataKey<Value>>) {
            let key = ActorMetadataKeys.__instance[keyPath: keyPath]
            self.id = key.id
            self.keyType = type(of: key)
        }

        public var wrappedValue: Value {
            get { fatalError("called wrappedValue getter") }
            set { fatalError("called wrappedValue setter") }
        }

        public var projectedValue: Value {
            get { fatalError("called projectedValue getter") }
            set { fatalError("called projectedValue setter") }
        }

        public static subscript<EnclosingSelf: DistributedActor, FinalValue>(
            _enclosingInstance myself: EnclosingSelf,
            wrapped wrappedKeyPath: ReferenceWritableKeyPath<EnclosingSelf, FinalValue>,
            storage storageKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Self>
        ) -> Value where EnclosingSelf.ActorSystem == ClusterSystem, EnclosingSelf.ID == ClusterSystem.ActorID {
            get {
                let key = myself[keyPath: storageKeyPath]
                guard let value = myself.id.metadata[key.id] else {
                    fatalError("ActorID Metadata for key \(key.id):\(key.keyType) was not assigned initial value, assign one in the distributed actor's initializer.")
                }
                return value as! Value
            }
            set {
                let metadata = myself.id.metadata
                let key = myself[keyPath: storageKeyPath]
                if let value = metadata[key.id] {
                    fatalError("Attempted to override ActorID Metadata for key \(key.id):\(key.keyType) which already had value: [\(value)] with new value: [\(String(describing: newValue))]")
                }
                metadata[key.id] = newValue

                if key.id == ActorMetadataKeys.__instance.wellKnown.id {
                    myself.actorSystem._wellKnownActorReady(myself)
                }
            }
        }
    }
}

extension ClusterSystem {
    /// Uniquely identifies a DistributedActor within the cluster.
    ///
    /// It is assigned by the `ClusterSystem` at initialization time of a distributed actor,
    /// and remains associated with that concrete actor until it terminates.
    ///
    /// ## Identity
    /// The id is the source of truth with regards to referring to a _specific_ actor in the system.
    /// Identities can be treated as globally (or at least cluster-wide) unique identifiers of actors.
    ///
    /// Note that distributed actors automatically synthesize an `Equatable` and `Hashable` conformance,
    /// by delegating to the `ID` they are assigned. As such, if two actor instances have the same `ID`,
    /// those actor instances are considered equal as well. In practice this can happen e.g. in tests,
    /// when you have two "local" and "remote" sides of a test, and want to confirm if the remote side
    /// stored the "right" actor -- you can compare remote and local actor instances using normal equality,
    /// and the comparison will be correct.
    ///
    /// The location of the distributed actor (i.e. it being "remote" or "local") is not taken into account
    /// during comparison of IDs, however does matter that it is on the same actual unique node.
    ///
    /// Additional information can be attached to them using ``ActorMetadata`` however those do not impact
    /// the identity or equality of the ID, or distributed actors identified by those IDs.
    ///
    /// ## Lifecycle
    /// An `ActorID` is a pure value, and as such does not "participate" in an actors lifecycle.
    ///
    /// It may represent an address of an actor that has already terminated, so attempts to locate (resolve)
    /// an actor for this id may fail if attempting to resolve a local actor, or result in a remote reference
    /// pointing at a dead actor id, in which case calls to it will return errors, and the remote actor system,
    /// may log messages sent to such dead actor as "dead letters".
    ///
    /// Storing an `ActorID` instead of the concrete `DistributedActor` is also a common pattern to avoid
    /// retaining the actor, while retaining the ability to know if we have already stored this actor or not.
    /// For example, in a lobby system, we might need to only store actor identifiers, and ``LifecycleWatch/watchTermination(of:whenTerminated:file:line:)``
    /// some actors, in order to not retain them in the lobby actor itself. If the same actor messages us again to "join",
    /// we would already know that we have already seen it, and could handle it joining again in some other way.
    ///
    /// ## Actor Tags
    ///
    /// It is possible to enrich actor identities with additional information using "tags".
    ///
    /// Some tags may be carried to remote peers, while others are intended only for local use,
    /// e.g. to inform the actor system to resolve the actor identity using some special treatment etc.
    ///
    /// Please refer to ``ActorMetadata`` for an in depth discussion about tagging.
    ///
    /// ## Serialization
    ///
    /// An ID can be serialized using `Codable` or other serialization mechanisms, and when shared over the network
    /// it shall include its local system's address. When using Codable serialization this is done automatically,
    /// and when implementing custom serializers the `Serialization.Context` should be used to access the node address
    /// to include while serializing the address.
    public struct ActorID: @unchecked Sendable {
        /// Knowledge about a node being `local` is purely an optimization, and should not be relied on by actual code anywhere.
        /// It is on purpose not exposed to end-user code as well, and must remain so to not break the location transparency promises made by the runtime.
        ///
        /// Internally, this knowledge sometimes is necessary however.
        ///
        /// As far as end users are concerned, local/remote manifests mostly in the address being hidden in a `description` of a local actor,
        /// this way it is not noisy to print actors when running in local only mode, or when listing actors and some of them are local.
        @usableFromInline
        internal var _location: ActorLocation

        /// The unique node on which the actor identified by this identity is located.
        public var uniqueNode: UniqueNode {
            switch self._location {
            case .local(let node): return node
            case .remote(let node): return node
            }
        }

        #if DEBUG
        private var debugID = UUID()
        #endif

        /// Collection of tags associated with this actor identity.
        ///
        /// Tags MAY be transferred to other peers as the identity is replicated, however they are not necessary to uniquely identify the actor.
        /// Tags can carry additional information such as the type of the actor identified by this identity, or any other user defined "roles" or similar tags.
        ///
        /// - SeeAlso: ``ActorMetadata`` for a detailed discussion of some frequently used tags.
        public var metadata: ActorMetadata {
            self.context.metadata
        }

        /// Internal "actor context" which is used as storage for additional cluster actor features, such as watching.
        internal var context: DistributedActorContext

        /// Underlying path representation, not attached to a specific Actor instance.
        public var path: ActorPath { // FIXME(distributed): make optional
            get {
                guard let path = metadata.path else {
                    fatalError("FIXME: ActorTags.path was not set on \(self.incarnation)! NOTE THAT PATHS ARE TO BECOME OPTIONAL!!!") // FIXME(distributed): must be removed
                }
                return path
            }
            set {
                self.metadata[ActorMetadataKeys.__instance.path.id] = newValue
            }
        }

        /// Returns the name of the actor represented by this path.
        /// This is equal to the last path segments string representation.
        public var name: String { // FIXME(distributed): make optional
            self.path.name
        }

        /// Uniquely identifies the specific "incarnation" of this actor.
        public let incarnation: ActorIncarnation

        // TODO(distributed): remove this initializer, as it is only for Behavior actors
        init(local node: UniqueNode, path: ActorPath?, incarnation: ActorIncarnation) {
            self.context = .init(lifecycle: nil, remoteCallInterceptor: nil)
            self._location = .local(node)
            self.incarnation = incarnation
            if let path {
                self.context.metadata.path = path
            }
            traceLog_DeathWatch("Made ID: \(self)")
        }

        // TODO(distributed): remove this initializer, as it is only for Behavior actors
        init(remote node: UniqueNode, path: ActorPath?, incarnation: ActorIncarnation) {
            self.context = .init(lifecycle: nil, remoteCallInterceptor: nil)
            self._location = .remote(node)
            self.incarnation = incarnation
            if let path {
                self.context.metadata.path = path
            }
            traceLog_DeathWatch("Made ID: \(self)")
        }

        public init<Act>(remote node: UniqueNode, type: Act.Type, incarnation: ActorIncarnation)
            where Act: DistributedActor, Act.ActorSystem == ClusterSystem
        {
            self.context = .init(lifecycle: nil, remoteCallInterceptor: nil)
            self._location = .remote(node)
            self.incarnation = incarnation
            if let mangledName = _mangledTypeName(type) { // TODO: avoid mangling names on every spawn?
                self.context.metadata.type = .init(mangledName: mangledName)
            }
            traceLog_DeathWatch("Made ID: \(self)")
        }

        init<Act>(local node: UniqueNode, type: Act.Type, incarnation: ActorIncarnation,
                  context: DistributedActorContext)
            where Act: DistributedActor, Act.ActorSystem == ClusterSystem
        {
            self.context = context
            self._location = .local(node)
            self.incarnation = incarnation
            if let mangledName = _mangledTypeName(type) { // TODO: avoid mangling names on every spawn?
                self.context.metadata.type = .init(mangledName: mangledName)
            }
            traceLog_DeathWatch("Made ID: \(self)")
        }

        init<Act>(remote node: UniqueNode, type: Act.Type, incarnation: ActorIncarnation,
                  context: DistributedActorContext)
            where Act: DistributedActor, Act.ActorSystem == ClusterSystem
        {
            self.context = context
            self._location = .remote(node)
            self.incarnation = incarnation
            if let mangledName = _mangledTypeName(type) { // TODO: avoid mangling names on every spawn?
                self.context.metadata.type = .init(mangledName: mangledName)
            }
            traceLog_DeathWatch("Made ID: \(self)")
        }

        internal var withoutLifecycle: Self {
            var copy = self
            copy.context = .init(
                lifecycle: nil,
                remoteCallInterceptor: nil,
                metadata: self.metadata
            )
            return copy
        }

        public var withoutMetadata: Self {
            var copy = self
            copy.context = .init(
                lifecycle: self.context.lifecycle,
                remoteCallInterceptor: nil,
                metadata: nil
            )
            return copy
        }
    }
}

extension DistributedActor where ActorSystem == ClusterSystem {
    public nonisolated var metadata: ActorMetadata {
        self.id.metadata
    }
}

extension DistributedActor where ActorSystem == ClusterSystem {
    /// Provides the actor context for use within this actor.
    /// The context must not be mutated concurrently with the owning actor, however the things it stores may provide additional synchronization to make this safe.
    internal var context: DistributedActorContext {
        self.id.context
    }
}

extension ActorID: Hashable {
    public static func == (lhs: ActorID, rhs: ActorID) -> Bool {
        // Check the metadata based well-known identity names.
        //
        // The legacy "well known path" is checked using the normal path below,
        // since it is implemented as incarnation == 0, and an unique path.
        if let lhsWellKnownName = lhs.metadata.wellKnown {
            if let rhsWellKnownName = rhs.metadata.wellKnown {
                // If we're comparing "well known" actors, we ignore the concrete incarnation,
                // and compare the well known name instead. This works for example for "$receptionist"
                // and other well known names, that can be resolved using them, without an incarnation number.
                if lhsWellKnownName == rhsWellKnownName, lhs.uniqueNode == rhs.uniqueNode {
                    return true
                }
            } else {
                // 'lhs' WAS well known, but 'rhs' was not
                return false
            }
        } else if rhs.metadata.wellKnown != nil {
            // 'lhs' was NOT well known, but 'rhs' was:
            return false
        }

        // quickest to check if the incarnations are the same
        // if they happen to be equal, we don't know yet for sure if it's the same actor or not,
        // as incarnation is just a random ID thus we need to compare the node and path as well
        return lhs.incarnation == rhs.incarnation &&
            lhs.uniqueNode == rhs.uniqueNode &&
            lhs.path == rhs.path
    }

    public func hash(into hasher: inout Hasher) {
        if let wellKnownName = self.metadata.wellKnown {
            hasher.combine(wellKnownName)
        } else {
            hasher.combine(self.incarnation)
        }
        hasher.combine(self.uniqueNode)
        hasher.combine(self.path)
    }
}

extension ActorID: CustomStringConvertible {
    public var description: String {
        var res = ""
        if self._isRemote {
            res += "\(self.uniqueNode)"
        }

        if let wellKnown = self.metadata.wellKnown {
            return "[$wellKnown: \(wellKnown)]"
        }

        if let path = self.metadata.path {
            // this is ready for making paths optional already -- and behavior removals
            res += "\(path)"
        } else {
            res += "\(self.incarnation)"
        }

        if !self.metadata.isEmpty {
            // TODO: we special case the "just a path" metadata to not break existing ActorRef tests
            if self.metadata.count == 1, self.metadata.path != nil {
                return res
            }

            res += self.metadata.description
        }

        return res
    }

    public var detailedDescription: String {
        var res = ""
        if self._isRemote {
            res += "\(reflecting: self.uniqueNode)"
        }
        res += "\(self.path)"

        if self.incarnation != ActorIncarnation.wellKnown {
            res += "#\(self.incarnation.value)"
        }

        if !self.metadata.isEmpty {
            res += self.metadata.description
        }

        return res
    }

    /// Prints all information contained in the ID, including `incarnation` and all `metadata`.
    public var fullDescription: String {
        var res = ""
        res += "\(reflecting: self.uniqueNode)"
        res += "\(self.path)"
        res += "#\(self.incarnation.value)"

        if !self.metadata.isEmpty {
            res += self.metadata.description
        }

        #if DEBUG
        res += "{debugID:\(debugID)}"
        #endif

        return res
    }
}

extension ActorID {
    /// Local root (also known as: "/") actor address.
    /// Only to be used by the "/" root "actor"
    static func _localRoot(on node: UniqueNode) -> ActorID {
        ActorPath._root.makeLocalID(on: node, incarnation: .wellKnown)
    }

    /// Local dead letters address.
    static func _deadLetters(on node: UniqueNode) -> ActorID {
        ActorPath._deadLetters.makeLocalID(on: node, incarnation: .wellKnown)
    }
}

extension ActorID {
    public var _isLocal: Bool {
        switch self._location {
        case .local: return true
        default: return false
        }
    }

    public var _isRemote: Bool {
        !self._isLocal
    }

    public var _asRemote: Self {
        var remote = self
        remote._location = .remote(remote.uniqueNode)
        return remote
    }

    public var _asLocal: Self {
        var local = self
        local._location = .local(self.uniqueNode)
        return local
    }
}

extension ActorID: _PathRelationships {
    public var segments: [ActorPathSegment] {
        self.path.segments
    }

    func makeChildAddress(name: String, incarnation: ActorIncarnation) throws -> ActorID {
        switch self._location {
        case .local(let node):
            return try .init(local: node, path: self.makeChildPath(name: name), incarnation: incarnation)
        case .remote(let node):
            return try .init(remote: node, path: self.makeChildPath(name: name), incarnation: incarnation)
        }
    }

    /// Creates a new path with `segment` appended
    public func appending(segment: ActorPathSegment) -> ActorID {
        switch self._location {
        case .remote(let node):
            return .init(remote: node, path: self.path.appending(segment: segment), incarnation: self.incarnation)
        case .local(let node):
            return .init(local: node, path: self.path.appending(segment: segment), incarnation: self.incarnation)
        }
    }
}

/// Offers arbitrary ordering for predictable ordered printing of things keyed by addresses.
extension ActorID: Comparable {
    public static func < (lhs: ActorID, rhs: ActorID) -> Bool {
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
    internal func appendingKnownUnique(_ unique: _ActorNaming) throws -> ActorPath {
        guard case .unique(let name) = unique.naming else {
            fatalError("Expected known-to-be-unique _ActorNaming in this unsafe call; Was: \(unique)")
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

extension ActorPath {
    public static let _root: ActorPath = .init() // also known as "/"
    public static let _user: ActorPath = try! ActorPath(root: "user")
    public static let _system: ActorPath = try! ActorPath(root: "system")

    internal func makeLocalID(on node: UniqueNode, incarnation: ActorIncarnation) -> ActorID {
        ActorID(local: node, path: self, incarnation: incarnation)
    }

    internal func makeRemoteID(on node: UniqueNode, incarnation: ActorIncarnation) -> ActorID {
        ActorID(remote: node, path: self, incarnation: incarnation)
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

extension _PathRelationships {
    /// Combines the base path with a child segment returning the concatenated path.
    internal static func / (base: Self, child: ActorPathSegment) -> Self {
        base.appending(segment: child)
    }

    /// Checks whether this path starts with the passed in `path`.
    public func starts(with path: ActorPath) -> Bool {
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
    public func isChildPathOf(_ maybeParentPath: _PathRelationships) -> Bool {
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
    public func isParentOf(_ maybeChildPath: _PathRelationships) -> Bool {
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

/// Used to uniquely identify a specific "incarnation" of an Actor and therefore provide unique identity to `ActorID` and `_ActorRef`s.
///
/// ## Example
/// The incarnation number is a crucial part of actor identity and is used to disambiguate actors which may have resided on the same `ActorPath` at some point.
/// Consider the following example:
///
/// 1. We spawn an actor under the following path `/user/example/something`; in reality the full and unique `ActorID`
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
/// and the `ActorID` is the "full intended recipient address" including not only street name, but also your friends unique name.
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

extension ActorIncarnation {
    /// To be used ONLY by special actors whose existence is wellKnown and identity never-changing.
    /// Examples: `/system/deadLetters` or `/system/cluster`.
    @available(*, deprecated, message: "Useful only with behavior actors, will be removed entirely")
    internal static let wellKnown: ActorIncarnation = .init(0)

    public static func random() -> ActorIncarnation {
        ActorIncarnation(UInt32.random(in: UInt32(1) ... UInt32.max))
    }
}

extension ActorIncarnation {
    internal init?(_ value: String?) {
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

extension UniqueNodeID {
    public static func random() -> UniqueNodeID {
        UniqueNodeID(UInt64.random(in: 1 ... .max))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Path errors

enum ActorPathError: Error {
    case illegalEmptyActorPath
    case illegalLeadingSpecialCharacter(name: String, illegal: Character)
    case illegalActorPathElement(name: String, illegal: String, index: Int)
    case rootPathSegmentRequiredToStartWithSlash(segment: ActorPathSegment)
    case invalidPath(String)
}
