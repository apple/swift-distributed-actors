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

extension Rendering {
    struct MessageCodableTemplate: Renderable {
        let actorable: ActorableTypeDecl

        static let messageCodableConformanceTemplate = Template(
            templateString:
            """

            // ==== ----------------------------------------------------------------------------------------------------------------
            // MARK: DO NOT EDIT: Codable conformance for {{baseName}}
            // TODO: This will not be required, once Swift synthesizes Codable conformances for enums with associated values 

            extension {{baseName}} {
                // TODO: Check with Swift team which style of discriminator to aim for
                public enum DiscriminatorKeys: String, Decodable {
                    {{ discriminatorCases }}
                }

                public enum CodingKeys: CodingKey {
                    {{ codingKeys }}
                }

                public init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    switch try container.decode(DiscriminatorKeys.self, forKey: CodingKeys._case) {
                    {{ decodeCases }}
                    }
                }

                public func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    switch self {
                    {{ encodeCases }}
                    }
                }
            }

            """
        )

        func render(_: GenerateActorsCommand) throws -> String {
            let printer = CodePrinter()

            let baseName = "\(self.actorable.messageFullyQualifiedName)"

            // ==== ----------------------------------------------------------------------------------------------------
            // MARK: discriminatorCases
            var discriminatorCases = printer.makeIndented(by: 2)
            discriminatorCases.dontIndentNext()
            self.actorable.funcs.forEach { decl in
                discriminatorCases.print("case \(decl.message.name)")
            }

            // actorable protocols
            self.actorable.actorableProtocols.forEach { proto in
                discriminatorCases.print("case \(proto.boxFuncName)")
            }

            // ==== ----------------------------------------------------------------------------------------------------
            // MARK: codingKeys
            var codingKeys = printer.makeIndented(by: 2)
            codingKeys.dontIndentNext()
            codingKeys.print("case _case") // the "special" case used to find the DiscriminatorKeys
            self.actorable.funcs.forEach { decl in
                decl.message.effectiveParams.forEach { firstName, secondName, _ in
                    let name: String
                    if firstName == "_" {
                        name = secondName
                    } else {
                        name = firstName ?? secondName
                    }
                    codingKeys.print("case \(decl.message.name)_\(name)")
                }
            }

            // actorable protocols
            self.actorable.actorableProtocols.forEach { proto in
                codingKeys.print("case \(proto.boxFuncName)")
            }

            // ==== ----------------------------------------------------------------------------------------------------
            // MARK: decodeCases
            var decodeCases = printer.makeIndented(by: 2)
            decodeCases.dontIndentNext()
            self.actorable.funcs.forEach { decl in
                decodeCases.print("case .\(decl.message.name):")
                decodeCases.indent()

                // render decode params
                decl.message.effectiveParams.forEach { firstName, secondName, type in
                    let name: String
                    if firstName == "_" {
                        name = secondName
                    } else {
                        name = firstName ?? secondName
                    }
                    if type == "ActorRef<Self>" {
                        decodeCases.print("let \(secondName) = try container.decode(ActorRef<\(self.actorable.name).Message>.self, forKey: CodingKeys.\(decl.message.name)_\(name))")
                    } else if type == "Actor<Self>" {
                        decodeCases.print("let \(secondName) = try container.decode(Actor<\(self.actorable.name)>.self, forKey: CodingKeys.\(decl.message.name)_\(name))")
                    } else {
                        decodeCases.print("let \(secondName) = try container.decode(\(type).self, forKey: CodingKeys.\(decl.message.name)_\(name))")
                    }
                }
                decodeCases.print("self = .\(decl.message.name)\(CodePrinter.content(decl.message.passEffectiveParamsWithBraces))")
                decodeCases.outdent()
            }

            // also encode any actorable protocols we conform to
            self.actorable.actorableProtocols.forEach { proto in
                decodeCases.print("case .\(proto.boxFuncName):") // case _boxParking:
                decodeCases.indent()
                decodeCases.print("let boxed = try container.decode(\(proto.messageFullyQualifiedName).self, forKey: CodingKeys.\(proto.boxFuncName))")
                decodeCases.print("self = .\(proto.nameFirstLowercased)(boxed)")
                decodeCases.outdent()
            }

            // ==== ----------------------------------------------------------------------------------------------------
            // MARK: encodeCases

            var encodeCases = printer.makeIndented(by: 2)
            encodeCases.dontIndentNext()
            self.actorable.funcs.forEach { decl in
                encodeCases.print("case .\(decl.message.name)\(decl.message.renderCaseLetParams):")
                encodeCases.indent()
                encodeCases.print("try container.encode(DiscriminatorKeys.\(decl.message.name).rawValue, forKey: CodingKeys._case)")
                // render encode params
                decl.message.effectiveParams.forEach { firstName, secondName, _ in
                    // TODO: finally make the 3-tuple a specific type with helpers
                    let name: String
                    if firstName == "_" {
                        name = secondName
                    } else {
                        name = firstName ?? secondName
                    }

                    encodeCases.print("try container.encode(\(secondName), forKey: CodingKeys.\(decl.message.name)_\(name))")
                }
                encodeCases.outdent()
            }

            // also encode any actorable protocols we conform to
            self.actorable.actorableProtocols.forEach { proto in
                encodeCases.print(proto.renderCaseLet) // case parking(let boxed):
                encodeCases.indent()
                encodeCases.print("try container.encode(DiscriminatorKeys.\(proto.boxFuncName).rawValue, forKey: CodingKeys._case)")
                encodeCases.print("try container.encode(boxed, forKey: CodingKeys.\(proto.boxFuncName))")
                encodeCases.outdent()
            }

            return try Self.messageCodableConformanceTemplate.render(
                [
                    "baseName": baseName,
                    "discriminatorCases": discriminatorCases.content,
                    "codingKeys": codingKeys.content,
                    "decodeCases": decodeCases.content,
                    "encodeCases": encodeCases.content,
                ]
            )
        }
    }
}
