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
import Stencil
import SwiftSyntax

protocol Renderable {
    func render(_ settings: GenerateActors.Settings) throws -> String
}

enum Rendering {
    static let generatedFileHeader: String =
        """
        // ==== ------------------------------------------------------------------ ====
        // === DO NOT EDIT: Generated by GenActors                     
        // ==== ------------------------------------------------------------------ ====

        """

    struct ActorShellTemplate: Renderable {
        let actorable: ActorableDecl

        static let messageForNonProtocolTemplate = Template(
            templateString:
            """
            // ==== ----------------------------------------------------------------------------------------------------------------
            // MARK: DO NOT EDIT: Generated {{baseName}} messages 

            /// DO NOT EDIT: Generated {{baseName}} messages
            extension {{baseName}} {
                // TODO: make Message: Codable - https://github.com/apple/swift-distributed-actors/issues/262
                {{messageAccess}} enum Message { {% for case in funcCases %}
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
                {{messageAccess}} enum {{baseName}} { {% for case in funcCases %}
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
                        var instance = instance // TODO only var if any of the methods are mutating

                        /* await */ instance.preStart(context: context)

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
                                switch instance.receiveTerminated(context: context, terminated: terminated) {
                                case .unhandled: 
                                    return .unhandled
                                case .stop: 
                                    return .stop
                                case .ignore: 
                                    return .same
                                }
                            default:
                                return .unhandled
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
            // MARK: Extend Actor for {{baseName}}

            extension Actor where A.Message == {{baseName}}.Message {
                {% for tell in funcTells %}
                {{ tell }} 
                {% endfor %}
            }

            """
        )

        func render(_ settings: GenerateActors.Settings) throws -> String {
            let context: [String: Any] = [
                "baseName": self.actorable.name,
                "actorableProtocol": self.actorable.type == .protocol ? self.actorable.name : "",

                "messageAccess": "public", // TODO: allow non public actor messages

                "funcCases": self.actorable.renderCaseDecls,

                "funcSwitchCases": try self.actorable.funcs.map {
                    try $0.renderFuncSwitchCase()
                },
                "funcBoxSwitchCases": try self.actorable.actorableProtocols.flatMap { box in
                    try box.funcs.map {
                        try $0.renderBoxFuncSwitchCase(partOf: box)
                    }
                },

                "boxFuncs": try self.actorable.actorableProtocols.map { inheritedProtocol in
                    try inheritedProtocol.renderBoxingFunc(in: self.actorable)
                },

                "funcTells": try self.actorable.funcs.map {
                    try $0.renderFuncTell()
                },
                "funcBoxTells": self.actorable.type == .protocol ? try self.actorable.funcs.map {
                    try $0.renderBoxFuncTell(self.actorable)
                } : [],
            ]

            var rendered: String = ""
            switch self.actorable.type {
            case .protocol:
                rendered.append(try Self.messageForProtocolTemplate.render(context))
            default:
                rendered.append(try Self.messageForNonProtocolTemplate.render(context))
            }

            switch self.actorable.type {
            case .struct, .class:
                rendered.append(try Self.behaviorTemplate.render(context))
                rendered.append(try Self.actorTellTemplate.render(context))
            case .protocol:
                rendered.append(try Self.boxingForProtocolTemplate.render(context))
            }

            if settings.verbose {
                print(rendered)
            }

            return rendered
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Rendering extensions

extension ActorableDecl {
    var renderCaseDecls: [String] {
        let renderedDirectFuncs = self.funcs.map {
            $0.renderCaseDecl()
        }

        let renderedActorableProtocolBoxes = self.actorableProtocols.map { decl in
            "case \(decl.nameFirstLowercased)(/*TODO: MODULE.*/GeneratedActor.Messages.\(decl.name))"
        }

        var res: [String] = renderedDirectFuncs
        res.append(contentsOf: renderedActorableProtocolBoxes)

        return res
    }

    func renderBoxingFunc(in owner: ActorableDecl) throws -> String {
        let context: [String: Any] = [
            "baseName": "\(owner.name)",
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

    var renderFuncDecl: String {
        let access = self.access.map {
            "\($0) "
        } ?? ""

        return "\(access)func \(self.name)(\(self.renderFuncParams))\(self.returnType.renderReturnTypeDeclPart)"
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
                self.effectiveParams.map { p in
                    "let \(p.1)"
                }.joined(separator: ", ") +
                ")"
        }
    }

    var passEffectiveParams: String {
        self.renderPassParams(effectiveParamsToo: true)
    }

    var passParams: String {
        self.renderPassParams(effectiveParamsToo: false)
    }

    func renderPassParams(effectiveParamsToo: Bool) -> String {
        let ps = effectiveParamsToo ? self.effectiveParams : self.params
        if ps.isEmpty {
            return ""
        } else {
            return ps.map { p in
                if let name = p.0, name == "_" {
                    // greet(name)
                    return "\(p.1)"
                } else {
                    // greet(name: name)
                    return "\(p.1): \(p.1)"
                }
            }.joined(separator: ", ")
        }
    }

    /// Implements the generated func method(...) by passing the parameters as a message, by telling or asking.
    var renderTellOrAskMessage: String {
        var ret = ""
        var isAsk = false

        switch self.returnType {
        case .nioEventLoopFuture(let futureValueType):
            isAsk = true
            ret.append("// TODO: FIXME perhaps timeout should be taken from context\n")
            ret.append("        Reply(nioFuture: \n")
            ret.append("            self.ref.ask(for: Result<\(futureValueType), Error>.self, timeout: .effectivelyInfinite) { _replyTo in\n")
            ret.append("                ")
        case .type(let t):
            isAsk = true
            ret.append("// TODO: FIXME perhaps timeout should be taken from context\n")
            ret.append("        Reply(nioFuture: \n")
            if self.throwing {
                ret.append("            self.ref.ask(for: Result<\(t), Error>.self, timeout: .effectivelyInfinite) { _replyTo in\n")
            } else {
                ret.append("            self.ref.ask(for: \(t).self, timeout: .effectivelyInfinite) { _replyTo in\n")
            }
            ret.append("                ")
        case .result(let t, let errType):
            isAsk = true
            ret.append("// TODO: FIXME perhaps timeout should be taken from context\n")
            ret.append("        Reply(nioFuture: \n")
            ret.append("            self.ref.ask(for: Result<\(t), \(errType)>.self, timeout: .effectivelyInfinite) { _replyTo in\n")
            ret.append("                ")
        case .void:
            ret.append("self.ref.tell(")
        case .behavior:
            ret.append("self.ref.tell(")
        }

        ret.append(self.renderPassMessage)

        if isAsk {
            ret.append("\n")
            ret.append("            }")
            if self.throwing || self.returnType.isFutureReturn {
                ret.append("""
                .nioFuture.flatMapThrowing { result in
                            switch result {
                            case .success(let res): return res
                            case .failure(let err): throw err
                            }
                        }\n
                """)
            } else {
                ret.append(".nioFuture\n")
            }
            ret.append("            )")
        } else {
            ret.append(")")
        }

        return ret
    }

    var renderPassMessage: String {
        var ret = ".\(self.name)"

        if !self.effectiveParams.isEmpty {
            ret.append("(")
            ret.append(self.passEffectiveParams)
            ret.append(")")
        }

        return ret
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
        case .result(let t, let errT):
            return " -> ResultReply<\(t), \(errT)>" // TODO: Reply type; ResultReply<T, Reason>
        case .nioEventLoopFuture(let t):
            return " -> Reply<\(t)>" // TODO: Reply type; Reply<T>
        case .type(let t):
            return " -> Reply<\(t)>" // TODO: Reply type; Reply<T>
        }
    }

    var isTypeReturn: Bool {
        if case .type = self {
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
        case .type, .result, .nioEventLoopFuture:
            return true
        }
    }
}

extension ActorFuncDecl {
    func renderFuncTell() throws -> String {
        let context: [String: Any] = [
            "funcDecl": message.renderFuncDecl,
            "passMessage": message.renderTellOrAskMessage,
        ]

        let rendered = try Template(
            templateString:
            """
            {{funcDecl}} { 
                    {{passMessage}}
                }
            """
        ).render(context)

        return rendered
    }

    // TODO: implement boxed asks
    func renderBoxFuncTell(_ actorableProtocol: ActorableDecl) throws -> String {
        precondition(actorableProtocol.type == .protocol, "protocolToBox MUST be protocol, was: \(actorableProtocol)")

        let context: [String: Any] = [
            "funcDecl": self.message.renderFuncDecl,
            "passMessage": self.message.renderPassMessage,
            "boxFuncName": actorableProtocol.boxFuncName,
        ]

        let rendered = try Template(
            templateString:
            """
            {{funcDecl}} { 
                    self.ref.tell(A.{{boxFuncName}}({{passMessage}}))
                }
            """
        ).render(context)

        return rendered
    }

    // TODO: dedup with the boxed one
    func renderFuncSwitchCase() throws -> String {
        var ret = "case .\(message.name)\(message.renderCaseLetParams):"
        ret.append("\n")

        let context: [String: Any] = [
            "name": self.message.name,
            "returnIfBecome": self.message.returnIfBecome,
            "storeIfTypeReturn": self.message.returnType.isTypeReturn ? "let result = " : "",
            "replyWithTypeReturn": self.message.returnType.isTypeReturn ?
                (self.message.throwing ?
                    "\n                    _replyTo.tell(.success(result))" :
                    "\n                    _replyTo.tell(result)"
                ) : "",
            "try": self.message.throwing ? "try " : "",
            "passParams": self.message.passParams,
        ]

        if self.message.throwing, self.message.returnType.rendersReturn {
            ret.append("                    do {")
            ret.append("\n")
        }

        // FIXME: it really is time to adopt CodePrinter

        // render invocation
        ret.append(try Template(
            templateString:
            "                    {{storeIfTypeReturn}}{{returnIfBecome}}{{try}}instance.{{name}}({{passParams}}){{replyWithTypeReturn}}"
        ).render(context))

        if case .nioEventLoopFuture = self.message.returnType {
            ret.append("\n                                    .whenComplete { res in _replyTo.tell(res) }")
        } else {
            ret.append("\n")
        }

        if self.message.throwing, self.message.returnType.rendersReturn {
            let pad = "                    " // FIXME: replace with code printer
            ret.append("\(pad)} catch {\n")
            ret.append("\(pad)    context.log.warning(\"Error thrown while handling [\\(message)], error: \\(error)\")\n")
            ret.append("\(pad)    _replyTo.tell(.failure(error))\n")
            ret.append("\(pad)}\n")
        }

        return ret
    }

    func renderBoxFuncSwitchCase(partOf ownerProtocol: ActorableDecl) throws -> String {
        let context: [String: Any] = [
            "box": ownerProtocol.nameFirstLowercased,
            "returnIfBecome": message.returnIfBecome,
            "try": message.throwing ? "try " : "",
            "name": message.name,
            "caseLetParams": message.renderCaseLetParams,
            "passParams": message.passParams,
        ]

        let rendered = try Template(
            templateString:
            """
            case .{{box}}(.{{name}}{{caseLetParams}}):
                                {{returnIfBecome}}{{try}}instance.{{name}}({{passParams}})
            """
        ).render(context)

        return rendered
    }

    func renderCaseDecl() -> String {
        self.message.renderCaseDecl
    }
}
