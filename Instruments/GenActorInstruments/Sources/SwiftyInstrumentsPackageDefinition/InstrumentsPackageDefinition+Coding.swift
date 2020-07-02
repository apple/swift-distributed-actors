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
        case template
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.version, forKey: .version)
        try container.encode(self.title, forKey: .title)
        try container.encodeIfPresent(self.owner, forKey: .owner)
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

        try container.encodeIfPresent(self.template, forKey: .template)
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

extension Column {
    public enum CodingKeys: String, CodingKey {
        case mnemonic
        case title
        case type
        case guide
        case expression
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(mnemonic, forKey: .mnemonic)
        try container.encode(title, forKey: .title)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(guide, forKey: .guide)
        try container.encode(expression, forKey: .expression)
    }
}

extension StaticString: Encodable {
    public func encode(to encoder: Encoder) throws {
        try "\(self)".encode(to: encoder)
    }
}

extension PackageDefinition.OSSignpostIntervalSchema: Encodable {
    enum CodingKeys: String, CodingKey {
        case id
        case title
        case required
        case note
        case attribute

        case subsystem
        case category
        case name

        case startPattern = "start-pattern"
        case endPattern = "end-pattern"

        case column
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.title, forKey: .title)
        if let required = self.required {
            try container.encode(required, forKey: .required)
        }
        if let note = self.note {
            try container.encode(note, forKey: .note)
        }
        if let attribute = self.attribute {
            try container.encode(attribute, forKey: .attribute)
        }
        try container.encode("\"\(self.subsystem)\"", forKey: .subsystem)
        try container.encode("\"\(self.category)\"", forKey: .category)
        try container.encode("\"\(self.name)\"", forKey: .name)
        try container.encode(SignpostPattern(self.startPattern), forKey: .startPattern)
        try container.encode(SignpostPattern(self.endPattern), forKey: .endPattern)

        for col in self.columns where col.notHidden {
            try container.encode(col, forKey: .column)
        }
    }
}

struct SignpostPattern: Encodable {
    var message: String

    init(_ message: StaticString) {
        var res: String = "\""
        res.reserveCapacity(message.utf8CodeUnitCount)

        let parts = "\(message)".split(separator: ";")
        for part in parts {
            if part.contains(":") {
                let pp = part.split(separator: ":")
                let p1 = pp.first!
                // let p2 = pp.dropFirst().first!
                res += ";\(p1):\" ?\(p1) \""
            } else {
                res += "\(part)"
            }
        }
        if res.hasSuffix(" \"") {
            res = "\(res.dropLast(2))"
        }
        if !res.contains(";") {
            res += "\""
        }

        self.message = res
    }
}

extension PackageDefinition.OSSignpostPointSchema: Encodable {
    enum CodingKeys: CodingKey {
        case id
        case title
        case required
        case note
        case attribute

        case subsystem
        case category
        case name

        case pattern

        case column
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.title, forKey: .title)
        if let required = self.required {
            try container.encode(required, forKey: .required)
        }
        try container.encode(self.note, forKey: .note)
        if let attribute = self.attribute {
            try container.encode(attribute, forKey: .attribute)
        }
        try container.encode("\"\(self.subsystem)\"", forKey: .subsystem)
        try container.encode("\"\(self.category)\"", forKey: .category)
        try container.encode("\"\(self.name)\"", forKey: .name)
        try container.encode(SignpostPattern(self.pattern), forKey: .pattern)

        for col in self.columns where col.notHidden {
            try container.encode(col, forKey: .column)
        }
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
        case beta

        case importParameters = "import-parameter"
        case createParameters = "create-parameter"
        case createTables = "create-table"

        case graphs = "graph"
        case lists = "list"
        case aggregations = "aggregation"
        case narratives = "narrative"
        case engineeringTypeTrack = "engineering-type-track"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encodeIfPresent(self.version, forKey: .version)
        try container.encode(self.title, forKey: .title)
        try container.encode(self.category.rawValue, forKey: .category)
        try container.encode(self.purpose, forKey: .purpose)
        try container.encode(self.icon.rawValue, forKey: .icon)

        try container.encode(self.importParameters, forKey: .importParameters)
        try container.encode(self.createParameters, forKey: .createParameters)

        try container.encode(self.createTables, forKey: .createTables)

        try container.encode(self.graphs, forKey: .graphs)
        try container.encode(self.lists, forKey: .lists)
        try container.encode(self.aggregations, forKey: .aggregations)
        try container.encode(self.narratives, forKey: .narratives)
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
        case aggregation
        case narrative
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
        case .aggregation(let element):
            try container.encode(element, forKey: .aggregation)
        case .narrative(let element):
            try container.encode(element, forKey: .narrative)

        case .fragment(let elements):
            fatalError("can't encode elements: \(elements)")
        }
    }
}

extension PackageDefinition.Instrument.TableRef {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.id)
    }
}

extension PackageDefinition.Instrument.ImportParameter {
    public enum CodingKeys: String, CodingKey {
        case fromScope = "from-scope"
        case name
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.fromScope, forKey: .fromScope)
        try container.encode(self.name, forKey: .name)
    }

}

extension PackageDefinition.Instrument.CreateTable {
    public enum CodingKeys: String, CodingKey {
        case id
        case schemaRef = "schema-ref"
        case attribute
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.schemaRef, forKey: .schemaRef)
        for a in self.attributes {
            try container.encode(a, forKey: .attribute)
        }
    }
}

extension TableAttribute {
    public enum CodingKeys: String, CodingKey {
        case name
        case array
        case parameterRef = "parameter-ref"
        case boolean
        case integer
        case string
    }

    public enum ArrayCodingKeys: String, CodingKey {
        case integer
        case string
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.name, forKey: .name)
        switch self.value {
        case .bool(let value):
            let v = value ? "true" : "false"
            try container.encode(v, forKey: .boolean)
        case .int(let int):
            try container.encode(int, forKey: .integer)
        case .string(let string):
            try container.encode(string, forKey: .string)
        case .arrayInt(let ints):
            var valuesContainer = container.nestedContainer(keyedBy: ArrayCodingKeys.self, forKey: .array)
            for int in ints {
                try valuesContainer.encode(int, forKey: .integer)
            }
        case .arrayString(let strings):
            var valuesContainer = container.nestedContainer(keyedBy: ArrayCodingKeys.self, forKey: .array)
            for s in strings {
                try valuesContainer.encode(s, forKey: .string)
            }
        }
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
        try container.encodeIfPresent(self.purpose, forKey: .purpose)
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

        case plot
        case plotTemplates = "plot-template"
        case histograms = "histogram"
        case histogramsTemplates = "histogram-template"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.title, forKey: .title)
        try container.encode(self.tableRef, forKey: .tableRef)
        try container.encodeIfPresent(self.guide, forKey: .guide)
        try container.encodeIfPresent(self.baseColor, forKey: .baseColor)

        try self.plots.forEach { try container.encode($0, forKey: .plot) }
        try self.plotTemplates.forEach { try container.encode($0, forKey: .plotTemplates) }
         try self.histograms.forEach { try container.encode($0, forKey: .histograms)}
        // try self.histogramsTemplates.forEach { try container.encode($0, forKey: .histogramsTemplates)} // TODO: implement this
    }
}

extension PackageDefinition.Instrument.Graph.Plot {
    public enum CodingKeys: String, CodingKey {
        case slice
        case valueFrom = "value-from"
        case colorFrom = "color-from"
        case priorityFrom = "priority-from"
        case labelFrom = "label-from"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(valueFrom, forKey: .valueFrom)
        try container.encodeIfPresent(self.colorFrom, forKey: .colorFrom)
        try container.encodeIfPresent(self.labelFrom, forKey: .labelFrom)
        // TODO: all others...
    }
}

extension PackageDefinition.Instrument.Graph.Histogram {
    public enum CodingKeys: String, CodingKey {
        case slice
        // case bestForResolution = "best-for-resolution"
        case nanosecondsPerBucket = "nanoseconds-per-bucket"

        case chooseAny = "choose-any"
        case chooseUnique = "choose-unique"
        case count
        case sum
        case min
        case max
        case average
        case standardDeviation = "std-dev"
        case range
        case percentOfCapacity = "percent-of-capacity"

        case peerGroup = "peer-group"
        case ignorePeerGroup = "ignore-peer-group"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        for slice in self.slice {
            try container.encode(slice, forKey: .slice)
        }

        try container.encode(self.nanosecondsPerBucket, forKey: .nanosecondsPerBucket)

        switch self.mode {
        case .chooseAny(let column):
            try container.encode(column.mnemonic.name, forKey: .chooseAny)
        case .chooseUnique(let column):
            try container.encode(column.mnemonic.name, forKey: .chooseUnique)
        case .count(let column):
            try container.encode(column.mnemonic.name, forKey: .count)
        case .sum(let column):
            try container.encode(column.mnemonic.name, forKey: .sum)
        case .min(let column):
            try container.encode(column.mnemonic.name, forKey: .min)
        case .max(let column):
            try container.encode(column.mnemonic.name, forKey: .max)
        case .average(let column):
            try container.encode(column.mnemonic.name, forKey: .average)
        case .standardDeviation(let column):
            try container.encode(column.mnemonic.name, forKey: .standardDeviation)
        case .range(let column):
            try container.encode(column.mnemonic.name, forKey: .range)
        case .percentOfCapacity(let column):
            try container.encode(column.mnemonic.name, forKey: .percentOfCapacity)
        }

        // TODO: all others
    }
}

extension PackageDefinition.Instrument.Graph.PlotTemplate {
    public enum CodingKeys: String, CodingKey {
        case instanceBy = "instance-by"
        case labelFormat = "label-format"
        case slice
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
        try container.encodeIfPresent(self.labelFormat, forKey: .labelFormat)
        try container.encode(valueFrom, forKey: .valueFrom)
        try container.encodeIfPresent(self.colorFrom, forKey: .colorFrom)
        try container.encodeIfPresent(self.labelFrom, forKey: .labelFrom)
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
        case histogram
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .plot(let element):
            try container.encode(element, forKey: .plot)
        case .plotTemplate(let element):
            try container.encode(element, forKey: .plotTemplate)
        case .histogram(let element):
            try container.encode(element, forKey: .histogram)

        case .fragment(let elements):
            fatalError("can't encode elements: \(elements)")
        }
    }
}

extension PackageDefinition.Instrument.List {
    public enum CodingKeys: String, CodingKey {
        case title
        case tableRef = "table-ref"
        case slice
        case columns = "column"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(self.title, forKey: .title)
        try container.encode(self.tableRef, forKey: .tableRef)
        try container.encodeIfPresent(self.slice, forKey: .slice)
        try container.encode(self.columns, forKey: .columns)
    }
}

extension PackageDefinition.Instrument.Slice {
    public enum CodingKeys: String, CodingKey {
        case when
        case column
        case equals
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        var whenContainer = container.nestedUnkeyedContainer(forKey: .when)
        for w in self.when {
            try whenContainer.encode(w)
        }

        try container.encode(self.column.asMnemonic(), forKey: .column)

        var equalsContainer = container.nestedContainer(keyedBy: EngineeringType.self, forKey: .equals)
        for e in self.equals {
            try equalsContainer.encode(e, forKey: self.column.type)
        }
    }
}

extension PackageDefinition.Instrument.Slice.When {
    public enum CodingKeys: String, CodingKey {
        case parameterIsTrue = "parameter-is-true"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .parameterIsTrue(let parameter):
            try container.encode(parameter.mnemonicString(), forKey: .parameterIsTrue)
        }
    }
}

extension PackageDefinition.Instrument.Narrative {
    public enum CodingKeys: String, CodingKey {
        case title
        case tableRef = "table-ref"
        case guide
        case visitOnFocus = "visit-on-focus"
        case emptyContentSuggestion = "empty-content-suggestion"
        case narrativeColumn = "narrative-column"
        case annotationColumns = "annotation-column"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encodeIfPresent(self.title, forKey: .title)
        try container.encode(self.tableRef, forKey: .tableRef)
        // try container.encodeIfPresent(self.guide, forKey: .guide)
        try container.encodeIfPresent(self.visitOnFocus, forKey: .visitOnFocus)
        // try container.encodeIfPresent(self.emptyContentSuggestion, forKey: .emptyContentSuggestion)
        try container.encode(self.narrativeColumn, forKey: .narrativeColumn)
        try container.encode(self.annotationColumns, forKey: .annotationColumns)
    }
}

extension PackageDefinition.Instrument.Aggregation {
    public enum CodingKeys: String, CodingKey {
        case title
        case tableRef = "table-ref"
        case slice
        case emptyContentSuggestion = "empty-content-suggestion"
        case guide
        case hierarchy
        case visitOnFocus = "visit-on-focus"
        case graphsOnLane = "graph-on-lane"
        case columns = "column"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(self.title, forKey: .title)
        try container.encode(self.tableRef, forKey: .tableRef)
        try container.encodeIfPresent(self.hierarchy, forKey: .hierarchy)
        try container.encodeIfPresent(self.emptyContentSuggestion, forKey: .emptyContentSuggestion)
        try container.encodeIfPresent(self.visitOnFocus, forKey: .visitOnFocus)
        try container.encode(self.columns, forKey: .columns) // TODO: render them specially, just the names
        try container.encode(self.columnsHidden, forKey: .columns)
    }
}

extension PackageDefinition.Instrument.Aggregation.AggregationColumn {
    public enum CodingKeys: String, CodingKey {
        case chooseAny = "choose-any"
        case chooseUnique = "choose-unique"
        case count
        case sum
        case min
        case max
        case average
        case stdDev = "std-dev"
        case range
        case percentOfCapacity = "percent-of-capacity"

        case title
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .chooseAny(let title, let column):
            try container.encodeIfPresent(title, forKey: .title)
            try container.encode(column.mnemonic.name, forKey: .chooseAny)
        case .chooseUnique(let title, let column):
            try container.encodeIfPresent(title, forKey: .title)
            try container.encode(column.mnemonic.name, forKey: .chooseUnique)
        case .count0(let title):
            try container.encodeIfPresent(title, forKey: .title)
            try container.encode("", forKey: .count) // <count/>
        case .count(let title, let column):
            try container.encodeIfPresent(title, forKey: .title)
            try container.encode(column.mnemonic.name, forKey: .count)
        case .sum(let title, let column):
            try container.encodeIfPresent(title, forKey: .title)
            try container.encode(column.mnemonic.name, forKey: .sum)
        case .min(let title, let column):
            try container.encodeIfPresent(title, forKey: .title)
            try container.encode(column.mnemonic.name, forKey: .min)
        case .max(let title, let column):
            try container.encodeIfPresent(title, forKey: .title)
            try container.encode(column.mnemonic.name, forKey: .max)
        case .average(let title, let column):
            try container.encodeIfPresent(title, forKey: .title)
            try container.encode(column.mnemonic.name, forKey: .average)
        case .stdDev(let title, let column):
            try container.encodeIfPresent(title, forKey: .title)
            try container.encode(column.mnemonic.name, forKey: .stdDev)
        case .range(let title, let column):
            try container.encodeIfPresent(title, forKey: .title)
            try container.encode(column.mnemonic.name, forKey: .range)
        case .percentOfCapacity(let title, let column):
            try container.encodeIfPresent(title, forKey: .title)
            try container.encode(column.mnemonic.name, forKey: .percentOfCapacity)
        }
    }
}

extension PackageDefinition.Instrument.Aggregation.AggregationHierarchy {
    public enum CodingKeys: String, CodingKey {
        case level
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.levels, forKey: .level)
    }
}

extension PackageDefinition.Instrument.Aggregation.AggregationHierarchy.Level {
    public enum CodingKeys: String, CodingKey {
        case column
        case processOfThread = "process-of-thread"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .column(let column):
            try container.encode(column.mnemonic.name, forKey: .column)
        case .processOfThread(let string):
            try container.encode(string, forKey: .processOfThread)
        }
    }
}

extension PackageDefinition.Instrument.VisitOnFocus {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.detailViewTitle)
    }
}

extension PackageDefinition.Instrument.EngineeringTypeTrack {
    public enum CodingKeys: String, CodingKey {
        case tableRef = "table-ref"
        case hierarchy
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.tableRef, forKey: .tableRef)
        try container.encode(self.hierarchy, forKey: .hierarchy)
    }
}

extension PackageDefinition.Instrument.EngineeringTypeTrack.Hierarchy {
    public enum CodingKeys: String, CodingKey {
        case levels = "level"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.levels, forKey: .levels)
    }
}

extension PackageDefinition.Instrument.EngineeringTypeTrack.Hierarchy.Level {
    public enum CodingKeys: String, CodingKey {
        case _self = "self"
        case column
        case typePriority = "type-priority"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self.type {
        case .self:
            try container.encode("", forKey: ._self)
        case .column(let column):
            try container.encode(column.mnemonic.name, forKey: .column)
        }
        try container.encodeIfPresent(self.typePriority, forKey: .typePriority)
    }
}

extension PackageDefinition.Instrument.SchemaRef {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.schemaRefString)
    }
}

extension PackageDefinition.Template {
    public enum CodingKeys: String, CodingKey {
        case importFromFile = "import-from-file"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.importFromFile, forKey: .importFromFile)
    }
}

#endif
