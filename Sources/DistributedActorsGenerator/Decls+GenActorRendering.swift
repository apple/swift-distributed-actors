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

import NIO
import SwiftSyntax

protocol Renderable {
    func render() throws -> String
}

enum Rendering {
    static let generatedFileHeader: String =
        """
        // ==== ------------------------------------------------------------------ ====
        // === DO NOT EDIT: Generated by DistributedActorsGenerator                     
        // ==== ------------------------------------------------------------------ ====

        import _Distributed

        """
}

extension Rendering {
    struct ActorShellTemplate: Renderable {
        let nominal: DistributedActorDecl

        static let messageForNonProtocolTemplate = Template(
            templateString:
            """
            // ==== ----------------------------------------------------------------------------------------------------------------
            // MARK: DO NOT EDIT: Generated {{baseName}} messages 

            /// DO NOT EDIT: Generated {{baseName}} messages
            extension {{baseName}}: DistributedActors.__DistributedClusterActor {

                {{messageAccess}} enum Message: ActorMessage {
                    {{funcCases}}
                }

                {{boxFuncs}}
            }
            """
        )

        static let messageForProtocolTemplate = Template(
            templateString:
            """
            // ==== ----------------------------------------------------------------------------------------------------------------
            // MARK: DO NOT EDIT: Generated {{baseName}} messages 

            extension GeneratedActor.Messages {
                {{messageAccess}} enum {{baseName}}: ActorMessage {
                    {{funcCases}}
                }
            }

            """
        )

        static let boxingForProtocolTemplate = Template(
            templateString:
            """
            // ==== ----------------------------------------------------------------------------------------------------------------
            // MARK: DO NOT EDIT: Boxing {{baseName}} for any inheriting nominal `A` 

            extension Actor where Act: {{actorableProtocol}} {
            {{funcBoxTells}}
            }

            """
        )

        static let behaviorTemplate = Template(
            templateString:
            """
            // ==== ----------------------------------------------------------------------------------------------------------------
            // MARK: DO NOT EDIT: Generated {{baseName}} behavior

            extension {{baseName}} {
                // TODO(distributed): this is unfortunate but we can't seem to implement this in the library as we can't get to the specific Message type...
                public static func _spawnAny(instance: {{baseName}}, on system: ActorSystem) throws -> AddressableActorRef {
                    let ref = system._spawnDistributedActor( // TODO(distributed): hopefully avoid surfacing this function entirely
                        Self.makeBehavior(instance: instance), 
                        identifiedBy: instance.id
                    )
                    return ref.asAddressable
                }

                public static func makeBehavior(instance: {{baseName}}) -> Behavior<Message> {
                    return .setup { [weak instance] context in
                        // FIXME: if the actor has lifecycle hooks, call them
                        // try await instance.preStart(context: context)

                        return Behavior<Message>._receiveMessageAsync { [weak instance] message in
                            guard let instance = instance else {
                                // This isn't wrong per se, it just is a race with the instance going away while we were
                                // still delivering it some remote message; the same as any other termination race.
                                let deadLetters = context.system.personalDeadLetters(type: Message.self, recipient: context.address)
                                deadLetters.tell(message)
                                return .stop
                            }
                            switch message { 
                            {{funcSwitchCases}}
                            {{funcBoxSwitchCases}}
                            }
                            return .same
                        }._receiveSignalAsync { [weak instance] context, signal in 
                            switch signal {
                            case is Signals.PostStop:
                                // FIXME: if we'd expose lifecycle hooks, call them
                                // try await instance.postStop(context: context)
                                return .stop
                            case let terminated as Signals.Terminated:
                                if let watcher = instance as? (DistributedActor & DistributedActors.LifecycleWatchSupport) { // TODO: cleanup once LifecycleWatchSupport implies DistributedActor
                                     try await watcher.whenLocal { __secretlyKnownToBeLocal in 
                                         try await __secretlyKnownToBeLocal._receiveActorTerminated(identity: terminated.identity)
                                     }
                                     return .same
                                } else { 
                                    return .unhandled 
                                } 
                            default:
                                // FIXME: if we had signal handlers, invoke it
                                // {{tryIfReceiveSignalIsThrowing}}instance.receiveSignal(context: context, signal: signal)
                                return .same
                            }
                        }
                    }
                }
            }

            """
        )

        static let actorTellTemplate = Template(
            templateString:
            """
            // ==== ----------------------------------------------------------------------------------------------------------------
            // MARK: _remote distributed func implementations for {{baseName}}

            extension {{baseName}} {
            {{remoteImplFuncs}}
            }

            """
        )

        func render() throws -> String {
            let actorableProtocols = self.nominal.actorableProtocols.sorted()

            let context: [String: String] = [
                "baseName": self.nominal.fullName,
                "actorableProtocol": self.nominal.type == .protocol ? self.nominal.name : "",

                "varLetInstance": self.nominal.renderStoreInstanceAs,

                "messageAccess": "public", // TODO: allow non public actor messages

                "funcCases": self.nominal.renderCaseDecls,

                "extensionWhereClause": self.nominal.isGeneric ?
                    "" :
                    " where Act.Message == \(self.nominal.fullName).Message",

                "funcSwitchCases": try self.renderFuncSwitchCases(),
                "funcBoxSwitchCases": try self.renderFuncBoxSwitchCases(actorableProtocols: actorableProtocols),

                "boxFuncs": try self.renderBoxFuncs(actorableProtocols: actorableProtocols),

                "remoteImplFuncs": try self.renderRemoteFuncImpls(),
                "funcBoxTells": try self.renderFuncBoxTells(),

                "tryIfReceiveTerminatedIsThrowing": self.nominal.receiveTerminatedIsThrowing ? "try " : " ",
                "tryIfReceiveSignalIsThrowing": self.nominal.receiveSignalIsThrowing ? "try " : " ",
            ]

            var rendered: String = "\n"
            switch self.nominal.type {
            case .protocol:
                rendered.append(Self.messageForProtocolTemplate.render(context))
            default:
                rendered.append(Self.messageForNonProtocolTemplate.render(context))
                rendered.append("\n")
            }

            switch self.nominal.type {
            case .distributedActor:
                rendered.append(Self.behaviorTemplate.render(context))
                rendered.append(Self.actorTellTemplate.render(context))
            case .protocol:
                rendered.append(Self.boxingForProtocolTemplate.render(context))
            }

            return rendered
        }

        private func renderFuncSwitchCases() throws -> String {
            var first = true
            let switchCases = try self.nominal.funcs.map { funcDecl in
                try CodePrinter.content { printer in
                    if first {
                        printer.dontIndentNext()
                        first = false
                    }
                    printer.indent(by: 4)
                    try funcDecl.renderFuncSwitchCase(partOfProtocol: nil, printer: &printer)
                }
            }

            var printer = CodePrinter()
            printer.print(switchCases)
            return printer.content
        }

        private func renderFuncBoxSwitchCases(actorableProtocols: [DistributedActorDecl]) throws -> String {
            var first = true
            let boxSwitchCases = try actorableProtocols.flatMap { box in
                try box.funcs.map { funcDecl in
                    try CodePrinter.content { printer in
                        if first {
                            printer.dontIndentNext()
                            first = false
                        }
                        printer.indent(by: 4)
                        try funcDecl.renderFuncSwitchCase(partOfProtocol: box, printer: &printer)
                    }
                }
            }

            var printer = CodePrinter()
            printer.print(boxSwitchCases)
            return printer.content
        }

        private func renderBoxFuncs(actorableProtocols: [DistributedActorDecl]) throws -> String {
            let boxFuncs = try actorableProtocols.map { inheritedProtocol in
                try inheritedProtocol.renderBoxingFunc(in: self.nominal)
            }

            var printer = CodePrinter(startingIndentation: 1)
            printer.print(boxFuncs, indentFirstLine: false)
            return printer.content
        }

        private func renderRemoteFuncImpls() throws -> String {
            var printer = CodePrinter(startingIndentation: 1)
            for funcDecl in self.nominal.funcs {
                try funcDecl.renderRemoteImplFunc(self.nominal, printer: &printer)
            }

            return printer.content
        }

        private func renderFuncBoxTells() throws -> String {
            guard self.nominal.type == .protocol else {
                return ""
            }

            var printer = CodePrinter(startingIndentation: 1)
            try self.nominal.funcs.forEach { actorableFunc in
                try actorableFunc.renderBoxFuncTell(self.nominal, printer: &printer)
            }
            return printer.content
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Rendering extensions

extension DistributedActorDecl {
    /// Render if we should store this as `let`.
    var renderStoreInstanceAs: String {
        "let"
    }

    var renderCaseLet: String {
        "case .\(self.nameFirstLowercased)(let boxed):"
    }

    var renderBoxCaseLet: String {
        "case .\(self.boxFuncName)(let boxed):"
    }

    var renderCaseDecls: String {
        let renderedDirectFuncs = self.funcs.map {
            $0.renderCaseDecl()
        }

        let renderedActorableProtocolBoxes = self.actorableProtocols.sorted().map { decl in
            "case \(decl.nameFirstLowercased)(/*TODO: MODULE.*/GeneratedActor.Messages.\(decl.name))"
        }

        var res: [String] = renderedDirectFuncs
        res.append(contentsOf: renderedActorableProtocolBoxes)

        var printer = CodePrinter(startingIndentation: 2)
        printer.print(res, indentFirstLine: false)
        return printer.content
    }

    func renderBoxingFunc(in owner: DistributedActorDecl) throws -> String {
        let context: [String: String] = [
            "baseName": "\(owner.fullName)",
            "access": "public",
            "boxCaseName": "\(self.nameFirstLowercased)",
            "boxFuncName": "\(self.boxFuncName)",
            "messageToBoxType": "GeneratedActor.Messages.\(self.name)",
        ]

        return Template(
            templateString:
            """
            /// Performs boxing of {{messageToBoxType}} messages such that they can be received by Actor<{{baseName}}>
                {{access}} static func {{boxFuncName}}(_ message: {{messageToBoxType}}) -> {{baseName}}.Message {
                    .{{boxCaseName}}(message)
                }
            """
        ).render(context)
    }
}

extension DistributedMessageDecl {
    var returnIfBecome: String {
        switch self.returnType {
        case .behavior:
            return "return /*become*/ "
        default:
            return ""
        }
    }

    func renderCaseDecl() -> String {
        guard !self.effectiveParams.isEmpty else {
            return "case \(self.name)"
        }

        var ret = "case \(self.name)("
        ret.append(
            self.effectiveParams.map { first, second, tpe in
                // FIXME: super naive... replace with something more proper
                let type = tpe
                    .replacingOccurrences(of: "<Self>", with: "<\(self.actorName)>")
                    .replacingOccurrences(of: "<Self,", with: "<\(self.actorName),")
                    .replacingOccurrences(of: ",Self>", with: ",\(self.actorName)>")
                    .replacingOccurrences(of: ", Self>", with: ", \(self.actorName)>")
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

    func renderFunc(printer: inout CodePrinter, actor: DistributedActorDecl, printBody: (inout CodePrinter) -> Void) {
        self.renderRemoteFuncDecl(printer: &printer, actor: actor)
        printer.print(" {")
        printer.indent()
        printBody(&printer)
        printer.outdent()
        printer.print("}")
    }

    func renderTellFuncDecl(printer: inout CodePrinter, actor: DistributedActorDecl) {
        let access = self.access.map { "\($0) " } ?? ""

        printer.print("\(access)func \(self.name)", skipNewline: true)

        if actor.isGeneric {
            printer.print("<\(actor.renderGenericTypes)>", skipNewline: true)
        }

        printer.print("(\(self.renderFuncParams()))\(self.returnType.renderReturnDeclPart)", skipNewline: true)

        if actor.isGeneric {
            printer.indent()
            printer.print("") // force a newline

            // this generic clause replaces what would normally be done on the `extension ...` itself,
            // but we dont have parameterized extensions today, so we need to do it on all functions instead;
            // See also: https://forums.swift.org/t/parameterized-extensions/25563
            printer.print("where Self.Message == \(actor.fullName)<\(actor.renderGenericNames)>.Message", skipNewline: true)

            // if the nominal had any additional where clauses we need to carry them here as well
            if !actor.genericWhereClauses.isEmpty {
                actor.genericWhereClauses.forEach {
                    printer.print(",")
                    printer.print($0.clause, skipNewline: true)
                }
            }

            printer.outdent()
        }
    }

    func renderDynamicFunctionReplacementAttr(printer: inout CodePrinter) {
        var replacedFuncIdent = "_remote_\(self.name)"
        replacedFuncIdent += "("
        replacedFuncIdent += renderFuncParams(forFuncIdentifier: true)
        replacedFuncIdent += ")"
        printer.print("  @_dynamicReplacement(for:\(replacedFuncIdent))")
    }

    func renderRemoteFuncDecl(printer: inout CodePrinter, actor: DistributedActorDecl) {
        self.renderDynamicFunctionReplacementAttr(printer: &printer)

        let access = self.access.map { "\($0) " } ?? ""
        printer.print("\(access)func _remoteImpl_cluster_\(self.name)", skipNewline: true)

        // FIXME(distributed): handle actor and function both being generic
        if actor.isGeneric {
            printer.print("<\(actor.renderGenericTypes)>", skipNewline: true)
        }

        printer.print("(\(self.renderFuncParams()))\(self.returnType.renderReturnDeclPart)", skipNewline: true)

        if actor.isGeneric {
            printer.indent()
            printer.print("") // force a newline

            // this generic clause replaces what would normally be done on the `extension ...` itself,
            // but we dont have parameterized extensions today, so we need to do it on all functions instead;
            // See also: https://forums.swift.org/t/parameterized-extensions/25563
            printer.print("where Self.Message == \(actor.fullName)<\(actor.renderGenericNames)>.Message", skipNewline: true)

            // if the nominal had any additional where clauses we need to carry them here as well
            if !actor.genericWhereClauses.isEmpty {
                actor.genericWhereClauses.forEach {
                    printer.print(",")
                    printer.print($0.clause, skipNewline: true)
                }
            }

            printer.outdent()
        }
    }

    func renderFuncParams(forFuncIdentifier: Bool = false) -> String {
        var result = self.params.map { first, second, tpe in
            // FIXME: super naive... replace with something more proper
            let type = tpe
                .replacingOccurrences(of: "<Self>", with: "<\(self.actorName)>")
                .replacingOccurrences(of: "<Self,", with: "<\(self.actorName),")
                .replacingOccurrences(of: ",Self>", with: ",\(self.actorName)>")
                .replacingOccurrences(of: ", Self>", with: ", \(self.actorName)>")

            if let name = first {
                if name == second || forFuncIdentifier {
                    // no need to write `name name: String`
                    var ret = "\(name)"
                    if (!forFuncIdentifier) {
                        ret += ": \(type)"
                    }
                    return ret
                } else {
                    var ret = "\(name) \(second):"
                    if (!forFuncIdentifier) {
                        ret += " \(type)"
                    }
                    return ret
                }
            } else {
                if (forFuncIdentifier) {
                    return "_"
                } else {
                    return "\(second): \(type)"
                }
            }
        }.joined(separator: forFuncIdentifier ? ":" : ", ")

        if forFuncIdentifier && !self.params.isEmpty {
            result += ":"
        }
        return result
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
                    name = secondName
                    return "let \(name)"
                }.joined(separator: ", ") +
                ")"
        }
    }

    // // nothing
    // (hello: hello)
    // (_replyTo: _replyTo)
    func passEffectiveParamsWithBraces(printer: inout CodePrinter, skipNewline: Bool = false) {
        if self.effectiveParams.isEmpty {
            self.renderPassParams(effectiveParamsToo: true, printer: &printer)
        } else {
            printer.print("(", skipNewline: true)
            self.renderPassParams(effectiveParamsToo: true, printer: &printer)
            printer.print(")", skipNewline: skipNewline)
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

    /// Implements the generated func _remote_method(...) by passing the parameters as a message, by telling or asking.
    func renderTellOrAskMessage(boxWith boxProtocol: DistributedActorDecl? = nil, printer: inout CodePrinter) {

        // TODO: make this nicer... the ID could serve as the ref
        printer.print("guard let system = self.actorTransport as? ActorSystem else {")
        printer.indent()
        printer.print("fatalError(\"Unknown transport: \\(self.actorTransport), expected ActorSystem\")")
        printer.outdent()
        printer.print("}")
        printer.print("guard let address = self.id.underlying as? ActorAddress else {")
        printer.indent()
        printer.print("fatalError(\"Unknown identity: \\(self.id), expected ActorAddress\")")
        printer.outdent()
        printer.print("}")

        printer.print("")
        printer.print("// FIXME: this is not great; once the ID 'is' the reference, we'll be able to simplify this")
        printer.print("let ref: ActorRef<Message> = system._resolve(context: ResolveContext(address: address, system: system))")
        printer.print("")
        printer.outdent()

        switch self.returnType {
        case .nioEventLoopFuture(let futureValueType):
            printer.print("return try await ref.ask(for: Result<\(futureValueType), ErrorEnvelope>.self, timeout: system.settings.cluster.callTimeout) { _replyTo in")
            printer.indent()
        case .actorReply(let replyValueType), .askResponse(let replyValueType):
            printer.print("return try await ref.ask(for: Result<\(replyValueType), ErrorEnvelope>.self, timeout: system.settings.cluster.callTimeout) { _replyTo in")
            printer.indent()
        case .type(let t):
            if self.throwing {
                printer.print("return try await ref.ask(for: Result<\(t), ErrorEnvelope>.self, timeout: system.settings.cluster.callTimeout) { _replyTo in")
                printer.indent()
            } else {
                printer.print("return try await ref.ask(for: \(t).self, timeout: system.settings.cluster.callTimeout) { _replyTo in")
                printer.indent()
            }
        case .result(let t, _):
            printer.print("return try await ref.ask(for: Result<\(t), ErrorEnvelope>.self, timeout: system.settings.cluster.callTimeout) { _replyTo in")
            printer.indent()
        case .void:
            printer.print("try await ref.ask(for: Result<_Done, ErrorEnvelope>.self, timeout: system.settings.cluster.callTimeout) { _replyTo in")
            printer.indent()
        case .behavior(let t):
            printer.print("return try await ref.ask(for: Result<\(t), ErrorEnvelope>.self, timeout: system.settings.cluster.callTimeout) { _replyTo in")
            printer.indent()
        }

        self.renderPassMessage(boxWith: boxProtocol, skipNewline: false, printer: &printer)
        printer.outdent()
        printer.print("}._unsafeAsyncValue")
    }

    func renderPassMessage(boxWith boxProtocol: DistributedActorDecl?, skipNewline: Bool, printer: inout CodePrinter) {
        if let boxName = boxProtocol?.boxFuncName {
            printer.print("Act.", skipNewline: true)
            printer.print(boxName, skipNewline: true)
            printer.print("(", skipNewline: true)
            printer.print(".\(self.name)", skipNewline: true)
        } else {
            printer.print("Self.Message.\(self.name)", skipNewline: true)
        }

        self.passEffectiveParamsWithBraces(printer: &printer, skipNewline: skipNewline)
    }
}

extension DistributedMessageDecl.ReturnType {
    var renderReturnDeclPart: String {
        switch self {
        case .void:
            return " async throws"
        case .behavior(let t):
            return " async throws -> \(t)"
        case .result(let t, _),
             .nioEventLoopFuture(let t),
             .actorReply(let t),
             .askResponse(let t),
            .type(let t):
            return " async throws -> \(t)"
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

extension DistributedFuncDecl {

    func renderRemoteImplFunc(_ actor: DistributedActorDecl, printer: inout CodePrinter) throws {
        self.message.renderFunc(printer: &printer, actor: actor) { printer in
            message.renderTellOrAskMessage(boxWith: nil, printer: &printer)
        }
    }

    func renderBoxFuncTell(_ actorableProtocol: DistributedActorDecl, printer: inout CodePrinter) throws {
        precondition(actorableProtocol.type == .protocol, "protocolToBox MUST be protocol, was: \(actorableProtocol)")

        self.message.renderFunc(printer: &printer, actor: actorableProtocol) { printer in
            self.message.renderTellOrAskMessage(boxWith: actorableProtocol, printer: &printer)
        }
    }

    // TODO: dedup with the boxed one
    func renderFuncSwitchCase(partOfProtocol ownerProtocol: DistributedActorDecl?, printer: inout CodePrinter) throws {
        printer.print("case ", skipNewline: true)

        if let boxProto = ownerProtocol {
            printer.print(".\(boxProto.nameFirstLowercased)(", skipNewline: true)
        }

        printer.print(".\(message.name)\(message.renderCaseLetParams)", skipNewline: true)

        if ownerProtocol != nil {
            printer.print(")", skipNewline: true)
        }

        printer.print(":")
        printer.indent()

        /// since we invoke a distributed func (even though we know it is local)
        /// the function is always throwing so we wrap it in a do/catch:
        if self.message.returnType.rendersReturn {
            printer.print("do {")
            printer.indent()
        }

        // render invocation
        if self.message.returnType.isTypeReturn || self.message.returnType.isResultReturn {
            printer.print("let result = ", skipNewline: true)
        }
        printer.print(self.message.returnIfBecome, skipNewline: true)
        printer.dontIndentNext()
        printer.print("try await ", skipNewline: true)
        printer.print("instance.\(self.message.name)(\(CodePrinter.content(self.message.passParams)))")
        if self.message.returnType.isTypeReturn {
            if self.message.throwing {
                // FIXME: ENABLE THIS, BECAUSE ALL FUNCS MAY THROW HERE
//                printer.print("_replyTo.tell(.success(result))")
                printer.print("_replyTo.tell(result)")
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

        if self.message.returnType.rendersReturn {
            printer.outdent()
            printer.print("} catch {")
            printer.indent()
            printer.print("context.log.warning(\"Error thrown while handling [\\(message)], error: \\(error)\")")
            // FIXME: ENABLE THIS, BECAUSE ALL FUNCS MAY THROW HERE
            // printer.print("_replyTo.tell(.failure(ErrorEnvelope(error)))")
            printer.outdent()
            printer.print("}")
        }
    }

    func renderCaseDecl() -> String {
        self.message.renderCaseDecl()
    }
}
