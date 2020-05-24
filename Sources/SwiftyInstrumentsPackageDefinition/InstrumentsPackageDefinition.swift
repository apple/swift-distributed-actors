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

import Foundation

public typealias Instrument = PackageDefinition.Instrument
public typealias Graph = PackageDefinition.Instrument.Graph
public typealias List = PackageDefinition.Instrument.List
public typealias Aggregation = PackageDefinition.Instrument.Aggregation

public typealias Template = PackageDefinition.Template
public typealias Augmentation = PackageDefinition.Augmentation
public typealias Modeler = PackageDefinition.Modeler

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: PackageDefinition

/// Corresponds to an Instruments.app PackageDefinition, as defined in:
/// https://help.apple.com/instruments/developer/mac/current/#/dev13041708
///
/// Used to construct using plain, reusable, Swift instrument package definitions.
///
// TODO: This is work in progress and may be missing elements still
public struct PackageDefinition: Encodable {
    var id: String
    var version: String

    var title: String

    var owner: Owner?

    var schemas: [Schema]

    var augmentations: [Augmentation]

    var instruments: [Instrument]

    public init(
        id: String,
        version: String,
        title: String,
        owner: Owner? = nil,
        @PackageDefinitionBuilder _ builder: () -> PackageElementConvertible = { PackageElement.fragment([]) }
    ) {
        self.id = id
        self.version = version
        self.title = title
        self.owner = owner

        self.schemas = []
        self.augmentations = []
        self.instruments = []

        self.collect(builder())
    }

    mutating func collect(_ element: PackageElementConvertible) {
        switch element.asPackageElement() {
        case .schema(let schema):
            self.schemas.append(schema)
        case .instrument(let instrument):
            self.instruments.append(instrument)
        case .template:
            fatalError() // FIXME:

        case .fragment(let elements):
            elements.forEach { el in
                self.collect(el)
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Schema

public protocol Schema: Encodable {
    /// A unique mnemonic that will identify this schema.
    var id: Mnemonic { get set }
    /// A title that should be displayed for this schema in a user interface.
    var title: String { get set }
    var required: Bool? { get set }
    /// A note that can be extracted for user's guide documentation
    var note: String? { get set }

    var attribute: SchemaAttribute? { get set }

    var subsystem: String { get set }
    var category: String { get set }
    var name: String { get set }
}

extension Schema {
    public func createTable() -> PackageDefinition.Instrument.CreateTable {
        .init(self)
    }
}

public typealias EventPattern = StaticString
public typealias StartPattern = StaticString
public typealias EndPattern = StaticString

extension PackageDefinition {
    public struct OSSignpostIntervalSchema: Schema, PackageElementConvertible {
        public var id: Mnemonic
        public var title: String
        public var required: Bool?
        public var note: String?

        public var attribute: SchemaAttribute?

        public var subsystem: String
        public var category: String
        public var name: String

        public var startPattern: StartPattern
        public var endPattern: EndPattern

        public var columns: [Column]

        // TODO: workaround for https://bugs.swift.org/browse/SR-11628
        public init(
            id: Mnemonic,
            title: String,
            required: Bool? = nil,
            note: String? = nil,
            attribute: SchemaAttribute? = nil,
            subsystem: String,
            category: String,
            name: String,
            startPattern: StartPattern,
            endPattern: EndPattern,
            element: SchemaElement
        ) {
            self.init(
                id: id,
                title: title,
                required: required,
                note: note,
                attribute: attribute,
                subsystem: subsystem,
                category: category,
                name: name,
                startPattern: startPattern,
                endPattern: endPattern,
                builder: { () in element }
            )
        }

        public init(
            id: Mnemonic,
            title: String,
            required: Bool? = nil,
            note: String? = nil,
            attribute: SchemaAttribute? = nil,
            subsystem: String,
            category: String,
            name: String,
            startPattern: StartPattern,
            endPattern: EndPattern,
            @SchemaBuilder builder: () -> SchemaElementConvertible
        ) {
            self.id = id
            self.title = title
            self.required = required
            self.note = note
            self.attribute = attribute
            self.subsystem = subsystem
            self.category = category
            self.name = name
            self.startPattern = startPattern
            self.endPattern = endPattern
            self.columns = []
            self.collect(builder())
        }

        private mutating func collect(_ element: SchemaElementConvertible) {
            switch element.asSchemaElement() {
            case .column(let column):
                self.columns.append(column)
            case .fragment(let fragments):
                for f in fragments {
                    self.collect(f)
                }
            }
        }

        public func validate() throws {
            // TODO: implement validation
//            for col in self.columns {
//                for mnemonic in col.expression.referencedMnemonics {
//
//                }
//            }
        }

        public func asPackageElement() -> PackageElement {
            .schema(self)
        }
    }

    public struct OSSignpostPointSchema: Schema, PackageElementConvertible {
        public var id: Mnemonic
        public var title: String
        public var required: Bool?
        public var note: String?

        public var attribute: SchemaAttribute?

        public var subsystem: String
        public var category: String
        public var name: String

        public var pattern: EventPattern

        public var columns: [Column]

        // TODO: workaround for https://bugs.swift.org/browse/SR-11628
        public init(
            id: Mnemonic,
            title: String,
            required: Bool? = nil,
            note: String? = nil,
            attribute: SchemaAttribute? = nil,
            subsystem: String,
            category: String,
            name: String,
            pattern: EventPattern,
            element: SchemaElement
        ) {
            self.init(
                id: id,
                title: title,
                required: required,
                note: note,
                attribute: attribute,
                subsystem: subsystem,
                category: category,
                name: name,
                pattern: pattern,
                builder: { () in element }
            )
        }

        public init(
            id: Mnemonic,
            title: String,
            required: Bool? = nil,
            note: String? = nil,
            attribute: SchemaAttribute? = nil,
            subsystem: String,
            category: String,
            name: String,
            pattern: EventPattern,
            @SchemaBuilder builder: () -> SchemaElementConvertible = { () in SchemaElement.fragment([]) }
        ) {
            self.id = id
            self.title = title
            self.required = required
            self.note = note
            self.subsystem = subsystem
            self.category = category
            self.name = name
            precondition(!"\(pattern)".contains("\n"), "Pattern [\(pattern)] in schema [\(id)] contained illegal newlines!")
            self.pattern = pattern
            self.columns = []
            self.collect(builder())
        }

        private mutating func collect(_ element: SchemaElementConvertible) {
            switch element.asSchemaElement() {
            case .column(let column):
                self.columns.append(column)
            case .fragment(let fragments):
                for f in fragments {
                    self.collect(f)
                }
            }
        }

        public func validate() throws {
            // TODO: implement validation
//            for col in self.columns {
//                col.expression.referencedMnemonics
//            }
        }

        public func asPackageElement() -> PackageElement {
            .schema(self)
        }
    }
}

extension PackageDefinition.OSSignpostIntervalSchema: Encodable {
    enum CodingKeys: CodingKey {
        case id
        case title
        case required
        case note
        case attribute

        case subsystem
        case category
        case name

        case startPattern
        case endPattern

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
        try container.encode(self.subsystem, forKey: .subsystem)
        try container.encode(self.category, forKey: .category)
        try container.encode(self.name, forKey: .name)
        try container.encode(self.startPattern, forKey: .startPattern)
        try container.encode(self.endPattern, forKey: .endPattern)

        for col in self.columns {
            try container.encode(col, forKey: .column)
        }
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
        try container.encode(self.subsystem, forKey: .subsystem)
        try container.encode(self.category, forKey: .category)
        try container.encode(self.name, forKey: .name)
        try container.encode(self.pattern, forKey: .pattern)

        for col in self.columns {
            try container.encode(col, forKey: .column)
        }
    }
}

public struct Owner: Encodable, PackageElementConvertible {
    public var name: String
    public var email: String

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }

    public func asPackageElement() -> PackageElement {
        fatalError("asPackageElement() has not been implemented")
    }
}

public struct Mnemonic: Encodable, ExpressibleByStringLiteral {
    public let name: String

    public init(stringLiteral value: StringLiteralType) {
        if value.starts(with: "?") {
            fatalError("Mnemonic values should not start with ?, this is prepended automatically.")
        }

        // FIXME: validate what it can look like

        self.name = value
    }

    public init(raw: String) {
        if raw.starts(with: "?") {
            self.name = "\(raw.dropFirst())"
        } else {
            self.name = raw
        }
    }

    func render() -> String {
        "?\(self.name)"
    }
}

extension String: MnemonicConvertible {
    public func asMnemonic() -> Mnemonic {
        .init(stringLiteral: self)
    }
}

public struct ClipsExpression: Encodable, ExpressibleByStringLiteral {
    // TODO: String interpolation
    public let expression: String

    public init(stringLiteral value: StringLiteralType) {
        self.init(expression: value)
    }

    public init(expression: String) {
        self.expression = expression
    }

    public static func mnemonic(_ mnemonic: MnemonicConvertible) -> ClipsExpression {
        .init(expression: mnemonic.asMnemonic().render())
    }

    public var referencedMnemonics: [Mnemonic] {
        var mnemonics: [Mnemonic] = []
        var remaining = self.expression[...]
        while let idx = remaining.firstIndex(of: "?") {
            remaining = remaining[idx...]
            let to = remaining.firstIndex(of: " ") ?? remaining.endIndex
            mnemonics.append(Mnemonic(raw: String(remaining[idx ... to])))
            remaining = remaining[to...]
        }

        return mnemonics
    }
}

public struct SchemaAttribute: Encodable {
    var name: String
    var required: Bool
    var note: String
    var valuePattern: String
}

public struct Column: Encodable, SchemaElementConvertible, MnemonicConvertible {
    public let mnemonic: Mnemonic
    public let title: String
    /// The type of data this column will hold.
    public let type: EngineeringType
    public let guide: String? = nil
    /// Defines how to map an integer expression to a string value.
    // public let `enum`: ColumnEnum
    /// An expression in the CLIPS language that will become the value of this column.
    public let expression: ClipsExpression

    public init(
        mnemonic: Mnemonic,
        title: String,
        type: EngineeringType,
        guide: String? = nil,
        expression: ClipsExpression
    ) {
        self.mnemonic = mnemonic
        self.title = title
        self.type = type
        self.expression = expression
    }

    public func asSchemaElement() -> SchemaElement {
        .column(self)
    }

    public func asMnemonic() -> Mnemonic {
        self.mnemonic
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Augmentation

extension PackageDefinition {
    public struct Augmentation: Encodable, PackageElementConvertible {
        public func asPackageElement() -> PackageElement {
            fatalError() // FIXME:
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Template

extension PackageDefinition {
    public struct Template: Encodable, PackageElementConvertible {
        var importFromFile: String

        public func asPackageElement() -> PackageElement {
            fatalError() // FIXME:
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Instrument

extension PackageDefinition {
    /// Defines an instrument that appears in the Instruments library.
    public struct Instrument: Encodable, PackageElementConvertible {
        // A unique id in reverse DNS notation that globally identifies your instrument.
        public var id: String
        /// A version number that helps Instruments resolve conflicts.
        /// Higher versions overwrite lower versions.
        public var version: UInt
        /// Descriptive title that will appear in the Instruments library.
        public var title: String
        public var category: String
        public var purpose: String
        public var icon: String // TODO: enum?

        /// Declares the name of a parameter that can be used in table definitions.
        public var importParameters: [Instrument.ImportParameter]

        /// Creates a parameter specific to this instrument.
        /// Parameters show up in the UI and command line as recording options.
        public var createParameters: [Instrument.CreateParameter]
        //    <name>?includeSystemActors</name>
        //    <boolean-value>
        //    <true-choice>Show /system Actors</true-choice>
        //    </boolean-value>

        /// Tells the instrument, when it's added to a trace document, to create a named data table.
        public var createTables: [Instrument.CreateTable]
        //    <id>actor-lifecycle-intervals</id>
        //    <schema-ref>actor-lifecycle-interval</schema-ref>
        //
        //    <attribute>
        //    <name>include-system-actors</name>
        //    <parameter-ref>?includeSystemActors</parameter-ref>
        //    </attribute>
        //
        //    </create-table>
        //    <create-table>
        //    <id>actor-lifecycle-spawns</id>
        //    <schema-ref>actor-lifecycle-spawn</schema-ref>
        //    </create-table>

        /// Defines the graph, or track, that the instrument will present.
        ///
        /// There can be several.
        public var graphs: [Instrument.Graph]

        /// Defines the list, or track, that the instrument will present.
        ///
        /// There can be several.
        public var lists: [Instrument.List]

        /// Creates an aggregate view (e.g. summary with totals and averages) in the detail area.
        public var aggregations: [Instrument.Aggregation]

        /// Defines engineering type data track data source.
        /// When this Instrument is present in the trace document,
        /// this data source is queried and matching engineering type tracks are created.
        public var engineeringTypeTracks: [EngineeringTypeTrack]

        public init(
            id: String,
            version: UInt = 1,
            title: String,
            category: String,
            purpose: String,
            icon: String,
            @InstrumentBuilder _ builder: () -> InstrumentElementConvertible = { InstrumentElement.fragment([]) }
        ) {
            self.id = id
            self.version = version
            self.title = title
            self.category = category
            self.purpose = purpose
            self.icon = icon

            self.importParameters = []
            self.createParameters = []
            self.createTables = []

            self.graphs = []
            self.lists = []
            self.aggregations = []
            self.engineeringTypeTracks = []

            self.collect(builder())
        }

        mutating func collect(_ element: InstrumentElementConvertible) {
            switch element.asInstrumentElement() {
            case .importParameter(let element):
                self.importParameters.append(element)
            case .createParameter(let element):
                self.createParameters.append(element)
            case .createTable(let element):
                self.createTables.append(element)
            case .engineeringTypeTrack(let element):
                self.engineeringTypeTracks.append(element)

            case .graph(let element):
                self.graphs.append(element)
            case .list(let element):
                self.lists.append(element)
            case .aggregation(let element):
                self.aggregations.append(element)

            case .fragment(let elements):
                elements.forEach { el in
                    self.collect(el)
                }
            }
        }

        public func asPackageElement() -> PackageElement {
            .instrument(self)
        }
    }
}

extension PackageDefinition.Instrument {
    public struct ImportParameter: Encodable, InstrumentElementConvertible {
        var fromScope: String // TODO: enum?
        var name: Mnemonic

        public init(fromScope: String, name: MnemonicConvertible) {
            self.fromScope = fromScope
            self.name = name.asMnemonic()
        }

        public func asInstrumentElement() -> InstrumentElement {
            .importParameter(self)
        }
    }

    public struct CreateParameter: Encodable, InstrumentElementConvertible {
        public func asInstrumentElement() -> InstrumentElement {
            .createParameter(self)
        }
    }

    public enum SchemaRef: Encodable {
        case schema(Schema)
        case id(String)

        public var schemaRefString: String {
            switch self {
            case .schema(let schema):
                return schema.id.name
            case .id(let id):
                return id
            }
        }
    }

    public struct CreateTable: Encodable, InstrumentElementConvertible {
        public var id: String
        public var schemaRef: SchemaRef
        public var attributes: [TableAttribute] = []

        public init(
            _ schema: Schema,
            @TableAttributesBuilder _ builder: () -> TableAttributeElementConvertible = { () in TableAttributeElement.fragment([]) }
        ) {
            self.id = "\(schema.id.name)-table"
            self.schemaRef = .schema(schema)
            self.gather(builder())
        }

        private mutating func gather(_ element: TableAttributeElementConvertible) {
            switch element.asTableAttributeElement() {
            case .attribute(let element):
                self.attributes.append(element)
            case .fragment(let fragments):
                for f in fragments {
                    self.gather(f)
                }
            }
        }

        public func asInstrumentElement() -> InstrumentElement {
            .createTable(self)
        }
    }

    public struct EngineeringTypeTrack: Encodable, InstrumentElementConvertible {
        public func asInstrumentElement() -> InstrumentElement {
            .engineeringTypeTrack(self)
        }
    }

    /// Defines the graph, or track, that the instrument will present.
    public struct Graph: Encodable, InstrumentElementConvertible {
        public var title: String
        public var purpose: String?

        public var lanes: [Lane] = []
        public var laneTemplates: [LaneTemplate] = []

        public init(
            title: String,
            purpose: String? = nil,
            @GraphBuilder _ builder: () -> GraphElementConvertible = { GraphElement.fragment([]) }
        ) {
            self.title = title
            self.purpose = purpose
            self.collect(builder())
        }

        private mutating func collect(_ element: GraphElementConvertible) {
            switch element.asGraphElement() {
            case .lane(let lane):
                self.lanes.append(lane)
            case .laneTemplate(let template):
                self.laneTemplates.append(template)
            case .fragment(let fragments):
                for f in fragments {
                    self.collect(f)
                }
            }
        }

        public func asInstrumentElement() -> InstrumentElement {
            .graph(self)
        }

        // ==== --------------------------------------------------------------------------------------------------------
        // MARK: Graph Elements

        /// Graphs are laid out vertically into 1 or more lanes.
        ///
        /// - Renders as `<lane/>` element.
        /// - SeeAlso: https://help.apple.com/instruments/developer/mac/current/#/dev170852594
        public struct Lane: Encodable, GraphElementConvertible {
            /// Describes the data that will be seen in this lane.
            public var title: String
            /// The data table that this lane reads from.
            public var tableRef: TableRef

            /// A note that documentation tools may extract when creating a user's guide.
            public var guide: String?

            /// The color that should be used when no explicit color is implied by the data.
            public var baseColor: String?

            // public var elements: [GraphLaneElement] = []
            public var plots: [PackageDefinition.Instrument.Graph.Plot] = []
            public var plotTemplates: [PackageDefinition.Instrument.Graph.PlotTemplate] = []
            // public var histograms: [PackageDefinition.Instrument.Graph.Histogram] = []
            // public var histogramTemplates: [PackageDefinition.Instrument.Graph.HistogramTemplate] = []

            public init(
                title: String,
                table: PackageDefinition.Instrument.CreateTable,
                guide: String? = nil,
                baseColor: String? = nil,
                @GraphLaneBuilder _ builder: () -> GraphLaneElementConvertible = { GraphLaneElement.fragment([]) }
            ) {
                self.title = title
                self.tableRef = .init(table)

                self.guide = guide
                self.baseColor = baseColor
                self.collect(builder())
            }

            private mutating func collect(_ element: GraphLaneElementConvertible) {
                switch element.asGraphLaneElement() {
                case .plot(let plot):
                    self.plots.append(plot)
                case .plotTemplate(let template):
                    self.plotTemplates.append(template)
                case .fragment(let fragments):
                    for f in fragments {
                        self.collect(f)
                    }
                }
            }

            public func asGraphElement() -> GraphElement {
                .lane(self)
            }
        }

        /// For elements that are not automatically graphed.
        /// This is used to graph aggregate rows and should be referenced by graph-on-lane elements inside an aggregation definition.
        ///
        /// - Renders as `<lane-template>` element.
        /// - SeeAlso: https://help.apple.com/instruments/developer/mac/current/#/dev358941033
        public struct LaneTemplate: Encodable, GraphElementConvertible {
            /// Describes the data that will be seen in this lane.
            public var title: String
            /// The data table that this lane reads from.
            public var tableRef: TableRef

            /// A note that documentation tools may extract when creating a user's guide.
            public var guide: String?

            /// The color that should be used when no explicit color is implied by the data.
            public var baseColor: String?

            public var elements: [GraphLaneElement] = []

            public init(
                title: String,
                table: PackageDefinition.Instrument.CreateTable,
                guide: String? = nil,
                baseColor: String? = nil,
                @GraphLaneBuilder _ builder: () -> GraphLaneElementConvertible = { GraphLaneElement.fragment([]) }
            ) {
                self.title = title
                self.tableRef = .init(table)

                self.guide = guide
                self.baseColor = baseColor
                self.collect(builder())
            }

            private mutating func collect(_ element: GraphLaneElementConvertible) {
                switch element.asGraphLaneElement() {
                case .plot(let element):
                    self.elements.append(.plot(element)) // TODO: keep like that or store in separate collections like elsewhere?
                case .plotTemplate(let element):
                    self.elements.append(.plotTemplate(element)) // TODO: keep like that or store in separate collections like elsewhere?
                case .fragment(let fragments):
                    for f in fragments {
                        self.collect(f)
                    }
                }
            }

            public func asGraphElement() -> GraphElement {
                .laneTemplate(self)
            }
        }

        /// Plots a single value for the lane.
        ///
        /// - SeeAlso: https://help.apple.com/instruments/developer/mac/current/#/dev326238583
        public struct Plot: Encodable, GraphLaneElementConvertible {
            // public var slice* // TODO:

            // public var best-for-resolution{0, 3} // TODO:

            /// The column where the value of the graph will be pulled.
            public var valueFrom: Mnemonic

            // public var color-from? // TODO:

            // public var priority-from? // TODO:

            /// The column where the label text on hover-over should be pulled.
            public var labelFrom: Mnemonic?

            // public var (qualified-by | disable-implicit-qualifier)?

            // public var qualifier-treatment* // TODO:

            // public var containment-level-from? // TODO:

            // public var (peer-group | ignore-peer-group)? // TODO:

            public init(
                valueFrom: MnemonicConvertible,
                labelFrom: MnemonicConvertible? = nil
            ) {
                self.valueFrom = valueFrom.asMnemonic()
                self.labelFrom = labelFrom?.asMnemonic()
            }

            public func asGraphLaneElement() -> GraphLaneElement {
                .plot(self)
            }
        }

        /// Like "plot", except it will automatically create slices for each value in "instance-by".
        public struct PlotTemplate: Encodable, GraphLaneElementConvertible {
            /// The column which will create a new instance of this plot template, for each unique value.
            public var instanceBy: Mnemonic

            /// Each instance of the plot can have a different label, where %s is the string value of the instance-by column's value.
            public var labelFormat: String?

            // slice*,

            // best-for-resolution{0, 3},

            /// The column where the value of the graph will be pulled.
            public var valueFrom: Mnemonic

            /// Determine the color based on this column rather than value-from's column.

            public var colorFrom: Mnemonic?
            // priority-from?,

            /// The column where the label text on hover-over should be pulled.
            public var labelFrom: Mnemonic?

            // (qualified-by | disable-implicit-qualifier)?

            // qualifier-treatment*,

            // containment-level-from?,

            // (peer-group | ignore-peer-group)?

            public init(
                instanceBy: MnemonicConvertible,
                labelFormat: String? = nil,
                valueFrom: MnemonicConvertible,
                colorFrom: MnemonicConvertible? = nil,
                labelFrom: MnemonicConvertible? = nil
            ) {
                self.instanceBy = instanceBy.asMnemonic()
                self.labelFormat = labelFormat
                self.valueFrom = valueFrom.asMnemonic()
                self.colorFrom = colorFrom?.asMnemonic()
                self.labelFrom = labelFrom?.asMnemonic()
            }

            // TODO need a lot of overloads here since any of the mnemonic convertibles may be a Column for the nice .syntax
            public init(
                instanceBy: Column,
                labelFormat: String? = nil,
                valueFrom: Column,
                colorFrom: Column? = nil,
                labelFrom: Column? = nil
            ) {
                self.instanceBy = instanceBy.asMnemonic()
                self.labelFormat = labelFormat
                self.valueFrom = valueFrom.asMnemonic()
                self.colorFrom = colorFrom?.asMnemonic()
                self.labelFrom = labelFrom?.asMnemonic()
            }

            public func asGraphLaneElement() -> GraphLaneElement {
                .plotTemplate(self)
            }
        }
    }

    public struct List: Encodable, InstrumentElementConvertible {
        public let title: String
        public let tableRef: TableRef
        public var columns: [Mnemonic]

        public init(
            title: String,
            table: PackageDefinition.Instrument.CreateTable,
            @ColumnsBuilder columns: () -> [MnemonicConvertible]
        ) {
            self.title = title
            self.tableRef = .init(table)
            self.columns = columns().map { $0.asMnemonic() }
            precondition(self.columns.count > 0, "List MUST have at least one column: \(self)")
        }

        public func asInstrumentElement() -> InstrumentElement {
            .list(self)
        }
    }

    /// Creates an aggregate view (e.g. summary with totals and averages) in the detail area.
    public struct Aggregation: Encodable, InstrumentElementConvertible {
        public var title: String
        public var tableRef: TableRef
//        public var slice*
        /// When a list is empty, this empty content suggestion helps explain why.
        ///
        /// - Example: Call kdebug_signpost() to report points of interest within your application
        public var emptyContentSuggestion: String?
//        public var guide?
        public var hierarchy: AggregationHierarchy?
        public var visitOnFocus: VisitOnFocus
//        public var graph-on-lane*
        public var columns: [AggregationColumn]
        public var columnsHidden: [Column]

        public func asInstrumentElement() -> InstrumentElement {
            .aggregation(self)
        }

        public init(
            title: String,
            table: PackageDefinition.Instrument.CreateTable,
            emptyContentSuggestion: String? = nil,
            hierarchy: AggregationHierarchy? = nil,
            visitOnFocus viewOnFocusTarget: VisitOnFocusTarget,
            columns: [AggregationColumn],
            columnsHidden: [Column] = []
        ) {
            self.title = title
            self.tableRef = TableRef(table)
            self.emptyContentSuggestion = emptyContentSuggestion
            self.hierarchy = hierarchy
            self.visitOnFocus = VisitOnFocus(viewOnFocusTarget)
            self.columns = columns
            self.columnsHidden = columnsHidden
        }

        public enum AggregationColumn: Encodable {
            case chooseAny(title: String?, Column)
            case chooseUnique(title: String?, Column)
            case count(title: String?, Column)
            case sum(title: String?, Column)
            case min(title: String?, Column)
            case max(title: String?, Column)
            case average(title: String?, Column)
            case stdDev(title: String?, Column)
            case range(title: String?, Column)
            case percentOfCapacity(title: String?, Column)

            /// Picks any value arbitrarily.
            public static func chooseAny(_ column: Column) -> AggregationColumn {
                .chooseAny(title: nil, column)
            }

            /// If all the data is the same, choose it, else choose nothing.
            public static func chooseUnique(_ column: Column) -> AggregationColumn {
                .chooseUnique(title: nil, column)
            }

            /// The number of data points in the aggregation.
            public static func count(_ column: Column) -> AggregationColumn {
                .count(title: nil, column)
            }

            /// Total the value in the column mnemonic supplied.
            public static func sum(_ column: Column) -> AggregationColumn {
                .sum(title: nil, column)
            }

            /// Minimum value in the column mnemonic supplied.
            public static func min(_ column: Column) -> AggregationColumn {
                .min(title: nil, column)
            }

            /// Maximum value in the column mnemonic supplied.
            public static func max(_ column: Column) -> AggregationColumn {
                .max(title: nil, column)
            }

            /// Average value in the column mnemonic supplied.
            public static func average(_ column: Column) -> AggregationColumn {
                .average(title: nil, column)
            }

            /// Standard deviation (quick estimate) of the value in the column mnemonic supplied.
            public static func stdDev(_ column: Column) -> AggregationColumn {
                .stdDev(title: nil, column)
            }

            /// The distance between the first point in the aggregate and the last.
            public static func range(_ column: Column) -> AggregationColumn {
                .range(title: nil, column)
            }

            /// Totals a column value, divides by the capacity constant, and multiplies by 100.
            public static func percentOfCapacity(_ column: Column) -> AggregationColumn {
                .percentOfCapacity(title: nil, column)
            }
        }
        
        /// Defines an outline-style aggregation where each level can be a different column or mapping.
        public struct AggregationHierarchy: Encodable, ExpressibleByArrayLiteral {
            public typealias ArrayLiteralElement = Level
            /// Describes each level in the hierarchy and how to roll up data from one level to the next.
            let levels: [Level]

            public init(arrayLiteral elements: Self.ArrayLiteralElement...) {
                self.levels = elements
            }


            public enum Level: Encodable {
                /// Specifies that the value of the level should just be the value at this column.
                case column(Column)
                /// Specifies that the value of the level should just be the process associated with a thread value at this column.
                case processOfThread(String)
            }
        }

        /// The title of another defined detail view, like a list, to visit when the user clicks the focus button of an aggregate.
        ///
        /// ### Example:
        /// If a `List` view titled `"Events"` exists, you can `VisitOnFocus("Events")`.
        ///
        /// The user will see a round focus button next to each row of this aggregation
        // and when they click it, the "Events" list will be pushed on to the detail
        // view, and it will be filtered to just the events that correspond with the
        // row of the aggregation being focused.  So, for example, if the events were
        // context switches, then clicking the focus button on the thread in the
        // outline view will push the list of events for that thread onto the view stack.
        public struct VisitOnFocus: Encodable, VisitOnFocusTarget, ExpressibleByStringLiteral {
            public let detailViewTitle: String

            public var title: String {
                self.detailViewTitle
            }

            public init(_ target: VisitOnFocusTarget) {
                self.detailViewTitle = target.title
            }

            public init(stringLiteral value: StringLiteralType) {
                if value.starts(with: "?") {
                    fatalError("VisitOnFocus.detailViewTitle MUST be a Title and not a mnemonic, passed in value [\(value)] starts with '?' suggesting it is a mnemonic.")
                }

                self.self.detailViewTitle = value
            }

            public init(_ detailViewTitle: String) {
                self.detailViewTitle = detailViewTitle
            }
        }
    }

    public struct TableRef: Encodable {
        var schemaRef: SchemaRef

        public init(_ table: PackageDefinition.Instrument.CreateTable) {
            self.schemaRef = table.schemaRef
        }

        public init(schema schemaRef: SchemaRef) {
            self.schemaRef = schemaRef
        }
    }
}

public protocol VisitOnFocusTarget {
    var title: String { get }
}

extension Instrument.List: VisitOnFocusTarget {}
extension Instrument.Graph: VisitOnFocusTarget {}

public enum EngineeringType: String, Codable {
    case invalid
    case rowNumber = "row-number"
    case eventCount = "event-count"
    case eventsPerSecond = "events-per-second"
    case duration
    case percent
    case systemCpuPercent = "system-cpu-percent"
    case tid
    case thread
    case threadName = "thread-name"
    case syscall
    case signpostName = "signpost-name"
    case vmOp = "vm-op"
    case kdebugCode = "kdebug-code"
    case kdebugClass = "kdebug-class"
    case kdebugSubclass = "kdebug-subclass"
    case kdebugFunc = "kdebug-func"
    case kdebugArg = "kdebug-arg"
    case startTime = "start-time"
    case eventTime = "event-time"
    case threadState = "thread-state"
    case deviceSession = "device-session"
    case pid
    case process
    case kperfBt = "kperf-bt"
    case pmcEvents = "pmc-events"
    case textAddresses = "text-addresses"
    case backtrace
    case textAddress = "text-address"
    case address
    case registerContent = "register-content"
    /// A logical CPU index. This number is typically assigned by the kernel at boot time.
    case core
    /// A logical CPU state.
    case coreState = "core-state"
    case durationOnCore = "duration-on-core"
    case durationWaiting = "duration-waiting"
    case syscallArg = "syscall-arg"
    case syscallReturn = "syscall-return"
    case schedEvent = "sched-event"
    case schedPriority = "sched-priority"
    case sizeInBytes = "size-in-bytes"
    case sizeInBytesPerSecond = "size-in-bytes-per-second"
    case networkSizeInBytes = "network-size-in-bytes"
    case networkSizeInBytesPerSecond = "network-size-in-bytes-per-second"
    case sizeInPages = "size-in-pages"
    case weight
    case narrativeText = "narrative-text"
    case narrative
    case narrativeCertainty = "narrative-certainty"
    case narrativeSignificance = "narrative-significance"
    case string
    case state
    case uint64
    case fixedDecimal = "fixed-decimal"
    case rawString = "raw-string"
    case consoleText = "console-text"
    case kdebugString = "kdebug-string"
    case clock
    case energyImpact = "energy-impact"
    case locationEvent = "location-event"
    case connectionUUID = "connection-uuid"
    case connectionUUID64 = "connection-uuid64"
    case connectionFilter = "connection-filter"
    case connectionMeta = "connection-meta"
    case visualUUIDChain = "visual-uuid-chain"
    case renderBufferDepth = "render-buffer-depth"
    case metalObjectLabel = "metal-object-label"
    case metalEncodingPara = "metal-encoding-para"
    case metalNestingLevel = "metal-nesting-level"
    case metalWorkloadPriority = "metal-workload-priority"
    case metalCommandBufferId = "metal-command-buffer-id"
    case metalEncoderId = "metal-encoder-id"
    case metalDeviceId = "metal-device-id"
    case metalCompilerRequest = "metal-compiler-request"
    case gpuDriverSubmission = "gpu-driver-submission"
    case gpuDriverSent = "gpu-driver-segment"
    case gpuDriverGPUSub = "gpu-driver-gpu-sub"
    case gpuDriverChannel = "gpu-driver-channel"
    case gpuDriverSurface = "gpu-driver-surface"
    case gpuDriverEventSource = "gpu-driver-event-source"
    case gpuDriverEvent = "gpu-driver-event"
    case gpuHardwareEngine = "gpu-hardware-engine"
    case gpuEngineState = "gpu-engine-state"
    case gpuHardwareTrace = "gpu-hardware-trace"
    case gpuPowerState = "gpu-power-state"
    case gpuHardwareEventSrc = "gpu-hardware-event-src"
    case gpuHardwareEvent = "gpu-hardware-event"
    case gpuFrameNumber = "gpu-frame-number"
    case displayedSurfacePrio = "displayed-surface-prio"
    case displayedSurfaceSwap = "displayed-surface-swap"
    case displayedSurfaceIOSurface = "displayed-surface-io-surface"
    case displayedSurfaceIOSurfaceSize = "displayed-surface-io-surface-size"
    case fps
    case bitRate = "bit-rate"
    case sizeInPts = "size-in-pts"
    case sizeInPxels = "size-in-pixels"
    case load
    case commitment
    case configId = "config-id"
    case key
    case stringValue = "string-value"
    case int64Value = "int64-value"
    case interval
    case fd
    case argSignature = "arg-signature"
    case errno
    case any
    case connectionRoute = "connection-route"
    case roiScope = "roi-scope"
    case roiKind = "roi-kind"
    case layoutId = "layout-id"
    case eventConcept = "event-concept"
    case capability
    case version
    case eventType = "event-type"
    case osSignpostIdentifier = "os-signpost-identifier"
    case formatString = "format-string"
    case subsystem
    case category
    case appPeriod = "app-period"
    case kdebugSignpostVariant = "kdebug-signpost-variant"
    case vsyncTimestamp = "vsync-timestamp"
    case sampleCount = "sample-count"
    case processUID = "process-uid"
    case processGID = "process-gid"
    case boolean
    case sampleTime = "sample-time"
    case cpuArchName = "cpu-arch-name"
    case processStatusName = "process-status-name"
    case textSymbol = "text-symbol"
    case machAbsoluteTime = "mach-absolute-time"
    case event
    case byte
    case eightByteArray = "eight-byte-array"
    case uuid
    case instrumentType = "instrument-type"
    case glassState = "glass-state"
    case machTimebaseInfoField = "mach-timebase-info-field"
    case machTimebaseInfo = "mach-timebase-info"
    case filePath = "file-path"
    case formattedLabel = "formatted-label"
    case sockaddr
    case networkProtocol = "network-protocol"
    case networkInterface = "network-interface"
    case uint32
    case dispatchQueue = "dispatch-queue"
    case dispatchWorkState = "dispatch-work-state"
    case abstractPower = "abstract-power"
    case graphicsDriverCounter = "graphics-driver-counter"
    case graphicsDriverStatistic = "graphics-driver-statistic"
    case graphicsDriverName = "graphics-driver-name"
    case timeOfDay = "time-of-day"
    case roiClass = "roi-class"
    case osLogMetadata = "os-log-metadata"
    case metadata
    case uint64Array = "uint64-array"
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Modeler

extension PackageDefinition {
    public struct Modeler {
        public var id: String
        public var title: String
        public var owner: Owner?
        public var purpose: String
        public var modeler: ProdSystemOrBuiltIn

        public var instanceParameters: [InstanceParameter]
        public var output: [Output] // TODO: at least one

        // (production-system | built-in)
        public enum ProdSystemOrBuiltIn: String, Equatable, Encodable {
            case productionSystem
            case builtIn
        }

        public struct InstanceParameter {}

        public struct Output {}
    }
}

#endif
