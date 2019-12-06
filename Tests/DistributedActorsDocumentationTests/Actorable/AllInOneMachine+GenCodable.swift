// ==== ------------------------------------------------------------------ ====
// === DO NOT EDIT: Generated by GenActors
// ==== ------------------------------------------------------------------ ====

//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// tag::imports[]

import DistributedActors

// end::imports[]

import DistributedActorsTestKit
import XCTest
// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Codable conformance for AllInOneMachine.Message
// TODO: This will not be required, once Swift synthesizes Codable conformances for enums with associated values

extension AllInOneMachine.Message: Codable {
    // TODO: Check with Swift team which style of discriminator to aim for
    public enum DiscriminatorKeys: String, Decodable {
        case clean
        case _boxDiagnostics
        case _boxCoffeeMachine
    }

    public enum CodingKeys: CodingKey {
        case _case
        case _boxDiagnostics
        case _boxCoffeeMachine
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(DiscriminatorKeys.self, forKey: CodingKeys._case) {
        case .clean:
            self = .clean
        case ._boxDiagnostics:
            let boxed = try container.decode(GeneratedActor.Messages.Diagnostics.self, forKey: CodingKeys._boxDiagnostics)
            self = .diagnostics(boxed)
        case ._boxCoffeeMachine:
            let boxed = try container.decode(GeneratedActor.Messages.CoffeeMachine.self, forKey: CodingKeys._boxCoffeeMachine)
            self = .coffeeMachine(boxed)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .clean:
            try container.encode(DiscriminatorKeys.clean.rawValue, forKey: CodingKeys._case)
        case .diagnostics(let boxed):
            try container.encode(boxed, forKey: CodingKeys._boxDiagnostics)
        case .coffeeMachine(let boxed):
            try container.encode(boxed, forKey: CodingKeys._boxCoffeeMachine)
        }
    }
}
