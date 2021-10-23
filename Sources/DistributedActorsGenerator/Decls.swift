//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019-2021 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import SwiftSyntax

struct DistributedActorDecl: Hashable {
    enum DeclType {
        case `protocol`
        case `distributedActor`
    }

    /// File where the actorable was defined
    var sourceFile: File

    var imports: [String] = []

    var access: String = ""
    var type: DeclType

    /// Contains type names within which this type is declared, e.g. `[Actorables.May.Be.Nested].MyActorable`.
    /// Empty for top level declarations.
    var declaredWithin: [String] = []

    var name: String
    var nameFirstLowercased: String {
        var res: String = self.name.first!.lowercased()
        res.append(contentsOf: self.name.dropFirst())
        return res
    }

    var fullName: String {
        if self.declaredWithin.isEmpty {
            return self.name
        } else {
            return "\(self.declaredWithin.joined(separator: ".")).\(self.name)"
        }
    }

    let generateCodableConformance: Bool = false

    var messageFullyQualifiedName: String {
        switch self.type {
        case .protocol:
            return "GeneratedActor.Messages.\(self.name)"
        default:
            return "\(self.fullName).Message"
        }
    }

    var boxFuncName: String {
        // TODO: "$box\(self.name)" would be nicer, but it is reserved
        // (error: cannot declare entity named '$boxParking'; the '$' prefix is reserved for implicitly-synthesized declarations)
        "_box\(self.name)"
    }

    /// If this decl implements other actorable protocols, those should be included here
    /// Available only after post processing phase
    var actorableProtocols: Set<DistributedActorDecl> = []

    /// Cleared and Actorable protocols are moved to actorableProtocols in post processing
    var inheritedTypes: Set<String> = []

    /// Those functions need to be made into message protocol and generate stuff for them
    var funcs: [DistributedFuncDecl] = []

    /// Only expected in case of a `protocol` for
    var boxingFunc: DistributedFuncDecl?

    /// Stores if the `receiveTerminated` implementation is `throws` or not
    /// The default is true since the protocols signature is such, however if users implement it without throws
    /// we must not invoke it with `try` prefixed.
    var receiveTerminatedIsThrowing = true

    /// Stores if the `receiveSignal` implementation is `throws` or not
    /// The default is true since the protocols signature is such, however if users implement it without throws
    /// we must not invoke it with `try` prefixed.
    var receiveSignalIsThrowing = true

    /// Captures any generic parameters of the actorable
    /// like `Hello` and `Who: Codable` from `Hello<World, Who>`
    ///
    /// See also: `whereClauses` for the where clauses
    var genericParameterDecls: [GenericDecl] = []
    struct GenericDecl {
        let name: String
        let parameterDecl: String

        init(_ declaration: String) {
            let decl = declaration
                .replacingOccurrences(of: ",", with: "")
                .trim(character: " ")
            self.parameterDecl = decl
            if declaration.contains(":") {
                self.name = String(declaration.split(separator: ":").first!)
                    .replacingOccurrences(of: ",", with: "")
                    .trim(character: " ")
            } else {
                self.name = declaration
                    .replacingOccurrences(of: ",", with: "")
                    .trim(character: " ")
            }
        }
    }

    var renderGenericTypes: String {
        self.genericParameterDecls.map { $0.parameterDecl } // TODO: must handle where clauses better
            .joined(separator: ", ")
    }

    var renderGenericNames: String {
        self.genericParameterDecls.map { $0.name }
            .joined(separator: ", ")
    }

    var isGeneric: Bool {
        !self.genericParameterDecls.isEmpty
    }

    var genericWhereClauses: [WhereClauseDecl] = []
    struct WhereClauseDecl {
        let name: String
        let clause: String

        init(_ clause: String) {
            self.clause = clause.replacingOccurrences(of: ",", with: "")
                .trim(character: " ")
            if clause.contains(":") {
                self.name = String(clause.split(separator: ":").first!)
                    .trim(character: " ")
            } else {
                fatalError("Not supported where clause: \(clause), please file a ticket.")
            }
        }
    }

    struct GenericInformation {
        let genericParameterDecls: [GenericDecl]
        let genericWhereClauses: [WhereClauseDecl]

        init(_ genericParameterDecls: [GenericDecl], _ genericWhereClauses: [WhereClauseDecl]) {
            self.genericParameterDecls = genericParameterDecls
            self.genericWhereClauses = genericWhereClauses
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(declaredWithin)
        hasher.combine(name)
    }

    static func ==(lhs: DistributedActorDecl, rhs: DistributedActorDecl) -> Bool {
        if lhs.declaredWithin != rhs.declaredWithin {
            return false
        }
        if lhs.name != rhs.name {
            return false
        }
        return true
    }
}

extension DistributedActorDecl: Comparable {
    public static func < (lhs: DistributedActorDecl, rhs: DistributedActorDecl) -> Bool {
        lhs.name < rhs.name
    }
}

struct DistributedFuncDecl {
    let message: DistributedMessageDecl
}

extension DistributedFuncDecl: Equatable {
    public static func == (lhs: DistributedFuncDecl, rhs: DistributedFuncDecl) -> Bool {
        lhs.message == rhs.message
    }
}

struct DistributedMessageDecl {
    let actorName: String

    let access: String?
    var outerType: String?
    let name: String

    typealias Name = String
    typealias TypeName = String
    let params: [(Name?, Name, TypeName)]

    var isMutating: Bool

    /// Similar to `params` but with potential `replyTo` parameter appended
    var effectiveParams: [(Name?, Name, TypeName)] {
        var res = self.params

        switch self.returnType {
        case .behavior:
            () // no "reply"

        case .void:
            res.append((nil, "_replyTo", "_ActorRef<Result<_Done, ErrorEnvelope>>"))

        case .type(let valueType) where !self.throwing:
            res.append((nil, "_replyTo", "_ActorRef<Result<\(valueType), ErrorEnvelope>>")) // TODO: make the same with the error envelope

        case .type(let valueType) /* self.throwing */:
            res.append((nil, "_replyTo", "_ActorRef<Result<\(valueType), ErrorEnvelope>>"))
        case .result(let valueType, _):
            res.append((nil, "_replyTo", "_ActorRef<Result<\(valueType), ErrorEnvelope>>"))
        case .nioEventLoopFuture(let valueType),
             .actorReply(let valueType),
             .askResponse(let valueType):
            // FIXME: carry the return type raw in the reply enum
            res.append((nil, "_replyTo", "_ActorRef<Result<\(valueType), ErrorEnvelope>>"))
        }

        return res
    }

    let throwing: Bool

    // For simplicity of moving the source gen to distributed actors, we just assume we'll always throw
    var effectivelyThrowing: Bool {
        true
    }

    let returnType: ReturnType

    enum ReturnType {
        case void
        case result(String, errorType: String)
        case nioEventLoopFuture(of: String)
        case actorReply(of: String)
        case askResponse(of: String)
        case behavior(String)
        case type(String)

        static func fromType(_ type: TypeSyntax?) -> ReturnType {
            guard let t = type else {
                return .void
            }

            let returnTypeString = "\(t)".trimmingCharacters(in: .whitespaces)
            if returnTypeString.starts(with: "Behavior<") || returnTypeString == "Myself.Behavior" {
                return .behavior(returnTypeString)
            } else if returnTypeString.starts(with: "Reply<") {
                let valueTypeString = String(
                    returnTypeString
                        .trim(character: " ")
                        .replacingOccurrences(of: "Reply<", with: "")
                        .dropLast(1)
                )
                return .actorReply(of: "\(valueTypeString)")
            } else if returnTypeString.starts(with: "AskResponse<") {
                let valueTypeString = String(
                    returnTypeString
                        .trim(character: " ")
                        .replacingOccurrences(of: "AskResponse<", with: "")
                        .dropLast(1)
                )
                return .askResponse(of: "\(valueTypeString)")
            } else if returnTypeString.starts(with: "Result<") {
                // TODO: instead analyse the type syntax?
                let trimmed = String(
                    returnTypeString
                        .trim(character: " ")
                        .replacingOccurrences(of: " ", with: "")
                )

                // FIXME: this will break with nexting...
                let valueType = String(trimmed[trimmed.index(after: trimmed.firstIndex(of: "<")!) ..< trimmed.firstIndex(of: ",")!])
                let errorType = String(trimmed[trimmed.index(after: trimmed.firstIndex(of: ",")!) ..< trimmed.lastIndex(of: ">")!])

                return .result(valueType, errorType: errorType)
            } else if returnTypeString.starts(with: "EventLoopFuture<") {
                let valueTypeString = String(
                    returnTypeString
                        .trim(character: " ")
                        .replacingOccurrences(of: "EventLoopFuture<", with: "")
                        .dropLast(1)
                )
                return .nioEventLoopFuture(of: valueTypeString)
            } else {
                return .type(returnTypeString.trim(character: " "))
            }
        }
    }
}

extension DistributedMessageDecl: Hashable {
    public func hash(into hasher: inout Hasher) {
//        hasher.combine(access) // FIXME? rules are a bit more complex in reality here, since enclosing scope etc
        hasher.combine(self.name) // FIXME: take into account enclosing scope
        hasher.combine(self.throwing)
    }

    public static func == (lhs: DistributedMessageDecl, rhs: DistributedMessageDecl) -> Bool {
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
