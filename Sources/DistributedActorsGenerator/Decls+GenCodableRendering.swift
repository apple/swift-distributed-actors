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

extension Rendering {
    struct MessageCodableTemplate: Renderable {
        let nominal: DistributedActorDecl

        static let messageCodableConformanceTemplate = Template(
            templateString:
            """

            // ==== ----------------------------------------------------------------------------------------------------------------
            // MARK: DO NOT EDIT: Codable conformance for {{baseName}}
            // TODO: This will not be required, once Swift synthesizes Codable conformances for enums with associated values 

            extension {{baseName}} {
                public enum DiscriminatorKeys: String, Decodable {
                    {{discriminatorCases}}
                }

                public enum CodingKeys: CodingKey {
                    {{codingKeys}}
                }

                public init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    switch try container.decode(DiscriminatorKeys.self, forKey: CodingKeys._case) {
                    {{decodeCases}}
                    }
                }

                public func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    switch self {
                    {{encodeCases}}
                    }
                }
            }

            """
        )

        func render() throws -> String {
            let printer = CodePrinter()

            let baseName = "\(self.nominal.messageFullyQualifiedName)"

            let actorableProtocols = self.nominal.actorableProtocols.sorted()

            // ==== ----------------------------------------------------------------------------------------------------
            // MARK: discriminatorCases
            var discriminatorCases = printer.makeIndented(by: 2)
            discriminatorCases.dontIndentNext()
            self.nominal.funcs.forEach { nominal in
                discriminatorCases.print("case \(nominal.message.name)")
            }

            // nominal protocols
            actorableProtocols.forEach { proto in
                discriminatorCases.print("case \(proto.boxFuncName)")
            }

            // ==== ----------------------------------------------------------------------------------------------------
            // MARK: codingKeys
            var codingKeys = printer.makeIndented(by: 2)
            codingKeys.dontIndentNext()
            codingKeys.print("case _case") // the "special" case used to find the DiscriminatorKeys
            self.nominal.funcs.forEach { nominal in
                nominal.message.effectiveParams.forEach { firstName, secondName, _ in
                    let name: String
                    if firstName == "_" {
                        name = secondName
                    } else {
                        name = firstName ?? secondName
                    }
                    codingKeys.print("case \(nominal.message.name)_\(name)")
                }
            }

            // nominal protocols
            actorableProtocols.forEach { proto in
                codingKeys.print("case \(proto.boxFuncName)")
            }

            // ==== ----------------------------------------------------------------------------------------------------
            // MARK: decodeCases
            var decodeCases = printer.makeIndented(by: 2)
            decodeCases.dontIndentNext()
            self.nominal.funcs.forEach { nominal in
                decodeCases.print("case .\(nominal.message.name):")
                decodeCases.indent()

                // render decode params
                nominal.message.effectiveParams.forEach { firstName, secondName, type in
                    let name: String
                    if firstName == "_" {
                        name = secondName
                    } else {
                        name = firstName ?? secondName
                    }
                    if type == "ActorRef<Self>" {
                        decodeCases.print("let \(secondName) = try container.decode(ActorRef<\(self.nominal.name).Message>.self, forKey: CodingKeys.\(nominal.message.name)_\(name))")
                    } else if type == "Actor<Self>" {
                        decodeCases.print("let \(secondName) = try container.decode(Actor<\(self.nominal.name)>.self, forKey: CodingKeys.\(nominal.message.name)_\(name))")
                    } else {
                        decodeCases.print("let \(secondName) = try container.decode(\(type).self, forKey: CodingKeys.\(nominal.message.name)_\(name))")
                    }
                }
                decodeCases.print("self = .\(nominal.message.name)\(CodePrinter.content { printer in nominal.message.passEffectiveParamsWithBraces(printer: &printer) })")
                decodeCases.outdent()
            }

            // also encode any nominal protocols we conform to
            actorableProtocols.forEach { proto in
                decodeCases.print("case .\(proto.boxFuncName):") // case _boxParking:
                decodeCases.indent()
                // note that the explicit `: Type` is necessary to avoid warnings/errors in case the nominal has zero messages
                // which would result in: `constant 'boxed' inferred to have type '...', which is an enum with no cases`
                decodeCases.print("let boxed: \(proto.messageFullyQualifiedName) = try container.decode(\(proto.messageFullyQualifiedName).self, forKey: CodingKeys.\(proto.boxFuncName))")
                decodeCases.print("self = .\(proto.nameFirstLowercased)(boxed)")
                decodeCases.outdent()
            }

            // ==== ----------------------------------------------------------------------------------------------------
            // MARK: encodeCases

            var encodeCases = printer.makeIndented(by: 2)
            encodeCases.dontIndentNext()
            self.nominal.funcs.forEach { nominal in
                encodeCases.print("case .\(nominal.message.name)\(nominal.message.renderCaseLetParams):")
                encodeCases.indent()
                encodeCases.print("try container.encode(DiscriminatorKeys.\(nominal.message.name).rawValue, forKey: CodingKeys._case)")
                // render encode params
                nominal.message.effectiveParams.forEach { firstName, secondName, _ in
                    // TODO: finally make the 3-tuple a specific type with helpers
                    let name: String
                    if firstName == "_" {
                        name = secondName
                    } else {
                        name = firstName ?? secondName
                    }

                    encodeCases.print("try container.encode(\(secondName), forKey: CodingKeys.\(nominal.message.name)_\(name))")
                }
                encodeCases.outdent()
            }

            // also encode any nominal protocols we conform to
            actorableProtocols.forEach { proto in
                encodeCases.print(proto.renderCaseLet) // case parking(let boxed):
                encodeCases.indent()
                encodeCases.print("try container.encode(DiscriminatorKeys.\(proto.boxFuncName).rawValue, forKey: CodingKeys._case)")
                encodeCases.print("try container.encode(boxed, forKey: CodingKeys.\(proto.boxFuncName))")
                encodeCases.outdent()
            }

            return Self.messageCodableConformanceTemplate.render(
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
