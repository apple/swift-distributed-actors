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
    func render() throws -> String
}

enum Rendering {
    static let generatedFileHeader: String =
        """
        // ==== ------------------------------------------------------------------ ====
        // === DO NOT EDIT: Generated by GenActors                     
        // ==== ------------------------------------------------------------------ ====

        import DistributedActors


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

                // TODO: if overriden don't generate this?
                // {{messageAccess}} typealias Message = Actor<{{baseName}}>.{{baseName}}Message

                public static func makeBehavior(instance: {{baseName}}) -> Behavior<Message> {
                    return .setup { context in
                        var instance = instance // TODO only var if any of the methods are mutating

                        // /* await */ self.instance.preStart(context: context) // TODO: enable preStart

                        return .receiveMessage { message in
                            switch message { 
                            {% for case in funcSwitchCases %}
                            {{case}} {% endfor %}
                            {% for case in funcBoxSwitchCases %}
                            {{case}} {% endfor %}
                            }
                            return .same
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

        func render() throws -> String {
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

//            for delegateProtocol in self.actorable.actorableProtocols {
//                let context: [String: Any] = [
//                    "baseName": self.actorable.name,
//
//                ]
//
//                let renderedProtocolTellsExtension = try Self.actorProtocolTellTemplate.render(context)
//                rendered.append(renderedProtocolTellsExtension)
//            }

            // TODO: if debug mode of generation
            print(rendered)

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

    func renderBoxingFunc(`in` owner: ActorableDecl) throws -> String {
        let context: [String: Any] = [
            "baseName": "\(owner.name)",
            "access": "public",
            "boxCaseName": "\(self.nameFirstLowercased)",
            "boxFuncName": "\(self.boxFuncName)",
            "messageToBoxType": "GeneratedActor.Messages.\(self.name)",
        ]

        return try Template(stringLiteral:
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
            return "return "
        default:
            return ""
        }
    }

    var renderCaseDecl: String {
        guard !self.params.isEmpty else {
            return "case \(self.name)"
        }

        var ret = "case \(self.name)("
        ret.append(
            self.params.map { first, second, tpe in
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

    var funcDecl: String {
        let access = self.access.map {
            "\($0) "
        } ?? ""

        return "\(access)func \(self.name)(\(self.renderFuncParams))"
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
        if self.params.isEmpty {
            return ""
        } else {
            return "(" +
                self.params.map { p in
                    "let \(p.1)"
                }.joined(separator: ", ") +
                ")"
        }
    }

    var passParams: String {
        if self.params.isEmpty {
            return ""
        } else {
            return self.params.map { p in
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

    var passMessage: String {
        var ret = ".\(self.name)"

        if !self.params.isEmpty {
            ret.append("(")
            ret.append(self.passParams)
            ret.append(")")
        }

        return ret
    }
}

extension ActorFuncDecl {

    func renderFuncTell() throws -> String {
        let context: [String: Any] = [
            "funcDecl": message.funcDecl,
            "passMessage": message.passMessage,
        ]

        let rendered = try Template(
            templateString:
            """
            {{funcDecl}} { 
                    self.ref.tell({{passMessage}})
                }
            """
        ).render(context)

        return rendered
    }

    func renderBoxFuncTell(_ actorableProtocol: ActorableDecl) throws -> String {
        precondition(actorableProtocol.type == .protocol, "protocolToBox MUST be protocol, was: \(actorableProtocol)")

        let context: [String: Any] = [
            "funcDecl": self.message.funcDecl,
            "passMessage": self.message.passMessage,
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
        let context: [String: Any] = [
            "returnIfBecome": message.returnIfBecome,
            "try": message.throwing ? "try " : "",
            "name": message.name,
            "caseLetParams": message.renderCaseLetParams,
            "passParams": message.passParams,
        ]

        let rendered = try Template(
            templateString:
            """
            case .{{name}}{{caseLetParams}}:
                                {{returnIfBecome}}{{try}}instance.{{name}}({{passParams}})
            """
        ).render(context)

        return rendered
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
        return self.message.renderCaseDecl
    }
}
