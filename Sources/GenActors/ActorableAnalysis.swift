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
    let path: File
    let settings: GenerateActors.Settings

    var imports: [String] = []

    var actorables: [ActorableTypeDecl] = []
    var wipActorable: ActorableTypeDecl!

    // Stack of types a declaration is nested in. E.g. an actorable struct declared in an enum for namespacing.
    var nestingStack: [String] = []

    init(_ path: File, _ settings: GenerateActors.Settings) {
        self.path = path
        self.settings = settings
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: imports

    mutating func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        // we store the imports outside the actorable, since we don't know _yet_ if there will be an actorable or not
        self.imports.append("\(node)") // TODO: more special type, since cross module etc
        return .visitChildren
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: types

    mutating func visit(_ type: ActorableTypeDecl.DeclType, node: DeclSyntax, name: String) -> SyntaxVisitorContinueKind {
        guard node.isActorable() else {
            self.nestingStack.append("\(name)")
            return .visitChildren
        }

        // This is another marker protocol and we do not need to generate anything for it
        guard name != "XPCActorableProtocol" else {
            return .skipChildren
        }

        let BLUE = "\u{001B}[0;34m"
        let RST = "\u{001B}[0;0m"
        self.wipActorable = ActorableTypeDecl(
            sourceFile: self.path,
            type: type,
            name: name,
            generateCodableConformance: true
        )
        self.wipActorable.imports = self.imports
        self.wipActorable.declaredWithin = self.nestingStack
        self.info("Actorable \(type) detected: [\(BLUE)\(self.wipActorable.fullName)\(RST)] at \(self.path.path), analyzing...")

        return .visitChildren
    }

    mutating func visitPostDecl(_ nodeName: String) {
        self.nestingStack = Array(self.nestingStack.reversed().drop(while: { $0 == nodeName })).reversed()

        guard self.wipActorable != nil else {
            return
        }
        self.actorables.append(self.wipActorable)
        self.wipActorable = nil
    }

    mutating func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        switch self.visit(.protocol, node: node, name: node.identifier.text) {
        case .skipChildren:
            return .skipChildren
        case .visitChildren:
            guard let modifiers = node.modifiers else {
                return .visitChildren
            }

            guard node.isActorable() else {
                return .visitChildren
            }

            // TODO: quite inefficient way to scan it, tho list is short
            if modifiers.contains(where: { $0.name.tokenKind == .publicKeyword }) {
                self.wipActorable.access = "public"
            } else if modifiers.contains(where: { $0.name.tokenKind == .internalKeyword }) {
                self.wipActorable.access = "internal"
            } else if modifiers.contains(where: { $0.name.tokenKind == .fileprivateKeyword }) {
                fatalError("""
                Fileprivate actors are not supported with GenActors, \
                since multiple files are involved due to the source generation. \
                Please change the following to be NOT fileprivate: \(node)
                """)
            } else if modifiers.contains(where: { $0.name.tokenKind == .privateKeyword }) {
                self.wipActorable.access = "private"
            }
            return .visitChildren
        }
    }

    mutating func visitPost(_ node: ProtocolDeclSyntax) {
        self.visitPostDecl(node.identifier.text)
    }

    mutating func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        self.visit(.class, node: node, name: node.identifier.text)
    }

    mutating func visitPost(_ node: ClassDeclSyntax) {
        self.visitPostDecl(node.identifier.text)
    }

    mutating func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        self.visit(.struct, node: node, name: node.identifier.text)
    }

    mutating func visitPost(_ node: StructDeclSyntax) {
        self.visitPostDecl(node.identifier.text)
    }

    mutating func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = "\(node.extendedType.description)".trim(character: " ")
        return self.visit(.extension, node: node, name: name)
    }

    mutating func visitPost(_ node: ExtensionDeclSyntax) {
        self.visitPostDecl(node.extendedType.description.trim(character: " "))
    }

    mutating func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = "\(node.identifier.text)"

        guard node.isActorable() else {
            self.nestingStack.append("\(name)")
            return .visitChildren
        }

        // TODO: It could be interesting to express actors as enums, that would be their "states"
        fatalError("Enums cannot (currently) be Actorable, define [\(name)] (in \(self.path)) as a struct instead. Offending node: \(node)")
    }

    mutating func visitPost(_ node: EnumDeclSyntax) {
        self.visitPostDecl(node.identifier.text)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: inherited types, incl. potentially actorable protocols

    mutating func visit(_ node: InheritedTypeSyntax) -> SyntaxVisitorContinueKind {
        guard self.wipActorable != nil else {
            return .skipChildren
        }
        self.wipActorable.inheritedTypes.insert("\(node.typeName)".trim(character: " "))
        return .visitChildren
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: GenActors configuration: static lets
    mutating func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        // we only care about static ones that we use to configure the source gen
        guard node.modifiers?.contains(where: { $0.name.tokenKind == .staticKeyword }) ?? false else {
            return .skipChildren
        }

        guard let name = node.bindings.firstToken?.text else {
            // should never happen, what is a var/let binding without any name?
            return .skipChildren
        }

        guard self.wipActorable != nil else {
            return .skipChildren
        }

        switch name {
        case "generateCodableConformance":
            // short cut, rather than checking exact return value
            self.wipActorable.generateCodableConformance = "\(node)".contains("true")
        default:
            // not a property we care about
            return .skipChildren
        }

        return .skipChildren
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: functions

    mutating func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard self.wipActorable != nil else {
            // likely a top-level function, we skip those always
            return .skipChildren
        }

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
            if Self.shouldSkipGenFor(func: node) {
                return .skipChildren
            }

            // skip all Actorable lifecycle methods
            if Self.actorableLifecycleMethods.contains(where: { name in node.identifier.text == name }) {
                // if it is one of those functions, we at least need to store if the implementation is throwing or not,
                // as it affects if the generated code needs to prefix the call with try or not.
                // if it was not defined, the protocols signature wins and thus we assume it is throwing
                switch node.identifier.text {
                case "receiveTerminated" where node.signature.throwsOrRethrowsKeyword == nil:
                    self.wipActorable.receiveTerminatedIsThrowing = false
                case "receiveSignal" where node.signature.throwsOrRethrowsKeyword == nil:
                    self.wipActorable.receiveSignalIsThrowing = false
                default:
                    () // nothing to do
                }
                return .skipChildren
            }

            guard !modifierTokenKinds.contains(.privateKeyword),
                !modifierTokenKinds.contains(.staticKeyword) else {
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
            access = self.wipActorable.access
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
        let funcDecl = ActorFuncDecl(
            message: ActorableMessageDecl(
                actorableName: self.wipActorable.name,
                access: access,
                name: name,
                params: node.signature.gatherParams(),
                isMutating: isMutating,
                throwing: throwing,
                returnType: .fromType(node.signature.output?.returnType)
            )
        )

        if isBoxingFunc {
            self.wipActorable.boxingFunc = funcDecl
        } else {
            self.wipActorable.funcs.append(funcDecl)
        }

        return .skipChildren
    }
}

extension GatherActorables {
    /// We skip generating messages for methods prefixed like this, regardless if they are public etc.
    /// We DO allow `_` methods and treat them as "this is only for the actor to message _itself_
    static let skipMethodsStartingWith = ["__", "$"]
    static let actorableLifecycleMethods = [
        "preStart",
        "postStop",
        "receiveTerminated",
        "receiveSignal",
    ] // TODO: more specific with param type matching?

    static func shouldSkipGenFor(func node: FunctionDeclSyntax) -> Bool {
        // Skip all "internal" methods
        // we always skip `_` prefixed methods; this is a way to allow public/internal methods but still not expose them as the actor interface.
        Self.skipMethodsStartingWith.contains(where: { prefix in node.identifier.text.starts(with: prefix) })
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
    static func resolve(_ actorables: [ActorableTypeDecl]) -> [ActorableTypeDecl] {
        Self.validateActorableProtocols(actorables)

        var protocolLookup: [String: ActorableTypeDecl] = [:]
        for act in actorables where act.type == .protocol {
            // TODO: in reality should be FQN, for cross module support
            protocolLookup[act.name] = act
        }
        let actorableTypes: Set<String> = Set(protocolLookup.keys)

        // yeah this is n^2 would not need this if we could use the type-/macro-system to do this for us?
        let resolvedActorables: [ActorableTypeDecl] = actorables.map { actorable in
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
            let protocolFuncs: [ActorFuncDecl] = inheritedActorableProtocols.flatMap {
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
    static func validateActorableProtocols(_ actorables: [ActorableTypeDecl]) {
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
                        Type defined in file: \(proto.sourceFile.path)
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
    var depth = 0

    mutating func visit(_ node: InheritedTypeListSyntax) -> SyntaxVisitorContinueKind {
        if "\(node)".contains("Actorable") { // TODO: make less hacky
            self.actorable = true
            return .skipChildren
        }
        return .visitChildren
    }

    private mutating func visitOnlyTopLevel() -> SyntaxVisitorContinueKind {
        self.depth += 1
        return self.depth == 1 ? .visitChildren : .skipChildren
    }

    mutating func visit(_: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        self.visitOnlyTopLevel()
    }

    mutating func visit(_: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        self.visitOnlyTopLevel()
    }

    mutating func visit(_: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        self.visitOnlyTopLevel()
    }

    mutating func visit(_: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        self.visitOnlyTopLevel()
    }

    var shouldContinue: SyntaxVisitorContinueKind {
        self.actorable ? .visitChildren : .skipChildren
    }
}

extension SyntaxVisitor {
    func info(_ message: String) {
        print("[gen-actors][INFO] \(message)")
    }

    func debug(_ message: String) {
        print("[gen-actors][DEBUG] \(message)")
    }
}
