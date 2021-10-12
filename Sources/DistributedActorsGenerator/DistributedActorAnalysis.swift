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

import Foundation
import Logging
import SwiftSyntax
import SwiftSyntaxParser

let BLUE = "\u{001B}[0;34m"
let RST = "\u{001B}[0;0m"

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Find Distributed Actors

final class GatherDistributedActors: SyntaxVisitor {
    var log: Logger

    let basePath: Directory
    var moduleName: String {
        basePath.name
    }
    let path: File

    var imports: [String] = []

    var actorDecls: [DistributedActorDecl] = []
    var wipDecl: DistributedActorDecl!

    // Stack of types a declaration is nested in. E.g. an actorable struct declared in an enum for namespacing.
    var nestingStack: [String] = []

    init(basePath: Directory, path: File, log: Logger) {
        self.basePath = basePath
        self.path = path
        self.log = log
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: imports

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        // we store the imports outside the actorable, since we don't know _yet_ if there will be an actorable or not
        self.imports.append("\(node)") // TODO: more special type, since cross module etc
        return .visitChildren
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: types

    func visitPostDecl(_ nodeName: String, completeWipActorable: Bool) {
        self.log.trace("\(#function): \(nodeName)")
        self.nestingStack = Array(self.nestingStack.reversed().drop(while: { $0 == nodeName })).reversed()

        if completeWipActorable, self.wipDecl != nil {
            self.actorDecls.append(self.wipDecl)
            self.wipDecl = nil
        }
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        let isDistributedProtocol = false
        guard isDistributedProtocol else { // FIXME: detect DistributedActor constrained protocol
            return .skipChildren
        }

        guard let modifiers = node.modifiers else {
            return .visitChildren
        }

        guard node.isDistributedActorConstrained else {
            return .visitChildren
        }

        // TODO: quite inefficient way to scan it, tho list is short
        if modifiers.contains(where: { $0.name.tokenKind == .publicKeyword }) {
            self.wipDecl.access = "public"
        } else if modifiers.contains(where: { $0.name.tokenKind == .internalKeyword }) {
            self.wipDecl.access = "internal"
        } else if modifiers.contains(where: { $0.name.tokenKind == .fileprivateKeyword }) {
            fatalError("""
            Fileprivate actors are not supported with GenActors, \
            since multiple files are involved due to the source generation. \
            Please change the following to be NOT fileprivate: \(node)
            """)
        } else if modifiers.contains(where: { $0.name.tokenKind == .privateKeyword }) {
            self.wipDecl.access = "private"
        }
        return .visitChildren
    }

    override func visitPost(_ node: ProtocolDeclSyntax) {
        self.visitPostDecl(node.identifier.text, completeWipActorable: node.isDistributedActorConstrained)
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.identifier.text
        guard node.isDistributedActor else {
            self.nestingStack.append("\(name)")
            self.log.trace("Nesting, visit children: \(name)")
            return .visitChildren
        }

        self.wipDecl = DistributedActorDecl(
            sourceFile: self.path,
            type: .distributedActor,
            name: name
        )
        if let genericInformation = collectGenericDecls(node.genericParameterClause, node.genericWhereClause) {
            self.wipDecl.genericParameterDecls = genericInformation.genericParameterDecls
            self.wipDecl.genericWhereClauses = genericInformation.genericWhereClauses
        }
        self.wipDecl.imports = self.imports
        self.wipDecl.declaredWithin = self.nestingStack
        self.log.info("Found 'distributed actor \(BLUE)\(self.wipDecl.fullName)\(RST)' in module \(self.moduleName), path: \(self.path.path(relativeTo: self.basePath))")

        return .visitChildren
    }

    override func visitPost(_ node: ClassDeclSyntax) {
        self.visitPostDecl(node.identifier.text, completeWipActorable: node.isDistributedActor)
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        return .skipChildren
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = "\(node.extendedType.description)".trim(character: " ")
        self.log.trace("Visiting extension \(name)")

        guard self.wipDecl != nil else {
            return .skipChildren
        }

        guard self.wipDecl?.name == name else {
            return .skipChildren
        }

        return .visitChildren
    }

    override func visitPost(_ node: ExtensionDeclSyntax) {
        let name = node.extendedType.description.trim(character: " ")
        let isDistributed = false // FIXME: can we detect here if this extension was on a distributed actor??
        self.visitPostDecl(name, completeWipActorable: isDistributed)
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        return .skipChildren
    }

    private func collectGenericDecls(
        _ genericParameterClause: GenericParameterClauseSyntax?,
        _ genericWhereClause: GenericWhereClauseSyntax?
    ) -> DistributedActorDecl.GenericInformation? {
        let genericDecls: [DistributedActorDecl.GenericDecl]
        if let genericParameterClause = genericParameterClause {
            genericDecls = genericParameterClause
                .genericParameterList.map { param in
                    .init("\(param)")
                }
        } else {
            genericDecls = []
        }

        let whereDecls: [DistributedActorDecl.WhereClauseDecl]
        if let genericWhereClause = genericWhereClause {
            whereDecls = genericWhereClause.requirementList.map { requirement in
                .init("\(requirement)")
            }
        } else {
            whereDecls = []
        }

        return .init(genericDecls, whereDecls)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: inherited types, incl. potentially actorable protocols

    override func visit(_ node: InheritedTypeSyntax) -> SyntaxVisitorContinueKind {
        guard self.wipDecl != nil else {
            return .skipChildren
        }
        self.wipDecl.inheritedTypes.insert("\(node.typeName)".trim(character: " "))
        return .visitChildren
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: functions

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = "\(node.identifier)"

        guard self.wipDecl != nil else {
            // likely a top-level function, we skip those always
            return .skipChildren
        }

        let modifierTokenKinds = node.modifiers?.map {
            $0.name.tokenKind
        } ?? []

        guard node.isDistributedFunc else  {
            return .skipChildren
        }

        // is it our special boxing function
        var isBoxingFunc = false

        self.log.debug("  distributed func \(name) ...")

        if self.wipDecl.type == .protocol,
            modifierTokenKinds.contains(.staticKeyword),
            name == "\(self.wipDecl.boxFuncName)" {
            isBoxingFunc = true
        } else {
            guard !modifierTokenKinds.contains(.privateKeyword),
                !modifierTokenKinds.contains(.fileprivateKeyword) else {
                preconditionFailure("""
                Function [\(name)] in [\(self.wipDecl.name)] can not be made into actor message, as it is `private` (or `fileprivate`).
                Only internal or public functions can be actor messages, because the generated sources need
                to be able to access the function in order to invoke it (which is impossible with `private`).
                """)
            }

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
            // carry access from outer scope
            access = self.wipDecl.access
        }

        // TODO: there is no TokenKind.mutatingKeyword in swift-syntax and it's expressed as .identifier("mutating"), could be a bug/omission
        let isMutating: Bool = node.modifiers?.tokens.contains(where: { $0.text == "mutating" }) ?? false

        let throwing: Bool
        switch node.signature.throwsOrRethrowsKeyword?.tokenKind {
        case .throwsKeyword, .rethrowsKeyword:
            throwing = true
        default:
            throwing = false
        }

        // TODO: we could require it to be async as well or something
        let funcDecl = DistributedFuncDecl(
            message: DistributedMessageDecl(
                actorName: self.wipDecl.name,
                access: access,
                name: name,
                params: node.signature.gatherParams(),
                isMutating: isMutating,
                throwing: throwing,
                returnType: .fromType(node.signature.output?.returnType)
            )
        )

        if isBoxingFunc {
            self.wipDecl.boxingFunc = funcDecl
        } else {
            self.wipDecl.funcs.append(funcDecl)
        }

        return .skipChildren
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Gather parameters of function declarations

final class GatherParameters: SyntaxVisitor {
    typealias Output = [(String?, String, String)]
    var params: Output = []

    override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
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
        let gather = GatherParameters()
        gather.walk(self)
        return gather.params
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Resolve types, e.g. inherited Actorable protocols

struct ResolveDistributedActors {
    static func resolve(_ decls: [DistributedActorDecl]) -> [DistributedActorDecl] {
        Self.validateActorableProtocols(decls)

        var protocolLookup: [String: DistributedActorDecl] = [:]
        for act in decls where act.type == .protocol {
            // TODO: in reality should be FQN, for cross module support
            protocolLookup[act.name] = act
        }
        let actorableTypes: Set<String> = Set(protocolLookup.keys)

        // yeah this is n^2 would not need this if we could use the type-/macro-system to do this for us?
        let resolvedActorables: [DistributedActorDecl] = decls.map { actorable in
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
            let protocolFuncs: [DistributedFuncDecl] = inheritedActorableProtocols.flatMap {
                $0.funcs
            }

            // The protocols are added such that we can generate their `case _protocol(Protocol)` cases and delegate to them
            resolved.actorableProtocols.formUnion(Set(inheritedActorableProtocols))

            // And we remove the "ad hoc" funcs which actually are funcs belonging to these protocols
            resolved.funcs = resolved.funcs.filter { f in
                let implementViaProtocol = protocolFuncs.contains(f)
                return !implementViaProtocol
            }

            return resolved
        }

        return resolvedActorables
    }

    /// **Faults** when an `protocol` inheriting `Actorable` does not provide a boxing
    static func validateActorableProtocols(_ actor: [DistributedActorDecl]) {
        let protocols = actor.filter {
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
                        Type defined in file: \(proto.sourceFile.path)
                        \u{001B}[0;0m
                    """)
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Check type is Distributed

extension ClassDeclSyntax {
    var isDistributedActor: Bool {
        let isActor = classOrActorKeyword.text == "actor"
        guard isActor else {
            return false
        }

        guard let mods = self.modifiers else {
            return false
        }

        for mod in mods where mod.name.text ==  "distributed" {
            return true
        }

        return false
    }
}

extension FunctionDeclSyntax {
    var isDistributedFunc: Bool {
        guard let mods = self.modifiers else {
            return false
        }

        for mod in mods {
            if mod.name.text ==  "distributed" {
                return true
            }
        }

        return false
    }
}

extension ProtocolDeclSyntax {
    var isDistributedActorConstrained: Bool {
        let visitor = IsDistributedActorProtocolVisitor()
        visitor.walk(self)
        return visitor.isDistributedActorProtocol
    }
}

// FIXME: a complete impl would need to "resolve the types" to know if it happens to be a dist protocol
final class IsDistributedActorProtocolVisitor: SyntaxVisitor {
    var isDistributedActorProtocol: Bool = false

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        .visitChildren
    }

    override func visit(_ node: InheritedTypeListSyntax) -> SyntaxVisitorContinueKind {
        for inheritedType in node {
            // TODO: get the name more properly
            let typeName = "\(inheritedType)"
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: .punctuationCharacters)
                .replacingOccurrences(of: "_Distributed.", with: "")

            if typeName == "DistributedActor" {
                self.isDistributedActorProtocol = true
                return .skipChildren
            }
        }

        return .visitChildren
    }


    override func visit(_: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

    override func visit(_: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

    override func visit(_: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

    override func visit(_: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

}