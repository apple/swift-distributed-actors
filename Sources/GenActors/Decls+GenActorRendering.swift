//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019-2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActors
import NIO
import Stencil
import SwiftSyntax

protocol Renderable {
    func render(_ settings: GenerateActorsCommand) throws -> String
}

enum Rendering {
    static let generatedFileHeader: String =
        """
        // ==== ------------------------------------------------------------------ ====
        // === DO NOT EDIT: Generated by GenActors                     
        // ==== ------------------------------------------------------------------ ====

        """
}

extension Rendering {
    struct ActorShellTemplate: Renderable {
        let actorable: ActorableTypeDecl
        let stubGenBehavior: Bool

        static let messageForNonProtocolTemplate = Template(
            templateString:
            """
            // ==== ----------------------------------------------------------------------------------------------------------------
            // MARK: DO NOT EDIT: Generated {{baseName}} messages 

            /// DO NOT EDIT: Generated {{baseName}} messages
            extension {{baseName}} {

                {{messageAccess}} enum Message: ActorMessage { {% for case in funcCases %}
                    {{case}} {% endfor %}
                }
                {%for tell in boxFuncs %}
                {{ tell }} 
                {% endfor %}
            }
            """
        )

        static let messageForProtocolTemplate = Template(
            templateString:
            """
            // ==== ----------------------------------------------------------------------------------------------------------------
            // MARK: DO NOT EDIT: Generated {{baseName}} messages 

            extension GeneratedActor.Messages {
                {{messageAccess}} enum {{baseName}}: ActorMessage { {% for case in funcCases %}
                    {{case}} {% endfor %} 
                }
            }

            """
        )

        static let boxingForProtocolTemplate = Template(
            templateString:
            """
            // ==== ----------------------------------------------------------------------------------------------------------------
            // MARK: DO NOT EDIT: Boxing {{baseName}} for any inheriting actorable `A` 

            extension Actor where A: {{actorableProtocol}} {
            {%for tell in funcBoxTells %}
            {{ tell }} 
            {% endfor %}
            }

            """
        )

        static let behaviorTemplate = Template(
            templateString:
            """
            // ==== ----------------------------------------------------------------------------------------------------------------
            // MARK: DO NOT EDIT: Generated {{baseName}} behavior

            extension {{baseName}} {

                public static func makeBehavior(instance: {{baseName}}) -> Behavior<Message> {
                    return .setup { _context in
                        let context = Actor<{{baseName}}>.Context(underlying: _context)
                        {{varLetInstance}} instance = instance

                        instance.preStart(context: context)

                        return Behavior<Message>.receiveMessage { message in
                            switch message { 
                            {% for case in funcSwitchCases %}
                            {{case}} {% endfor %}
                            {% for case in funcBoxSwitchCases %}
                            {{case}} {% endfor %}
                            }
                            return .same
                        }.receiveSignal { _context, signal in 
                            let context = Actor<{{baseName}}>.Context(underlying: _context)

                            switch signal {
                            case is Signals.PostStop: 
                                instance.postStop(context: context)
                                return .same
                            case let terminated as Signals.Terminated:
                                switch {{tryIfReceiveTerminatedIsThrowing}}instance.receiveTerminated(context: context, terminated: terminated) {
                                case .unhandled: 
                                    return .unhandled
                                case .stop: 
                                    return .stop
                                case .ignore: 
                                    return .same
                                }
                            default:
                                {{tryIfReceiveSignalIsThrowing}}instance.receiveSignal(context: context, signal: signal)
                                return .same
                            }
                        }
                    }
                }
            }

            """
        )

        static let behaviorStubTemplate = Template(
            templateString:
            """
            // ==== ----------------------------------------------------------------------------------------------------------------
            // MARK: DO NOT EDIT: Generated {{baseName}} behavior

            extension {{baseName}} {

                public static func makeBehavior(instance: {{baseName}}) -> Behavior<Message> {
                    fatalError("Behavior STUB for XPCActorableProtocol. Not intended to be instantiated.")
                }
            }

            """
        )

        static let actorTellTemplate = Template(
            templateString:
            """
            // ==== ----------------------------------------------------------------------------------------------------------------
            // MARK: Extend Actor for {{baseName}}

            extension Actor{{extensionWhereClause}} {
            {% for tell in funcTells %}
            {{ tell }} 
            {% endfor %}
            }

            """
        )

        func render(_ settings: GenerateActorsCommand) throws -> String {
            let actorableProtocols = self.actorable.actorableProtocols.sorted()

            let context: [String: Any] = [
                "baseName": self.actorable.fullName,
                "actorableProtocol": self.actorable.type == .protocol ? self.actorable.name : "",

                "varLetInstance": self.actorable.renderStoreInstanceAs,

                "messageAccess": "public", // TODO: allow non public actor messages

                "funcCases": self.actorable.renderCaseDecls,

                "extensionWhereClause": self.actorable.isGeneric ?
                    "" :
                    " where A.Message == \(self.actorable.fullName).Message",

                "funcSwitchCases": try self.actorable.funcs.map { funcDecl in
                    try CodePrinter.content { printer in
                        try funcDecl.renderFuncSwitchCase(partOfProtocol: nil, printer: &printer)
                    }
                },
                "funcBoxSwitchCases": try actorableProtocols.flatMap { box in
                    try box.funcs.map { funcDecl in
                        try CodePrinter.content { printer in
                            try funcDecl.renderFuncSwitchCase(partOfProtocol: box, printer: &printer)
                        }
                    }
                },

                "boxFuncs": try actorableProtocols.map { inheritedProtocol in
                    try inheritedProtocol.renderBoxingFunc(in: self.actorable)
                },

                "funcTells": try self.actorable.funcs.map { funcDecl in
                    try CodePrinter.content { printer in
                        printer.indent()
                        try funcDecl.renderFuncTell(self.actorable, printer: &printer)
                    }
                },
                "funcBoxTells": self.actorable.type == .protocol ? try self.actorable.funcs.map { actorableFunc in
                    try CodePrinter.content { printer in
                        printer.indent()
                        try actorableFunc.renderBoxFuncTell(self.actorable, printer: &printer)
                    }
                } : [],

                "tryIfReceiveTerminatedIsThrowing": self.actorable.receiveTerminatedIsThrowing ? "try " : " ",
                "tryIfReceiveSignalIsThrowing": self.actorable.receiveSignalIsThrowing ? "try " : " ",
            ]

            var rendered: String = "\n"
            switch self.actorable.type {
            case .protocol:
                rendered.append(try Self.messageForProtocolTemplate.render(context))
            default:
                rendered.append(try Self.messageForNonProtocolTemplate.render(context))
                rendered.append("\n")
            }

            switch self.actorable.type {
            case .struct, .class, .enum, .extension:
                if self.stubGenBehavior {
                    rendered.append(try Self.behaviorStubTemplate.render(context))
                } else {
                    rendered.append(try Self.behaviorTemplate.render(context))
                    rendered.append(try Self.actorTellTemplate.render(context))
                }
            case .protocol:
                rendered.append(try Self.boxingForProtocolTemplate.render(context))
            }

            if settings.printGenerated {
                print(rendered)
            }

            return rendered
        }
    }

    struct XPCProtocolStubTemplate: Renderable {
        let actorable: ActorableTypeDecl

        static let stubStructTemplate = Template(
            templateString:
            """
            // ==== ----------------------------------------------------------------------------------------------------------------
            // MARK: DO NOT EDIT: Generated {{baseName}}Stub for XPCService consumers of the {{baseName}} XPCActorableProtocol

            /// DO NOT EDIT: Generated {{baseName}} messages
            ///
            /// This type serves only as "stub" in order for callers of an XPCService implementing {{baseName}} to be 
            /// able to express `Actor<{{baseName}}>`.
            public struct {{baseName}}Stub: Actorable, {{baseName}} {
                private init() {
                    // Just a Stub, no-one should ever be instantiating it.
                }
            {% for tell in funcTells %}
            {{ tell }}{% endfor %}
            }
            """
        )

        func render(_ settings: GenerateActorsCommand) throws -> String {
            let context: [String: Any] = [
                "baseName": self.actorable.fullName,
                "funcTells": try self.actorable.funcs.map { funcDecl in
                    try CodePrinter.content { printer in
                        printer.indent()
                        try funcDecl.renderFuncStub(printer: &printer)
                    }
                },
            ]

            var rendered: String = "\n"
            switch self.actorable.type {
            case .protocol:
                rendered.append(try Self.stubStructTemplate.render(context))
                rendered.append("\n")
            default:
                break
            }

            if settings.printGenerated {
                print(rendered)
            }

            return rendered
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Rendering extensions

extension ActorableTypeDecl {
    /// Render if we should store this as `let` or `var`, as storing in the right way is important to avoid compiler warnings,
    /// i.e. we could store always in a var, but it'd cause warnings.
    var renderStoreInstanceAs: String {
        if self.type == DeclType.class {
            return "let"
        } else {
            // structs may need to be stored as var or let, depending if they have mutating members
            //
            // we need to also check all the adopted protocols if they cause any mutating calls;
            // TODO: this would need to go recursively all the way in reality; since protocols conform to other protocols etc.
            if self.funcs.contains(where: { $0.message.isMutating }) ||
                self.actorableProtocols.contains(where: { $0.funcs.contains(where: { $0.message.isMutating }) }) {
                return "var"
            } else {
                return "let"
            }
        }
    }

    var renderCaseLet: String {
        "case .\(self.nameFirstLowercased)(let boxed):"
    }

    var renderBoxCaseLet: String {
        "case .\(self.boxFuncName)(let boxed):"
    }

    var renderCaseDecls: [String] {
        let renderedDirectFuncs = self.funcs.map {
            $0.renderCaseDecl()
        }

        let renderedActorableProtocolBoxes = self.actorableProtocols.sorted().map { decl in
            "case \(decl.nameFirstLowercased)(/*TODO: MODULE.*/GeneratedActor.Messages.\(decl.name))"
        }

        var res: [String] = renderedDirectFuncs
        res.append(contentsOf: renderedActorableProtocolBoxes)

        return res
    }

    func renderBoxingFunc(in owner: ActorableTypeDecl) throws -> String {
        let context: [String: Any] = [
            "baseName": "\(owner.fullName)",
            "access": "public",
            "boxCaseName": "\(self.nameFirstLowercased)",
            "boxFuncName": "\(self.boxFuncName)",
            "messageToBoxType": "GeneratedActor.Messages.\(self.name)",
        ]

        return try Template(
            stringLiteral:
            """
            /// Performs boxing of {{messageToBoxType}} messages such that they can be received by Actor<{{baseName}}>
                {{access}} static func {{boxFuncName}}(_ message: {{messageToBoxType}}) -> {{baseName}}.Message {
                    .{{boxCaseName}}(message)
                }
            """
        ).render(context)
    }
}

extension ActorableMessageDecl {
    var returnIfBecome: String {
        switch self.returnType {
        case .behavior:
            return "return /*become*/ "
        default:
            return ""
        }
    }

    var renderCaseDecl: String {
        guard !self.effectiveParams.isEmpty else {
            return "case \(self.name)"
        }

        var ret = "case \(self.name)("
        ret.append(
            self.effectiveParams.map { first, second, tpe in
                // FIXME: super naive... replace with something more proper
                let type = tpe
                    .replacingOccurrences(of: "<Self>", with: "<\(self.actorableName)>")
                    .replacingOccurrences(of: "<Self,", with: "<\(self.actorableName),")
                    .replacingOccurrences(of: ",Self>", with: ",\(self.actorableName)>")
                    .replacingOccurrences(of: ", Self>", with: ", \(self.actorableName)>")
                    .replacingOccurrences(of: "@escaping", with: "")

                if let name = first, name == "_" {
                    return "\(type)"
                } else if let name = first {
                    return "\(name): \(type)"
                } else {
                    return "\(second): \(type)"
                }
            }.joined(separator: ", ")
        )
        ret.append(")")

        return ret
    }

    func renderFunc(printer: inout CodePrinter, actor: ActorableTypeDecl, printBody: (inout CodePrinter) -> Void) {
        self.renderTellFuncDecl(printer: &printer, actor: actor)
        printer.print(" {")
        printer.indent()
        printBody(&printer)
        printer.outdent()
        printer.print("}")
    }

    func renderTellFuncDecl(printer: inout CodePrinter, actor: ActorableTypeDecl) {
        let access = self.access.map { "\($0) " } ?? ""

        printer.print("\(access)func \(self.name)", skipNewline: true)

        if actor.isGeneric {
            printer.print("<\(actor.renderGenericTypes)>", skipNewline: true)
        }

        printer.print("(\(self.renderFuncParams))\(self.returnType.renderReturnTypeDeclPart)", skipNewline: true)

        if actor.isGeneric {
            printer.print(" where Self.Message == \(actor.fullName)<\(actor.renderGenericNames)>.Message", skipNewline: true)
        }
    }

    func renderStubFunc(printer: inout CodePrinter, printBody: (inout CodePrinter) -> Void) {
        self.renderStubFuncDecl(printer: &printer)
        printer.print(" {")
        printer.indent()
        printBody(&printer)
        printer.outdent()
        printer.print("}")
    }

    func renderStubFuncDecl(printer: inout CodePrinter) {
        let access = self.access.map {
            "\($0) "
        } ?? ""

        printer.print("\(access)func \(self.name)(\(self.renderFuncParams))\(self.returnType.renderRawTypeDeclPart)", skipNewline: true)
    }

    var renderFuncParams: String {
        self.params.map { first, second, tpe in
            // FIXME: super naive... replace with something more proper
            let type = tpe
                .replacingOccurrences(of: "<Self>", with: "<\(self.actorableName)>")
                .replacingOccurrences(of: "<Self,", with: "<\(self.actorableName),")
                .replacingOccurrences(of: ",Self>", with: ",\(self.actorableName)>")
                .replacingOccurrences(of: ", Self>", with: ", \(self.actorableName)>")

            if let name = first {
                if name == second {
                    // no need to write `name name: String`
                    return "\(name): \(type)"
                }
                return "\(name) \(second): \(type)"
            } else {
                return "\(second): \(type)"
            }
        }.joined(separator: ", ")
    }

    /// Renders:
    ///
    /// ````(let thing, let other)
    var renderCaseLetParams: String {
        if self.effectiveParams.isEmpty {
            return ""
        } else {
            return "(" +
                self.effectiveParams.map { _, secondName, _ in
                    // TODO: Finally change the triple tuple into a specific type with more helpers
                    let name: String
//                    if firstName == "_" {
//                        name = secondName
//                    } else {
//                        name = firstName ?? secondName
//                    }
                    name = secondName
                    return "let \(name)"
                }.joined(separator: ", ") +
                ")"
        }
    }

    // // nothing
    // (hello: hello)
    // (_replyTo: _replyTo)
    func passEffectiveParamsWithBraces(printer: inout CodePrinter) {
        if self.effectiveParams.isEmpty {
            self.renderPassParams(effectiveParamsToo: true, printer: &printer)
        } else {
            printer.print("(", skipNewline: true)
            self.renderPassParams(effectiveParamsToo: true, printer: &printer)
            printer.print(")", skipNewline: true)
        }
    }

    // WARNING: Does not wrap with `()`
    //
    // // nothing
    // hello: hello
    // hello: hello, two: two
    func passParams(printer: inout CodePrinter) {
        self.renderPassParams(effectiveParamsToo: false, printer: &printer)
    }

    func renderPassParams(effectiveParamsToo: Bool, printer: inout CodePrinter) {
        let ps = effectiveParamsToo ? self.effectiveParams : self.params
        if ps.isEmpty {
            return
        } else {
            let render = ps.map { p in
                if let name = p.0, name == "_" {
                    // greet(name)
                    return "\(p.1)"
                } else {
                    // greet(name: name)
                    return "\(p.0 ?? p.1): \(p.1)"
                }
            }.joined(separator: ", ")

            printer.print(render, skipNewline: true)
        }
    }

    /// Implements the generated func method(...) by passing the parameters as a message, by telling or asking.
    func renderTellOrAskMessage(boxWith boxProtocol: ActorableTypeDecl? = nil, printer: inout CodePrinter) {
        var isAsk = false

        switch self.returnType {
        case .nioEventLoopFuture(let futureValueType):
            isAsk = true
            printer.print("// TODO: FIXME perhaps timeout should be taken from context")
            printer.print("Reply.from(askResponse: ")
            printer.indent()
            printer.print("self.ref.ask(for: Result<\(futureValueType), ErrorEnvelope>.self, timeout: .effectivelyInfinite) { _replyTo in")
            printer.indent()
        case .actorReply(let replyValueType), .askResponse(let replyValueType):
            isAsk = true
            printer.print("// TODO: FIXME perhaps timeout should be taken from context")
            printer.print("Reply.from(askResponse: ")
            printer.indent()
            printer.print("self.ref.ask(for: Result<\(replyValueType), ErrorEnvelope>.self, timeout: .effectivelyInfinite) { _replyTo in")
            printer.indent()
        case .type(let t):
            isAsk = true
            printer.print("// TODO: FIXME perhaps timeout should be taken from context")
            printer.print("Reply.from(askResponse: ")
            printer.indent()
            if self.throwing {
                printer.print("self.ref.ask(for: Result<\(t), ErrorEnvelope>.self, timeout: .effectivelyInfinite) { _replyTo in")
                printer.indent()
            } else {
                printer.print("self.ref.ask(for: \(t).self, timeout: .effectivelyInfinite) { _replyTo in")
                printer.indent()
            }
        case .result(let t, _):
            isAsk = true
            printer.print("// TODO: FIXME perhaps timeout should be taken from context")
            printer.print("Reply.from(askResponse: ")
            printer.indent()
            printer.print("self.ref.ask(for: Result<\(t), ErrorEnvelope>.self, timeout: .effectivelyInfinite) { _replyTo in")
            printer.indent()
        case .void:
            printer.print("self.ref.tell(", skipNewline: true)
            printer.indent()
        case .behavior:
            printer.print("self.ref.tell(", skipNewline: true)
            printer.indent()
        }

        if isAsk {
            self.renderPassMessage(boxWith: boxProtocol, skipNewline: false, printer: &printer)
            printer.outdent()
            printer.print("}")
            printer.outdent()
            printer.print(")")
        } else {
            self.renderPassMessage(boxWith: boxProtocol, skipNewline: true, printer: &printer)
            printer.print(")")
            printer.outdent()
        }
    }

    func renderPassMessage(boxWith boxProtocol: ActorableTypeDecl?, skipNewline: Bool, printer: inout CodePrinter) {
        if let boxName = boxProtocol?.boxFuncName {
            printer.print("A.", skipNewline: true)
            printer.print(boxName, skipNewline: true)
            printer.print("(", skipNewline: true)
            printer.print(".\(self.name)", skipNewline: true)
        } else {
            printer.print("Self.Message.\(self.name)", skipNewline: true)
        }

        self.passEffectiveParamsWithBraces(printer: &printer)

        if boxProtocol != nil {
            printer.print(")", skipNewline: skipNewline)
        }
    }
}

extension ActorableMessageDecl.ReturnType {
    /// Renders:
    /// ```
    ///
    /// // or
    /// -> Reply<T>
    /// ```
    var renderReturnTypeDeclPart: String {
        switch self {
        case .void:
            return ""
        case .behavior:
            return ""
        case .result(let t, _):
            return " -> Reply<Result<\(t), ErrorEnvelope>>"
        case .nioEventLoopFuture(let t),
             .actorReply(let t),
             .askResponse(let t):
            return " -> Reply<\(t)>"
        case .type(let t):
            return " -> Reply<\(t)>"
        }
    }

    var renderRawTypeDeclPart: String {
        switch self {
        case .void:
            return ""
        case .behavior(let behavior):
            return " -> \(behavior)"
        case .result(let t, _):
            return " -> Result<\(t), ErrorEnvelope>"
        case .nioEventLoopFuture(let t):
            return " -> EventLoopFuture<\(t)>"
        case .actorReply(let t):
            return " -> Reply<\(t)>"
        case .askResponse(let t):
            return " -> AskResponse<\(t)>"
        case .type(let t):
            return " -> \(t)"
        }
    }

    var isTypeReturn: Bool {
        if case .type = self {
            return true
        } else {
            return false
        }
    }

    var isResultReturn: Bool {
        if case .result = self {
            return true
        } else {
            return false
        }
    }

    var isFutureReturn: Bool {
        if case .nioEventLoopFuture = self {
            return true
        } else {
            return false
        }
    }

    var rendersReturn: Bool {
        switch self {
        case .void, .behavior:
            return false
        case .type, .result, .nioEventLoopFuture, .actorReply, .askResponse:
            return true
        }
    }
}

extension ActorFuncDecl {
    func renderFuncTell(_ actor: ActorableTypeDecl, printer: inout CodePrinter) throws {
        self.message.renderFunc(printer: &printer, actor: actor) { printer in
            message.renderTellOrAskMessage(boxWith: nil, printer: &printer)
        }
    }

    func renderFuncStub(printer: inout CodePrinter) throws {
        self.message.renderStubFunc(printer: &printer) { printer in
            printer.print("""
            fatalError("Function STUB for XPCActorableProtocol [\(self.message.name)], function: \\(#function).")
            """)
        }
    }

    func renderBoxFuncTell(_ actorableProtocol: ActorableTypeDecl, printer: inout CodePrinter) throws {
        precondition(actorableProtocol.type == .protocol, "protocolToBox MUST be protocol, was: \(actorableProtocol)")

        self.message.renderFunc(printer: &printer, actor: actorableProtocol) { printer in
            self.message.renderTellOrAskMessage(boxWith: actorableProtocol, printer: &printer)
        }
    }

    // TODO: dedup with the boxed one
    func renderFuncSwitchCase(partOfProtocol ownerProtocol: ActorableTypeDecl?, printer: inout CodePrinter) throws {
        printer.print("case ", skipNewline: true)

        if let boxProto = ownerProtocol {
            printer.print(".\(boxProto.nameFirstLowercased)(", skipNewline: true)
        }

        printer.print(".\(message.name)\(message.renderCaseLetParams)", skipNewline: true)

        if ownerProtocol != nil {
            printer.print(")", skipNewline: true)
        }

        printer.print(":")
        printer.indent(by: 5)

        if self.message.throwing, self.message.returnType.rendersReturn {
            printer.print("do {")
            printer.indent()
        }

        // render invocation
        if self.message.returnType.isTypeReturn || self.message.returnType.isResultReturn {
            printer.print("let result = ", skipNewline: true)
        }
        printer.print(self.message.returnIfBecome, skipNewline: true)
        if self.message.throwing {
            printer.print("try ", skipNewline: true)
        }
        printer.print("instance.\(self.message.name)(\(CodePrinter.content(self.message.passParams)))")
        if self.message.returnType.isTypeReturn {
            if self.message.throwing {
                printer.print("_replyTo.tell(.success(result))")
            } else {
                printer.print("_replyTo.tell(result)")
            }
        }

        switch self.message.returnType {
        case .nioEventLoopFuture:
            printer.indent()
            printer.print(".whenComplete { res in")
            printer.indent()
            printer.print("switch res {")
            printer.print("case .success(let value):")
            printer.indent()
            printer.print("_replyTo.tell(.success(value))")
            printer.outdent()
            printer.print("case .failure(let error):")
            printer.indent()
            printer.print("_replyTo.tell(.failure(ErrorEnvelope(error)))")
            printer.outdent()
            printer.print("}")
            printer.outdent()
            printer.print("}")
            printer.outdent()
        case .actorReply, .askResponse:
            printer.indent()
            printer.print("._onComplete { res in")
            printer.indent()
            printer.print("switch res {")
            printer.print("case .success(let value):")
            printer.indent()
            printer.print("_replyTo.tell(.success(value))")
            printer.outdent()
            printer.print("case .failure(let error):")
            printer.indent()
            printer.print("_replyTo.tell(.failure(ErrorEnvelope(error)))")
            printer.outdent()
            printer.print("}")
            printer.outdent()
            printer.print("}")
            printer.outdent()
        case .result:
            printer.print("_replyTo.tell(result.mapError { error in ErrorEnvelope(error) })")
        default:
            printer.print("")
        }

        if self.message.throwing, self.message.returnType.rendersReturn {
            printer.outdent()
            printer.print("} catch {")
            printer.indent()
            printer.print("context.log.warning(\"Error thrown while handling [\\(message)], error: \\(error)\")")
            printer.print("_replyTo.tell(.failure(ErrorEnvelope(error)))")
            printer.outdent()
            printer.print("}")
        }
    }

    func renderCaseDecl() -> String {
        self.message.renderCaseDecl
    }
}
