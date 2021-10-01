//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

struct Template {
    let templateString: String
    
    func render(_ context: [String: String]) -> String {
        context.reduce(self.templateString) { result, entry in
            result.replacingOccurrences(of: "{{\(entry.key)}}", with: entry.value)
        }
    }
}
