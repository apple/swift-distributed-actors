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
import Files
import Foundation
import SwiftSyntax

public final class GenerateActors {
    var filesToScan: [File] = []
    var foldersToScan: [Folder] = []

    var settings: Settings

    let fileScanNameSuffix: String = "+Actorable"
    let fileScanNameSuffixWithExtension: String = "+Actorable.swift"
    let fileGenNameSuffixWithExtension: String = "+GenActor.swift"

    public init(args: [String]) {
        let remaining = args.dropFirst()
        self.settings = remaining.filter {
            $0.starts(with: "-")
        }.reduce(into: Settings()) { settings, option in
            switch option {
            case "-v", "--verbose":
                settings.verbose = true
            default:
                ()
            }
        }

        do {
            let passedInToScan: [String] = remaining.filter {
                !$0.starts(with: "--")
            }.map { path in
                if path.starts(with: "/") {
                    return path
                } else {
                    return Folder.current.path + path
                }
            }

            self.filesToScan = try passedInToScan.filter {
                $0.hasSuffix(self.fileScanNameSuffixWithExtension)
            }.map { path in
                try File(path: path)
            }
            self.foldersToScan = try passedInToScan.filter {
                !$0.hasSuffix(".swift")
            }.map { path in
                try Folder(path: path)
            }

            if self.foldersToScan.isEmpty {
                try self.foldersToScan.append(Folder.current.subfolder(at: "Sources"))
            }

        } catch {
            fatalError("Unable to initialize \(GenerateActors.self), error: \(error)")
        }
    }

    public func run() throws {
        try self.filesToScan.forEach { file in
            _ = try self.parseAndGen(fileToParse: file)
        }

        try self.foldersToScan.forEach { folder in
            self.debug("Scanning [\(folder.path)] for [\(self.fileScanNameSuffixWithExtension)] suffixed files...")
            let actorFilesToScan = folder.files.recursive.filter { f in
                f.name.hasSuffix(self.fileScanNameSuffixWithExtension)
            }

            try actorFilesToScan.forEach { file in
                _ = try self.parseAndGen(fileToParse: file)
            }
        }
    }

    public func parseAndGen(fileToParse: File) throws -> Bool {
        self.debug("Parsing: \(fileToParse.path)")

        let url = URL(fileURLWithPath: fileToParse.path)
        let sourceFile = try SyntaxParser.parse(url)

        var gather = GatherActorables(self.settings)
        sourceFile.walk(&gather)
        let rawActorables = gather.actorables

        let actorables = ResolveActorables.resolve(rawActorables)

        try actorables.forEach { actorable in
            let renderedShell = try Rendering.ActorShellTemplate(actorable: actorable).render(self.settings)

            guard let parent = fileToParse.parent else {
                fatalError("Unable to locate or render Actorable definitions in \(fileToParse).")
            }

            let targetFile = try parent.createFile(named: "\(actorable.name)\(self.fileGenNameSuffixWithExtension)")

            try targetFile.append(Rendering.generatedFileHeader)
            try targetFile.append("\n")
            try gather.imports.forEach { importBlock in
                try targetFile.append("\(importBlock)")
            }
            try targetFile.append(renderedShell)
        }

        return !rawActorables.isEmpty
    }

    func debug(_ message: String) {
        if self.settings.verbose {
            print("[gen-actors] \(message)")
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Settings

extension GenerateActors {
    struct Settings {
        /// If true, prints verbose information during analysis and source code generation.
        /// Can be enabled using `--verbose`
        var verbose: Bool = false
    }
}
