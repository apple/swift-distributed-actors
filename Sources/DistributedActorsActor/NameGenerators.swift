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

import NIOConcurrencyHelpers

// FIXME: KM I've grown convinced we should improve on the anonymous naming generation, see examples:
//   - https://twitter.com/ktosopl/status/1047147815019851776
//   - https://philzimmermann.com/docs/human-oriented-base-32-encoding.txt
//   - k8s uses "safe string"

// Implementation note:
// Note that we are not strictly following Base64; we start with lower case letters and replace the `/` with `~`
// TODO: To be honest it might be nicer to avoid the + and ~ as well; we'd differ from Akka but that does not matter really.
//
// Rationale:
// This is consistent with Akka, where the choice was made such as it is "natural" for small numbers of actors
// when learning the toolkit, and predictable for high numbers of them (where how it looks like stops to matter).
// TODO we could also avoid similar looking letters... I may be overthinking it? // was thinking about it since https://blog.softwaremill.com/new-pretty-id-generator-in-scala-commons-39b0fc6b6210
fileprivate let charsTable: [UnicodeScalar] = [
  "a", "b", "c", "d", "e", "f", "g", "h", "i", "j",
  "k", "l", "m", "n", "o", "p", "q", "r", "s", "t",
  "u", "v", "w", "x", "y", "z",
  "A", "B", "C", "D", "E", "F", "G", "H", "I", "J",
  "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T",
  "U", "V", "W", "X", "Y", "Z",
  // TODO contemplate skipping those 0...~ completely for nicer names
  "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" , "+", "~"
]
fileprivate let charsTableMaxIndex = charsTable.indices.last!

// TODO is this proper style?
// TODO is such inheritance expensive?
public class AnonymousNamesGenerator {
  private let prefix: String

  public init(prefix: String) {
    self.prefix = prefix
  }

  /// Implement by providing appropriate next actor number generation
  /// to seed the name generation. Atomic and non-atomic implementations
  /// exist, for use for top-level or protected within an actor execution/reduction naming.
  ///
  /// Note that no guarantees about names of anonymous actors are made;
  /// and developers should not expect those names never to change.
  fileprivate func nextId() -> Int {
    return undefined()
  }

  public func nextName() -> String {
    let n = nextId()
    return mkName(prefix: prefix, n: n)
  }

  /// Based on Base64, though simplified
  internal func mkName(prefix: String, n: Int) -> String { // TODO work on Int64?
    var outputString: String = prefix

    var next = n
    repeat {
      let c = charsTable[Int(next & charsTableMaxIndex)]
      outputString.unicodeScalars.append(c)
      next &>>= 6
    } while next > 0

    return outputString
  }

}

/// Generate sequential names for actors
// TODO can be abstracted ofc, not doing so for now; keeping internal
public final class AtomicAnonymousNamesGenerator: AnonymousNamesGenerator {
  private var ids = Atomic<Int64>(value: 0)

  override public init(prefix: String) {
    super.init(prefix: prefix)
  }

  override func nextId() -> Int {
    return Int(ids.add(1))
  }
}

// TODO pick better name for non synchronized ones
public final   class NonSynchronizedAnonymousNamesGenerator: AnonymousNamesGenerator {
  private var ids: Int // FIXME should be UInt64, since there's no reason to limit child actors only since the name won't fit them ;-)

  override init(prefix: String) {
    self.ids = 0
    super.init(prefix: prefix)
  }

  override func nextId() -> Int {
    defer { ids += 1 }
    return ids
  }
}