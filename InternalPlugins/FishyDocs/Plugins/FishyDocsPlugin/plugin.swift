import Foundation
import PackagePlugin

@main struct FishyDocsBuildPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let genSourcesDir = context.pluginWorkDirectory
        let doccBasePath = "\(context.package.directory)/Sources/DistributedActors/Docs.docc"

        let mdFiles = try FileManager.default
            .contentsOfDirectory(atPath: doccBasePath)
            .filter { $0.hasSuffix(".md") }
            .map { Path("\(doccBasePath)/\($0)") }

        return try mdFiles.map { mdPath in
            guard let mdFileFileName = "\(mdPath)".split(separator: "/").last else {
                fatalError("Can't find filename for: \(mdPath)")
            }
            let outputPath = Path("\(genSourcesDir)/\(mdFileFileName)+CompileTest.swift")

            return .buildCommand(
                displayName: "Running FishyDocs",
                executable: try context.tool(named: "FishyDocs").path,
                arguments: [
                    "--docc-file", "\(mdPath)",
                    "--output-file", "\(outputPath)",
                ],
                environment: [
                    "PROJECT_DIR": "\(context.package.directory)",
                    "TARGET_NAME": "\(target.name)",
                    "DERIVED_SOURCES_DIR": "\(genSourcesDir)",
                ],
                inputFiles: [mdPath],
                outputFiles: [outputPath]
            )
        }
    }
}
