//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import SwiftSyntax

struct ActorableDecl {
    enum DeclType {
        case `protocol`
        case `class`
        case `struct`
    }

    var type: DeclType

    var name: String
    var nameFirstLowercased: String {
        var res: String = self.name.first!.lowercased()
        res.append(contentsOf: self.name.dropFirst())
        return res
    }

    var boxFuncName: String {
        // TODO: "$box\(self.name)" would be nicer, but it is reserved
        // (error: cannot declare entity named '$boxParking'; the '$' prefix is reserved for implicitly-synthesized declarations)
        "_box\(self.name)"
    }

    /// If this decl implements other actorable protocols, those should be included here
    /// Available only after post processing phase
    var actorableProtocols: [ActorableDecl] = []

    /// Cleared and Actorable protocols are moved to actorableProtocols in post processing
    var inheritedTypes: Set<String> = []

    /// Those functions need to be made into message protocol and generate stuff for them
    var funcs: [ActorFuncDecl] = []

    /// Only expected in case of a `protocol` for
    var boxingFunc: ActorFuncDecl? = nil
}

struct ActorFuncDecl {
    let message: ActorableMessageDecl
}

extension ActorFuncDecl: Equatable {
    public static func ==(lhs: ActorFuncDecl, rhs: ActorFuncDecl) -> Bool {
        lhs.message == rhs.message
    }
}


struct ActorableMessageDecl {
    let actorableName: String
    var actorableNameFirstLowercased: String { // TODO: more DRY
        var res: String = self.actorableName.first!.lowercased()
        res.append(contentsOf: self.actorableName.dropFirst())
        return res
    }

    let access: String?
    let name: String

    typealias Name = String
    typealias TypeName = String
    let params: [(Name?, Name, TypeName)]

    let throwing: Bool

    let returnType: ReturnType

    enum ReturnType {
        case void
        case type(String)
        case behavior(String)

        static func fromType(_ type: TypeSyntax?) -> ReturnType {
            guard let t = type else {
                return .void
            }

            if "\(t)".starts(with: "Behavior<") {
                return .behavior("\(t)")
            } else {
                return .type("\(t)")
            }
        }
    }
}

extension ActorableMessageDecl: Hashable {
    public func hash(into hasher: inout Hasher) {
//        hasher.combine(access) // FIXME? rules are a bit more complex in reality here, since enclosing scope etc
        hasher.combine(name)
        hasher.combine(throwing)
    }

    public static func ==(lhs: ActorableMessageDecl, rhs: ActorableMessageDecl) -> Bool {
//        if lhs.access != rhs.access { // FIXME? rules are a bit more complex in reality here, since enclosing scope etc
//            return false
//        }
        if lhs.name != rhs.name {
            return false
        }
        if lhs.throwing != rhs.throwing {
            return false
        }
        return true
    }
}
