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

enum TestActorableNamespace {
    struct TestActorableNamespaceDirectly: Actorable {
        // @actor
        func echo(_ string: String) -> String {
            string
        }
    }

    struct NotActorable {}
}

extension TestActorableNamespace {
    struct TestActorableNamespaceInExtension: Actorable {
        // @actor
        func echo(_ string: String) -> String {
            string
        }
    }

    struct NotActorableAgain {}
}

extension TestActorableNamespace {
    enum InnerNamespace {
        struct TestActorableNamespaceExtensionEnumDirectly: Actorable {
            // @actor
            func echo(_ string: String) -> String {
                string
            }
        }
    }
}
