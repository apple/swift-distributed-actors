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
import SwiftSyntax

final class GenerateActors {
    var filesToScan: [File] = []
    var foldersToScan: [Folder] = []

    let command: GenerateActorsCommand

    let fileScanNameSuffix: String = ""
    let fileScanNameSuffixWithExtension: String = ".swift"
    let fileGenActorNameSuffixWithExtension: String = "+GenActor.swift"
    let fileGenXPCProtocolStubSuffixWithExtension: String = "+XPCProtocolStub.swift"
    let fileGenCodableNameSuffixWithExtension: String = "+GenCodable.swift"

    public init(command: GenerateActorsCommand) {
        self.command = command

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

    func info(_ message: String) {
        print("[gen-actors][INFO] \(message)")
    }

    func debug(_ message: String) {
        if self.command.verbose {
            print("[gen-actors][DEBUG] \(message)")
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Parsing sources

extension GenerateActors {
    private func isGeneratedFile(file: File) -> Bool {
        file.name.hasSuffix(self.fileGenActorNameSuffixWithExtension) ||
            file.name.hasSuffix(self.fileGenXPCProtocolStubSuffixWithExtension) ||
            file.name.hasSuffix(self.fileGenCodableNameSuffixWithExtension)
    }

    private func cleanAll() {
        func delete(_ file: File) {
            do {
                self.info("Cleaning up: [\(file.path)]...")
                try file.delete()
            } catch {
                self.info("Could not delete: \(file)")
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
            self.debug("Scanning [\(folder.path)] for actorables...")
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
        self.debug("Parsing: \(fileToParse.path)")

        let url = URL(fileURLWithPath: fileToParse.path)
        let sourceFile = try SyntaxParser.parse(url)

        let path = try File(path: url.path)
        var gather = GatherActorables(path, self.command)
        sourceFile.walk(&gather)

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
            _ = try generateXPCProtocolStubFile(parent, actorable: actorable, resolvedActorables: resolvedActorables)
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
        let renderedShell = try Rendering.ActorShellTemplate(actorable: actorable, stubGenBehavior: skipGenBehavior).render(self.command)
        try targetFile.append(renderedShell)

        self.debug("Generated: \(targetFile.path)")
        return targetFile
    }

    /// For `XPCActorableProtocol` we need to generate a `...Stub` type as it is impossible to write `Actor<Protocol>`,
    /// yet that is exactly what we'd like to express -- "this is a reference to some implementation of Protocol, and we do not know what it is".
    ///
    // FIXME: Would be fixed if we could say Actor<some Protocol> I suppose?
    private func generateXPCProtocolStubFile(_ parent: Folder, actorable: ActorableTypeDecl, resolvedActorables: [ActorableTypeDecl]) throws -> File? {
        guard actorable.type == .protocol, actorable.inheritedTypes.contains("XPCActorableProtocol") else {
            return nil
        }

        let genFolder = try parent.createSubfolderIfNeeded(withName: "GenActors")
        let targetFile = try genFolder.createFile(named: "\(actorable.name)\(self.fileGenXPCProtocolStubSuffixWithExtension)")

        try targetFile.append(Rendering.generatedFileHeader)
        try targetFile.append("\n")

        try actorable.imports.forEach { importBlock in
            try targetFile.append("\(importBlock)")
        }

        try targetFile.append("\n")
        let renderedShell = try Rendering.XPCProtocolStubTemplate(actorable: actorable).render(self.command)
        try targetFile.append(renderedShell)

        self.info("Generated XPCActorableProtocol stub: \(targetFile.path)...")

        // parse and gen the generated file, as we need the actor functions more than we need the Stub actually (!)
        let stubActorables = try self.parse(fileToParse: targetFile)

        // we need to resolve the stub actorable in order to generate _box methods for it
        var all = resolvedActorables
        all.append(contentsOf: stubActorables)
        var resolvedStubActorables = ResolveActorables.resolve(all)
        resolvedStubActorables = resolvedStubActorables.filter { resolved in
            // TODO: naive, can be improved; but we need to get out only the resolved Stubs here basically
            stubActorables.contains(where: { stub in stub.fullName == resolved.fullName })
        }

        try resolvedStubActorables.forEach { stubActorable in
            let generatedGenActor = try self.generateGenActorFile(parent, actorable: stubActorable, skipGenBehavior: true)
            self.debug("Generated \(self.fileGenActorNameSuffixWithExtension) for \(stubActorable.name): \(generatedGenActor.path)")

            if let generatedGenCodable = try self.generateGenCodableFile(parent, actorable: stubActorable) {
                self.debug("Generated \(self.fileGenCodableNameSuffixWithExtension) for \(stubActorable.name): \(generatedGenCodable.path)")
            }
        }

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

        self.debug("Generated: \(targetFile.path)")
        return targetFile
    }
}
