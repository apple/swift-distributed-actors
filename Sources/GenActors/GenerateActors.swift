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

import ArgumentParser
import DistributedActors
import Files
import Foundation
import Logging
import SwiftSyntax

final class GenerateActors {
    var log: Logger
    var filesToScan: [File] = []
    var foldersToScan: [Folder] = []

    let command: GenerateActorsCommand

    let fileScanNameSuffix: String = ""
    let fileScanNameSuffixWithExtension: String = ".swift"
    let fileGenActorNameSuffixWithExtension: String = "+GenActor.swift"
    let fileGenCodableNameSuffixWithExtension: String = "+GenCodable.swift"

    public init(command: GenerateActorsCommand) {
        self.command = command

        self.log = Logger(label: "\(GenerateActors.self)")
        self.log.logLevel = command.logLevelValue

        do {
            let passedInToScan: [String] = command.scanTargets
                .map { path in
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
            }.filter {
                !self.isGeneratedFile(file: $0)
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
        if self.command.clean {
            cleanAll()
        }

        let unresolvedActorables = try parseAll()

        // resolves protocol adoption across files; e.g. a protocol defined in another file can be implemented in another
        // TODO: does not work cross module yet (it would break)
        let resolvedActorables = ResolveActorables.resolve(unresolvedActorables)

        try generateAll(resolvedActorables: resolvedActorables)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Parsing sources

extension GenerateActors {
    private func isGeneratedFile(file: File) -> Bool {
        file.name.hasSuffix(self.fileGenActorNameSuffixWithExtension) ||
            file.name.hasSuffix(self.fileGenCodableNameSuffixWithExtension)
    }

    private func cleanAll() {
        func delete(_ file: File) {
            do {
                self.log.info("Cleaning up: [\(file.path)]...")
                try file.delete()
            } catch {
                self.log.warning("Could not delete file: \(file)")
            }
        }

        self.filesToScan.forEach { file in
            if isGeneratedFile(file: file) {
                delete(file)
            }
        }

        self.foldersToScan.forEach { folder in
            folder.files.recursive
                .filter { isGeneratedFile(file: $0) }
                .forEach { delete($0) }
        }
    }

    private func parseAll() throws -> [ActorableTypeDecl] {
        var unresolvedActorables: [ActorableTypeDecl] = []

        try self.filesToScan.forEach { file in
            let actorablesInFile = try self.parse(fileToParse: file)
            unresolvedActorables.append(contentsOf: actorablesInFile)
        }

        try self.foldersToScan.forEach { folder in
            self.log.debug("Scanning [\(folder.path)] for actorables...")
            let actorFilesToScan = folder.files.recursive.filter { f in
                f.name.hasSuffix(self.fileScanNameSuffixWithExtension)
            }.filter {
                !self.isGeneratedFile(file: $0)
            }

            try actorFilesToScan.forEach { file in
                let actorablesInFile = try self.parse(fileToParse: file)
                unresolvedActorables.append(contentsOf: actorablesInFile)
            }
        }
        return unresolvedActorables
    }

    func parse(fileToParse: File) throws -> [ActorableTypeDecl] {
        self.log.debug("Parsing: \(fileToParse.path)")

        let url = URL(fileURLWithPath: fileToParse.path)
        let sourceFile = try SyntaxParser.parse(url)

        let path = try File(path: url.path)
        let gather = GatherActorables(path, self.command)
        gather.walk(sourceFile)

        // perform a resolve within the file
        let rawActorables = gather.actorables
        let actorables = ResolveActorables.resolve(rawActorables)

        return actorables
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Generating sources

extension GenerateActors {
    private func generateAll(resolvedActorables: [ActorableTypeDecl]) throws {
        try resolvedActorables.forEach { actorable in
            guard let parent = actorable.sourceFile.parent else {
                fatalError("Unable to locate or render Actorable definitions in \(actorable.sourceFile).")
            }

            _ = try generateGenActorFile(parent, actorable: actorable)
            _ = try generateGenCodableFile(parent, actorable: actorable)
        }
    }

    private func generateGenActorFile(_ parent: Folder, actorable: ActorableTypeDecl, skipGenBehavior: Bool = false) throws -> File {
        let genFolder = try parent.createSubfolderIfNeeded(withName: "GenActors")
        let targetFile = try genFolder.createFile(named: "\(actorable.name)\(self.fileGenActorNameSuffixWithExtension)")

        try targetFile.append(Rendering.generatedFileHeader)
        try targetFile.append("\n")

        try actorable.imports.forEach { importBlock in
            try targetFile.append("\(importBlock)")
        }

        try targetFile.append("\n")
        let renderedShell = try Rendering.ActorShellTemplate(actorable: actorable).render(self.command)
        try targetFile.append(renderedShell)

        self.log.debug("Generated: \(targetFile.path)")
        return targetFile
    }

    /// Generate Codable conformances for the `Message` type -- until we don't have auto synthesis of it for enums with associated values.
    private func generateGenCodableFile(_ parent: Folder, actorable: ActorableTypeDecl) throws -> File? {
        guard actorable.generateCodableConformance else {
            return nil // skip generating
        }

        let genFolder = try parent.createSubfolderIfNeeded(withName: "GenActors")
        let targetFile = try genFolder.createFile(named: "\(actorable.name)\(self.fileGenCodableNameSuffixWithExtension)")

        try targetFile.append(Rendering.generatedFileHeader)
        try targetFile.append("\n")

        try actorable.imports.forEach { importBlock in
            try targetFile.append("\(importBlock)")
        }

        try targetFile.append("\n")
        let codableConformance = try Rendering.MessageCodableTemplate(actorable: actorable).render(self.command)
        try targetFile.append(codableConformance)

        self.log.debug("Generated: \(targetFile.path)")
        return targetFile
    }
}
