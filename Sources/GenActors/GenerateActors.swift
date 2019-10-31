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
    let foldersToScan: [Folder]
    var options: [String]

    let fileScanNameSuffix: String = "+Actorable"
    let fileScanNameSuffixWithExtension: String = "+Actorable.swift"

    public init(args: [String]) {
        precondition(args.count > 1, "Syntax: genActors PATH [options]")

        var remaining = args.dropFirst()
        self.options = remaining.filter { $0.starts(with: "--") }

        do {
            let foldersToScan = remaining.filter { !$0.starts(with: "--") }
            precondition(!foldersToScan.isEmpty, "At least one directory to scan must be passed in. Arguments were: \(args)")
            self.foldersToScan = try foldersToScan.map { try Folder(path: Folder.current.path + "/\($0)") }
        } catch {
            fatalError("Unable to initialize \(GenerateActors.self), error: \(error)")
        }
    }

    public func run() throws -> Bool {
        let foldersContainedActorables: [Bool] = try self.foldersToScan.map { folder in
            self.debug("Scanning [\(folder.path)] for [\(self.fileScanNameSuffixWithExtension)] suffixed files...")
            let actorFilesToScan = folder.files.recursive.filter { f in
                f.name.hasSuffix(self.fileScanNameSuffixWithExtension)
            }

            return try actorFilesToScan.reduce(true) { acc, file in
                try acc && self.parseAndGen(fileToParse: file)
            }
        }

        return foldersContainedActorables.reduce(true) { $0 && $1 }
    }

    public func parseAndGen(fileToParse: File) throws -> Bool {
        self.debug("Parsing: \(fileToParse.path)")

        let url = URL(fileURLWithPath: fileToParse.path)
        let sourceFile = try SyntaxParser.parse(url)

        var gather = GatherActorables()
        sourceFile.walk(&gather)

        // TODO: allow many actors in same file
        let baseName = gather.actorable

        let renderedShell = try Rendering.ActorShellTemplate(baseName: baseName, funcs: gather.actorFuncs).render()

        let genActorFilename = "\(fileToParse.nameExcludingExtension).swift".replacingOccurrences(of: self.fileScanNameSuffix, with: "+GenActors")
        guard let parentFolder = fileToParse.parent else {
            fatalError("Unable to locate or render Actorable definitions in \(fileToParse.parent).")
        }
        let targetFile = try parentFolder.createFile(named: genActorFilename)
        try targetFile.write(Rendering.generatedFileHeader)
        try targetFile.append(renderedShell)

        return true
    }

    func debug(_ message: String, file: StaticString = #file, line: UInt = #line) {
        pprint("[gen-actors] \(message)", file: file, line: line)
    }
}

// TODO: we do not allow many actors in the same file I guess
struct GatherActorables: SyntaxVisitor {
    /// Those functions need to be made into message protocol and generate stuff for them
    var actorFuncs: [ActorFunc] = []
    var actorable: String = ""

    mutating func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.isActorable() else {
            return .skipChildren
        }

        self.debug("Actorable detected: [\(node.identifier.text)]")
        self.actorable = node.identifier.text

        pprint("self = \(self)")

        return .visitChildren
    }

    mutating func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.isActorable() else {
            return .skipChildren
        }

        self.debug("Actorable detected: \(node.identifier)") // TODO: we could allow many
        self.actorable = node.identifier.text

        return .visitChildren
    }

    mutating func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let modifierTokenKinds = node.modifiers?.map {
            $0.name.tokenKind
        } ?? []

        // TODO: carry access control
        guard !modifierTokenKinds.contains(.privateKeyword) else {
            return .skipChildren
        }

        let access: String
        if modifierTokenKinds.contains(.publicKeyword) {
            access = "public"
        } else if modifierTokenKinds.contains(.internalKeyword) {
            access = "internal"
        } else {
            access = ""
        }
        
        let throwing: Bool
        switch node.signature.throwsOrRethrowsKeyword?.tokenKind {
        case .throwsKeyword:
            throwing = true
        default:
            throwing = false
        }

        // TODO: we could require it to be async as well or something
        self.actorFuncs.append(
            ActorFunc(message: ActorableMessageDecl(
                access: access,
                throwing: throwing,
                name: "\(node.identifier)",
                params: node.signature.gatherParams()
            ))
        )

        // pprint("MAKE INTO ACTOR FUNC: \(node)")
        return .skipChildren
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Gather parameters of function declarations

struct GatherParameters: SyntaxVisitor {
    typealias Output = [(String?, String, String)]
    var params: Output = []

    mutating func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
        let firstName = node.firstName?.text
        guard let secondName = node.secondName?.text ?? firstName else {
            fatalError("No `secondName` or `firstName` available at: \(node)")
        }
        guard let type = node.type?.description else {
            fatalError("No `type` available at: \(node)")
        }

        self.params.append((firstName, secondName, type))
        return .skipChildren
    }
}

extension FunctionSignatureSyntax {
    func gatherParams() -> GatherParameters.Output {
        var gather = GatherParameters()
        self.walk(&gather)
        return gather.params
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Check type is Actorable

extension DeclSyntax {
    func isActorable() -> Bool {
        var isActorable = IsActorableVisitor()
        self.walk(&isActorable)
        return isActorable.actorable
    }
}

struct IsActorableVisitor: SyntaxVisitor {
    var actorable: Bool = false

    mutating func visit(_ node: InheritedTypeSyntax) -> SyntaxVisitorContinueKind {
        if "\(node)".contains("Actorable") { // TODO: make less hacky
            self.actorable = true
            return .skipChildren
        }
        return .visitChildren
    }

    var shouldContinue: SyntaxVisitorContinueKind {
        return self.actorable ? .visitChildren : .skipChildren
    }
}

extension SyntaxVisitor {
    func debug(_ message: String, file: StaticString = #file, line: UInt = #line) {
        pprint("[gen-actors] \(message)", file: file, line: line)
    }
}
