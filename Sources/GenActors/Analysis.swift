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

import DistributedActors
import Files
import Foundation
import SwiftSyntax

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Find Actorables

struct GatherActorables: SyntaxVisitor {

    var actorables: [ActorableDecl] = []
    var wipActorable: ActorableDecl = .init(type: .protocol, name: "<NOTHING>")

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: types

    mutating func visit(_ type: ActorableDecl.DeclType, node: DeclSyntax, name: String) -> SyntaxVisitorContinueKind {
        guard node.isActorable() else {
            return .skipChildren
        }

        self.debug("Actorable \(type) detected: [\(name)], analyzing...")
        self.wipActorable = ActorableDecl(type: type, name: name)

        return .visitChildren
    }

    mutating func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        self.visit(.protocol, node: node, name: node.identifier.text)
    }

    mutating func visitPost(_ node: ProtocolDeclSyntax) {
        self.actorables.append(self.wipActorable)
        self.wipActorable = .init(type: .protocol, name: "<NOTHING>")
    }

    mutating func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        self.visit(.class, node: node, name: node.identifier.text)
    }

    mutating func visitPost(_ node: ClassDeclSyntax) {
        self.actorables.append(self.wipActorable)
        self.wipActorable = .init(type: .protocol, name: "<NOTHING>")
    }

    mutating func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        self.visit(.struct, node: node, name: node.identifier.text)
    }

    mutating func visitPost(_ node: StructDeclSyntax) {
        self.actorables.append(self.wipActorable)
        self.wipActorable = .init(type: .protocol, name: "<NOTHING>")
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: inherited types, incl. potentially actorable protocols

    mutating func visit(_ node: InheritedTypeSyntax) -> SyntaxVisitorContinueKind {
        self.wipActorable.inheritedTypes.insert(node.typeName.description)
        return .visitChildren
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: functions

    mutating func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = "\(node.identifier)"

        let modifierTokenKinds = node.modifiers?.map {
            $0.name.tokenKind
        } ?? []

        // is it our special boxing function
        var isBoxingFunc = false

        if self.wipActorable.type == .protocol,
           modifierTokenKinds.contains(.staticKeyword),
           name == "\(self.wipActorable.boxFuncName)" {
            isBoxingFunc = true
        } else {
            guard !name.starts(with: "_") && !name.starts(with: "$") else {
                // we always skip `_` prefixed methods; this is a way to allow public/internal methods but still not expose them as the actor interface.
                return .skipChildren
            }

            // TODO: carry access control
            guard !modifierTokenKinds.contains(.privateKeyword) else {
                return .skipChildren
            }

            // only non-static methods can be actor tells
            guard !modifierTokenKinds.contains(.staticKeyword) else {
                return .skipChildren
            }
        }

        let access: String
        if modifierTokenKinds.contains(.publicKeyword) {
            access = "public"
        } else if modifierTokenKinds.contains(.internalKeyword) {
            access = "internal"
        } else {
            access = ""
        }

        let throwing: Bool
        switch node.signature.throwsOrRethrowsKeyword?.tokenKind {
        case .throwsKeyword:
            throwing = true
        default:
            throwing = false
        }

        // TODO: we could require it to be async as well or something
        let funcDecl = ActorFuncDecl(
            message: ActorableMessageDecl(
                actorableName: self.wipActorable.name,
                access: access,
                name: name,
                params: node.signature.gatherParams(),
                throwing: throwing,
                returnType: .fromType(node.signature.output?.returnType)
            ))


        if isBoxingFunc {
            pprint("self.wipActorable.boxingFunc = \(funcDecl)")
            self.wipActorable.boxingFunc = funcDecl
        } else {
            self.wipActorable.funcs.append(funcDecl)
        }

        return .skipChildren
    }

}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Gather parameters of function declarations

struct GatherParameters: SyntaxVisitor {
    typealias Output = [(String?, String, String)]
    var params: Output = []

    mutating func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
        let firstName = node.firstName?.text
        guard let secondName = node.secondName?.text ?? firstName else {
            fatalError("No `secondName` or `firstName` available at: \(node)")
        }
        guard let type = node.type?.description else {
            fatalError("No `type` available at function parameter: \(node)")
        }

        self.params.append((firstName, secondName, type))
        return .skipChildren
    }
}

extension FunctionSignatureSyntax {
    func gatherParams() -> GatherParameters.Output {
        var gather = GatherParameters()
        self.walk(&gather)
        return gather.params
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Resolve types, e.g. inherited Actorable protocols

struct ResolveActorables {
    static func resolve(_ actorables: [ActorableDecl]) -> [ActorableDecl] {
        Self.validateActorableProtocols(actorables)

        var protocolLookup: [String: ActorableDecl] = [:]
        protocolLookup.reserveCapacity(actorables.count)
        for act in actorables where act.type == .protocol {
            // TODO: in reality should be FQN, for cross module support
            protocolLookup[act.name] = act
        }
        let actorableTypes: Set<String> = Set(protocolLookup.keys)

        // yeah this is n^2 would not need this if we could use the type-/macro-system to do this for us?
        let resolvedActorables: [ActorableDecl] = actorables.map { actorable in
            let inheritedByNameMatches = actorable.inheritedTypes.intersection(actorableTypes)
            guard !inheritedByNameMatches.isEmpty else {
                return actorable
            }

            // TODO: This could be expressed as some "actorable.implements(protocol)"

            // some of the super types are indeed `ActorableDecl`!
            var resolved = actorable
            let inheritedActorableProtocols = inheritedByNameMatches.compactMap {
                protocolLookup[$0]
            }.filter {
                $0.type == .protocol
            }

            /// Functions which shall be implemented by packaging into the protocols "container" rather than ad hoc by the actorable class/struct
            let protocolFuncs = inheritedActorableProtocols.flatMap {
                $0.funcs
            }

            // The protocols are added such that we can generate their `case _protocol(Protocol)` cases and delegate to them
            resolved.actorableProtocols.append(contentsOf: inheritedActorableProtocols)

            // And we remove the "ad hoc" funcs which actually are funcs belonging to these protocols
            resolved.funcs = resolved.funcs.filter { f in
                let implementViaProtocol = protocolFuncs.contains(f)
                if implementViaProtocol {
                    pprint("Implement via actorable protocol: \(f)")
                }
                return !implementViaProtocol
            }

            return resolved
        }

        return resolvedActorables
    }

    /// **Faults** when an `protocol` inheriting `Actorable` does not provide a boxing
    static func validateActorableProtocols(_ actorables: [ActorableDecl]) {
        let protocols = actorables.filter {
            $0.type == .protocol
        }

        for proto in protocols {
            guard proto.boxingFunc != nil else {
                fatalError(
                    """
                        \u{001B}[0;31m Actorable protocol [\(proto.name)] MUST define a boxing function, in order to be adopted by other Actorables!
                        Please define a static boxing function in [\(proto.name)]:

                            static func \(proto.boxFuncName)(_ message: GeneratedActor.Messages.\(proto.name)) -> Self.Message

                        Implementations for this function will be generated automatically for every concrete conformance of an Actorable and this protocol.
                        \u{001B}[0;0m
                    """)
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Check type is Actorable

extension DeclSyntax {
    func isActorable() -> Bool {
        var isActorable = IsActorableVisitor()
        self.walk(&isActorable)
        return isActorable.actorable
    }
}

struct IsActorableVisitor: SyntaxVisitor {
    var actorable: Bool = false

    mutating func visit(_ node: InheritedTypeSyntax) -> SyntaxVisitorContinueKind {
        if "\(node)".contains("Actorable") { // TODO: make less hacky
            self.actorable = true
            return .skipChildren
        }
        return .visitChildren
    }

    var shouldContinue: SyntaxVisitorContinueKind {
        return self.actorable ? .visitChildren : .skipChildren
    }
}

extension SyntaxVisitor {
    func debug(_ message: String, file: StaticString = #file, line: UInt = #line) {
        pprint("[gen-actors] \(message)", file: file, line: line)
    }
}
