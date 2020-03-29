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

#if os(macOS) || os(tvOS) || os(iOS) || os(watchOS)

extension PackageElement {
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .schema(let schema):
            try schema.encode(to: encoder)
        default:
            fatalError("Cannot encode: \(self)")
        }
    }
}

extension PackageDefinition {
    enum CodingKeys: String, CodingKey {
        case id
        case version

        case title

        case owner

        case schema_OSSignpostIntervalSchema = "os-signpost-interval-schema"
        case schema_OSSignpostPointSchema = "os-signpost-point-schema"

        case instrument
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.version, forKey: .version)
        try container.encode(self.title, forKey: .title)
        if let owner = self.owner {
            try container.encode(owner, forKey: .owner)
        }
        try self.schemas.forEach { schema in
            switch schema {
            case let s as OSSignpostIntervalSchema:
                try container.encode(s, forKey: .schema_OSSignpostIntervalSchema)
            case let s as OSSignpostPointSchema:
                try container.encode(s, forKey: .schema_OSSignpostPointSchema)
            default:
                fatalError("Unsupported schema type: \(type(of: schema as Any)); \(schema)")
            }
        }

        try self.instruments.forEach { instrument in
            try container.encode(instrument, forKey: .instrument)
        }
    }
}

extension Mnemonic {
    public func encode(to encoder: Encoder) throws {
        try self.name.encode(to: encoder)
    }
}

extension ClipsExpression {
    public func encode(to encoder: Encoder) throws {
        try self.expression.encode(to: encoder)
    }
}

extension StaticString: Encodable {
    public func encode(to encoder: Encoder) throws {
        try "\(self)".encode(to: encoder)
    }
}

extension Instrument {
    public enum CodingKeys: String, CodingKey {
        case id
        case version
        case title
        case category
        case purpose
        case icon

        case importParameters = "import-parameter"
        case createParameters = "create-parameter"
        case createTables = "create-table"

        case graphs = "graph"
        case lists = "list"
        case engineeringTypeTrack = "engineering-type-track"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.version, forKey: .version)
        try container.encode(self.title, forKey: .category)
        try container.encode(self.purpose, forKey: .purpose)
        try container.encode(self.icon, forKey: .icon)

        try container.encode(self.importParameters, forKey: .importParameters)
        try container.encode(self.createParameters, forKey: .createParameters)

        try container.encode(self.createTables, forKey: .createTables)

        try container.encode(self.graphs, forKey: .graphs)
        try container.encode(self.lists, forKey: .lists)

        try container.encode(self.engineeringTypeTracks, forKey: .engineeringTypeTrack)
    }
}

extension InstrumentElement {
    public enum CodingKeys: String, CodingKey {
        case importParameter = "import-parameter"
        case createParameter = "create-parameter"
        case createTable = "create-table"
        case engineeringTypeTrack = "engineering-type-track"

        case graph
        case list
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .importParameter(let element):
            try container.encode(element, forKey: .importParameter)
        case .createParameter(let element):
            try container.encode(element, forKey: .createParameter)
        case .createTable(let element):
            try container.encode(element, forKey: .createTable)
        case .engineeringTypeTrack(let element):
            try container.encode(element, forKey: .engineeringTypeTrack)

        case .graph(let element):
            try container.encode(element, forKey: .graph)
        case .list(let element):
            try container.encode(element, forKey: .list)

        case .fragment(let elements):
            fatalError("can't encode elements: \(elements)")
        }
    }
}

extension PackageDefinition.Instrument.TableRef {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.schemaRef.schemaRefString)
    }
}

extension PackageDefinition.Instrument.CreateTable {
    public enum CodingKeys: String, CodingKey {
        case id
        case schemaRef = "schema-ref"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.schemaRef, forKey: .schemaRef)
    }
}

extension PackageDefinition.Instrument.Graph {
    public enum CodingKeys: String, CodingKey {
        case title
        case purpose
        case lanes = "lane"
        case laneTemplates = "lane-template"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.title, forKey: .title)
        if let purpose = self.purpose {
            try container.encode(purpose, forKey: .purpose)
        }
        try container.encode(self.lanes, forKey: .lanes)
        try container.encode(self.laneTemplates, forKey: .laneTemplates)
    }
}

extension PackageDefinition.Instrument.Graph.Lane {
    public enum CodingKeys: String, CodingKey {
        case title
        case tableRef = "table-ref"
        case guide
        case baseColor = "base-color"

        case plot = "plot"
        case plotTemplates = "plot-templates"
        case histograms = "histogram"
        case histogramsTemplates = "histogram-templates"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.title, forKey: .title)
        try container.encode(self.tableRef, forKey: .tableRef)
        if let guide = self.guide {
            try container.encode(guide, forKey: .guide)
        }
        if let baseColor = self.baseColor {
            try container.encode(baseColor, forKey: .baseColor)
        }

        try self.plots.forEach { try container.encode($0, forKey: .plot)}
        try self.plotTemplates.forEach { try container.encode($0, forKey: .plotTemplates)}
        // try self.histograms.forEach { try container.encode($0, forKey: .histograms)} // TODO: implement this
        // try self.histogramsTemplates.forEach { try container.encode($0, forKey: .histogramsTemplates)} // TODO: implement this
    }
}

extension PackageDefinition.Instrument.Graph.PlotTemplate {
    public enum CodingKeys: String, CodingKey {
        case instanceBy = "instance-by"
        case labelFormat = "label-format"
        case slice = "slice"
        case valueFrom = "value-from"
        case colorFrom = "color-from"
        case priorityFrom = "priority-from"
        case labelFrom = "label-from"
        case qualifierTreatment = "qualifier-treatment"
        case containmentLevelFrom = "containment-level-from"
        case peerGroup = "peer-group"
        case ignorePeerGroup = "ignore-peer-group"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.instanceBy, forKey: .instanceBy)
        if let labelFormat = self.labelFormat {
            try container.encode(labelFormat, forKey: .labelFormat)
        }
        try container.encode(valueFrom, forKey: .valueFrom)
        if let colorFrom = self.colorFrom {
            try container.encode(colorFrom, forKey: .colorFrom)
        }
        if let labelFrom = self.labelFrom {
            try container.encode(labelFrom, forKey: .labelFrom)
        }
        // TODO: all others...
    }
}

extension GraphElement {
    public enum CodingKeys: String, CodingKey {
        case lane
        case laneTemplate
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .lane(let element):
            try container.encode(element, forKey: .lane)
        case .laneTemplate(let element):
            try container.encode(element, forKey: .laneTemplate)

        case .fragment(let elements):
            fatalError("can't encode elements: \(elements)")
        }
    }
}

extension GraphLaneElement {
    public enum CodingKeys: String, CodingKey {
        case plot
        case plotTemplate
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .plot(let element):
            try container.encode(element, forKey: .plot)
        case .plotTemplate(let element):
            try container.encode(element, forKey: .plotTemplate)

        case .fragment(let elements):
            fatalError("can't encode elements: \(elements)")
        }
    }
}

extension PackageDefinition.Instrument.List {
    public enum CodingKeys: String, CodingKey {
        case title = "title"
        case tableRef = "table-ref"
        case columns = "column"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.title, forKey: .title)
        try container.encode(self.tableRef, forKey: .tableRef)
        try container.encode(self.columns, forKey: .columns)
    }
}

extension PackageDefinition.Instrument.SchemaRef {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.schemaRefString)
    }
}

#endif
