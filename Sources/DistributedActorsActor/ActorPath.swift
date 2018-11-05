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
/// Names MUST:
/// - not start with `$` (those names are reserved for Swift Distributed Actors internal system actors)
/// - contain only ASCII characters and select special characters (listed in [[ValidPathSymbols.extraSymbols]]
///
/// - Example: `/user/master/worker`
public struct ActorPath: Equatable, Hashable {

  private var segments: [ActorPathSegment]

  public init(_ segments: [ActorPathSegment]) throws {
    guard !segments.isEmpty else { throw ActorPathError.illegalEmptyActorPath }
    self.segments = segments
  }
  public init(root: String) throws {
    try self.init([ActorPathSegment(root)])
  }
  public init(root: ActorPathSegment) throws {
    try self.init([root])
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
    return segments.last! // it is guaranteed
  }
}
  // TODO
  extension ActorPath: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
      return self.segments.map({$0.value}).joined(separator: "/")
    }
    public var debugDescription: String {
      return "ActorPath(\(description))"
    }
  }

/// Represents a single segment (actor name) of an ActorPath.
public struct ActorPathSegment: Equatable, Hashable {
  let value: String

  public init(_ name: String) throws {
    // TODO may want to separate validation out, in case we create it from "known safe" strings
    try ActorPathSegment.validatePathSegment(name)
    self.value = name
  }
  
  static func validatePathSegment(_ name: String) throws {
    if name.isEmpty { throw ActorPathError.illegalActorPathElement(name: name, illegal: "", index: 0) }

    // TODO benchmark
    func isValidASCII(_ char: Character, _ scalar: Unicode.Scalar) -> Bool {
      let s = scalar.value

      return (s >= ValidActorPathSymbols.a && s <= ValidActorPathSymbols.z) ||
             (s >= ValidActorPathSymbols.A && s <= ValidActorPathSymbols.Z) ||
             (s >= ValidActorPathSymbols.zero && s <= ValidActorPathSymbols.nine) ||
             (ValidActorPathSymbols.extraSymbols.firstIndex(of: char) != nil)
    }
    
    // TODO accept hex and url encoded things as well
    // http://www.ietf.org/rfc/rfc2396.txt
    var pos = 0
    for c in name {
      // TODO optimize, use ASCII code-points < with > checks to limit to a-zA-Z
      let f = c.unicodeScalars.first

      if (f?.isASCII ?? false) && isValidASCII(c, f!) {
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
  static let a = "a".unicodeScalars.first!.value
  static let z = "z".unicodeScalars.first!.value
  static let A = "A".unicodeScalars.first!.value
  static let Z = "Z".unicodeScalars.first!.value
  static let zero = "0".unicodeScalars.first!.value
  static let nine = "9".unicodeScalars.first!.value

  static let extraSymbols = "-_.*$+:@&=,!~';"
}

// MARK: --

public enum ActorPathError: Error {
  case illegalEmptyActorPath
  case illegalActorPathElement(name: String, illegal: String, index: Int)
  case rootPathSegmentRequiredToStartWithSlash(segment: ActorPathSegment)
}
