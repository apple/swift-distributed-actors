//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Tracing

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Injector

struct InvocationMessageInjector: Tracing.Injector {
    typealias Carrier = InvocationMessage

    func inject(_ value: String, forKey key: String, into carrier: inout Carrier) {
        carrier.metadata[key] = value
    }
}

extension Tracing.Injector where Self == InvocationMessageInjector {
    static var invocationMessage: InvocationMessageInjector {
        InvocationMessageInjector()
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Extractor

struct InvocationMessageExtractor: Tracing.Extractor {
    typealias Carrier = InvocationMessage

    func extract(key: String, from carrier: Carrier) -> String? {
        carrier.metadata[key]
    }
}

extension Tracing.Extractor where Self == InvocationMessageExtractor {
    static var invocationMessage: InvocationMessageExtractor {
        InvocationMessageExtractor()
    }
}
