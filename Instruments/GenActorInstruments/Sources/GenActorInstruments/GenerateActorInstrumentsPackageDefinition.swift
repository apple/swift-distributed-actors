//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ArgumentParser
import DistributedActors
import Foundation
import XMLCoder
import Logging

struct GenerateActorInstrumentsPackageDefinition {
    let log: Logger = Logger(label: "gen-package-def")
    let settings: Command

    init(command settings: Self.Command) {
        self.settings = settings
    }

    #if os(macOS) || os(tvOS) || os(iOS) || os(watchOS)
    func run() throws {
        if #available(macOS 10.14, *) {
            let package = ActorInstrumentsPackageDefinition().packageDefinition

            let xml = try! XMLEncoder().encode(package, withRootKey: "package")

            var renderedXML = "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>"
            renderedXML.append(String(data: xml, encoding: .utf8)!)

            try renderedXML.write(toFile: self.settings.output, atomically: true, encoding: .utf8)

            self.log.info("Rendered: \(self.settings.output)")
            self.log.info("To format the generates XML you may want to pipe through: xmllint --output Instruments/ActorInstruments/ActorInstruments/ActorInstruments.instrpkg --format -")


            self.log.info("""
                          To generate package using Xcode: 
                              open ./Instruments/ActorInstruments/ActorInstruments.xcodeproj
                          """)


            if self.settings.stdout {
                print(renderedXML)
            }
        }
    }

    #else
    func run() {
        print("Instruments(.app) PackageDefinition not available on non Apple platforms")
    }
    #endif
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Command Line interface

extension GenerateActorInstrumentsPackageDefinition {
    struct Command: ParsableCommand {
        @Flag(
            name: .shortAndLong,
            help: "If true, the entire PackageDefinition XML is also printed to stdout"
        )
        var stdout: Bool

        @Flag(
            name: .shortAndLong,
            help: "Print verbose information"
        )
        var verbose: Bool

        @Option(
            default: "./Instruments/ActorInstruments/ActorInstruments/ActorInstruments.instrpkg",
            help: "Where to write the generated instruments package definition file"
        )
        var output: String
    }
}

extension GenerateActorInstrumentsPackageDefinition.Command {
    public func run() throws {
        let gen = GenerateActorInstrumentsPackageDefinition(command: self)
        try gen.run()
    }
}
