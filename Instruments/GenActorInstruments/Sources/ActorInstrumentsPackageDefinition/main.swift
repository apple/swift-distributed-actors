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

import GenActorInstruments
import Logging

LoggingSystem.bootstrap(StreamLogHandler.standardError)

if #available(macOS 10.14, *) {
    let generator = InstrumentsPackageDefinitionGenerator(
        packageDefinition: ActorInstrumentsPackageDefinition().packageDefinition
    )
    try! generator.run()
} else {
    print("Instruments(.app) PackageDefinition not available on non Apple platforms")
}
