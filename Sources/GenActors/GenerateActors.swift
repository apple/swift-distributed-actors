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

    let fileScanNameSuffix: String = ""
    let fileScanNameSuffixWithExtension: String = ".swift"
    let fileGenActorNameSuffixWithExtension: String = "+GenActor.swift"
    let fileGenCodableNameSuffixWithExtension: String = "+GenCodable.swift"

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

            if self.foldersToScan.isEmpty, self.filesToScan.isEmpty {
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

        let path = try File(path: url.path).path(relativeTo: Folder.current)
        var gather = GatherActorables(path, self.settings)
        sourceFile.walk(&gather)
        let rawActorables = gather.actorables

        let actorables = ResolveActorables.resolve(rawActorables)

        try actorables.forEach { actorable in

            guard let parent = fileToParse.parent else {
                fatalError("Unable to locate or render Actorable definitions in \(fileToParse).")
            }

            _ = try generateGenActorFile(parent, gather: gather, actorable: actorable)

            _ = try generateGenCodableFile(parent, gather: gather, actorable: actorable)
        }

        return !rawActorables.isEmpty
    }

    private func generateGenActorFile(_ parent: Folder, gather: GatherActorables, actorable: ActorableTypeDecl) throws -> File {
        let genFolder = try parent.createSubfolderIfNeeded(withName: "GenActors")
        let targetFile = try genFolder.createFile(named: "\(actorable.name)\(self.fileGenActorNameSuffixWithExtension)")

        try targetFile.append(Rendering.generatedFileHeader)
        try targetFile.append("\n")

        try gather.imports.forEach { importBlock in
            try targetFile.append("\(importBlock)")
        }

        try targetFile.append("\n")
        let renderedShell = try Rendering.ActorShellTemplate(actorable: actorable).render(self.settings)
        try targetFile.append(renderedShell)

        return targetFile
    }

    /// Generate Codable conformances for the `Message` type -- until we don't have auto synthesis of it for enums with associated values.
    private func generateGenCodableFile(_ parent: Folder, gather: GatherActorables, actorable: ActorableTypeDecl) throws -> File? {
        guard actorable.generateCodableConformance else {
            return nil // skip generating
        }

        let genFolder = try parent.createSubfolderIfNeeded(withName: "GenActors")
        let targetFile = try genFolder.createFile(named: "\(actorable.name)\(self.fileGenCodableNameSuffixWithExtension)")

        try targetFile.append(Rendering.generatedFileHeader)
        try targetFile.append("\n")

        try gather.imports.forEach { importBlock in
            try targetFile.append("\(importBlock)")
        }

        try targetFile.append("\n")
        let codableConformance = try Rendering.MessageCodableTemplate(actorable: actorable).render(self.settings)
        try targetFile.append(codableConformance)

        return targetFile
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
