//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActorsConcurrencyHelpers

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor Name

extension _ActorNaming {
    /// Default actor naming strategy; whereas the name MUST be unique under a given path.
    ///
    /// I.e. if a parent actor spawns `.unique(worker)`
    ///
    /// This naming is used by the `ExpressibleByStringLiteral` and `ExpressibleByStringInterpolation` conversions.
    ///
    /// - Faults: when passed in name contains illegal characters. See `_ActorNaming` for detailed rules about actor naming.
    public static func unique(_ name: String) -> _ActorNaming {
        _ActorNaming.validateUserProvided(nameOrPrefix: name)
        return .init(unchecked: .unique(name))
    }

    /// Naming strategy prefixing a sequence of names with a common prefix, followed by a `-` character and an identifier,
    /// as assigned by the context in which the name is being given; E.g. if spawning multiple temporary actors from a parent
    /// actor, it may name them with subsequent numbers or letters of a limited alphabet.
    ///
    /// - Faults: when passed in name contains illegal characters. See `_ActorNaming` for detailed rules about actor naming.
    public static func prefixed(with prefix: String) -> _ActorNaming {
        _ActorNaming.validateUserProvided(nameOrPrefix: prefix)
        return .init(unchecked: .prefixed(prefix: prefix, suffixScheme: .letters))
    }

    /// Shorthand for defining "anonymous" actor names, which carry
    public static var anonymous: _ActorNaming {
        .init(unchecked: .prefixed(prefix: "$anonymous", suffixScheme: .letters))
    }

    /// Performs some initial name validation, like user provided names not being allowed to start with $ etc.
    /// Additional name validity checks are performed when constructing the `ActorPathPathSegment`, as those validations apply to all segments,
    /// regardless of their origin.
    private static func validateUserProvided(nameOrPrefix: String) {
        guard !nameOrPrefix.starts(with: "$") else {
            // only system and anonymous actors are allowed have names beginning with "$"
            fatalError("User defined actor names MUST NOT start with $ sign, yet was: [\(nameOrPrefix)]")
        }
    }
}

extension _ActorNaming {
    /// Special naming scheme applied to `ask` actors.
    static var ask: _ActorNaming = .init(unchecked: .prefixed(prefix: "$ask", suffixScheme: .letters))

    /// Naming for adapters (`context.messageAdapter`)
    static let adapter: _ActorNaming = .init(unchecked: .unique("$messageAdapter"))
}

/// Used while spawning actors to identify how its name should be created.
public struct _ActorNaming: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Hashable {
    // We keep an internal enum, but do not expose it as we may want to add more naming strategies in the future?
    internal enum _Naming: Hashable {
        case unique(String)
        // case uniqueNumeric(NumberingScheme)
        case prefixed(prefix: String, suffixScheme: SuffixScheme)
    }

    internal enum SuffixScheme {
        /// Scheme optimized for sequential related to each other entities, such as workers, or process identifiers.
        /// resulting in sequential numeric values: `1, 2, 3, ..., 9, 10, 11, 12, ...`
        ///
        case sequentialNumeric

        /// Scheme optimized for human readability of the identifiers.
        ///
        /// This scheme is inspired by the "human-oriented base-32 encoding" as defined by z-base-32 [1],
        /// however is not a full implementation thereof, as we only use it to encode 32bit integer identifiers,
        /// and not encode/decode information or arbitrary length.
        ///
        /// This scheme on purpose does not yield "growing" ordered values if sorted lexicographically,
        /// as using this scheme indicates that the numbering (order) of the spawned entities should not matter,
        /// nor should it be used as inherent counter of "how many" were spawned. This information can however if need be
        /// restored by decoding the zBase32 representation into a number by using its coding alphabet.
        ///
        /// ### Alphabet
        /// The alphabet used to in zBase32 on purpose leaves out the following commonly confused characters.
        ///
        /// Quoting the z-base-32 Alphabet section:
        ///     There are 26 alphabet characters and 10 digits, for a total of 36 characters
        ///     available. We need only 32 characters for our base-32 alphabet, so we can
        ///     choose four characters to exclude. This is where we part company with
        ///     traditional base-32 encodings. For example [1] eliminates `0', `1', `8', and
        ///    `9'. This choice eliminates two characters that are relatively unambiguous
        ///     (`8' and `9') while retaining others that are potentially confusing. Others
        ///     have suggested eliminating `0', `1', `O', and `L', which is likewise suboptimal.
        ///
        ///     Our choice of confusing characters to eliminate is: `0', `l', `v', and `2'. Our
        ///     reasoning is that `0' is potentially mistaken for `o', that `l' is potentially
        ///     mistaken for `1' or `i', that `v' is potentially mistaken for `u' or `r'
        ///     (especially in handwriting) and that `2' is potentially mistaken for `z'
        ///     (especially in handwriting).
        ///
        /// Resulting in the following alphabet: `ybndrfg8ejkmcpqxot1uwisza345h769`
        ///
        /// ### Usage
        /// This scheme is used for `$ask`, `$testProbe` and other similar entities, where noticing "which one"
        /// is more important than "which one in order."
        ///
        /// - SeeAlso: [1] <a href="http://philzimmermann.com/docs/human-oriented-base-32-encoding.txt">z-base-32 encoding</a>
        case letters

        // other ideas:
        // https://github.com/google/open-location-code/blob/boss/docs/olc_definition.adoc#open-location-code
        // This was to avoid, as far as possible, Open Location Codes being generated that included recognisable words. The selected 20 character set is made up of "23456789CFGHJMPQRVWX".
    }

    internal let naming: _Naming

    /// Directly create target naming, WITHOUT performing any validation (!),
    /// used to create e.g. $ prefixed names for automatically spawned actors like "ask" or similar.
    internal init(unchecked: _Naming) {
        self.naming = unchecked
    }

    public init(stringLiteral value: String) {
        self = .unique(value)
    }

    func makeName(_ context: inout ActorNamingContext) -> String {
        switch self.naming {
        case .unique(let name):
            return name

        case .prefixed(let prefix, let repr):
            var resultingName = "\(prefix)-"
            switch repr {
            case .sequentialNumeric:
                let seqNr = context.nextSequenceNr()
                resultingName.append("\(seqNr)")

            case .letters:
                let seqNr = context.nextSequenceNr()
                var next: UInt32 = seqNr
                repeat {
                    let c = zBase32Alphabet[Int(next & zBase32AlphabetMaxIndex)]
                    resultingName.unicodeScalars.append(c)
                    next &>>= 5
                } while next > 0
            }

            return resultingName
        }
    }
}

/// Used as source of (usually sequential) numbers to power name generation of anonymous or worker actors.
internal struct ActorNamingContext {
    private var seqNr: UInt32

    init() {
        self.seqNr = 0
        // TODO: we could include node ids or similar if we wanted snowflakes...
    }

    mutating func nextSequenceNr() -> UInt32 {
        defer { self.seqNr += 1 }
        return self.seqNr
    }
}

let zBase32Alphabet: [UnicodeScalar] = [
    "y", "b", "n", "d", "r", "f", "g", "8",
    "e", "j", "k", "m", "c", "p", "q", "x",
    "o", "t", "1", "u", "w", "i", "s", "z",
    "a", "3", "4", "5", "h", "7", "6", "9",
]

private let zBase32AlphabetMaxIndex: UInt32 = .init(zBase32Alphabet.indices.last!)
