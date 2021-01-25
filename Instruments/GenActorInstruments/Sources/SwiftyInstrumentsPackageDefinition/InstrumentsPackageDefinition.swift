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
public typealias Narrative = PackageDefinition.Instrument.Narrative
public typealias Aggregation = PackageDefinition.Instrument.Aggregation
public typealias EngineeringTypeTrack = PackageDefinition.Instrument.EngineeringTypeTrack

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
    public var id: String
    public var version: String

    public var title: String

    public var owner: Owner?

    public var schemas: [Schema]

    public var augmentations: [Augmentation]

    public var instruments: [Instrument]

    public var template: Template?

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

        self.template = nil

        self.collect(builder())

        self.validate()
    }

    mutating func collect(_ element: PackageElementConvertible) {
        switch element.asPackageElement() {
        case .schema(let schema):
            self.schemas.append(schema)
        case .instrument(let instrument):
            self.instruments.append(instrument)
        case .template(let template):
            self.template = template

        case .fragment(let elements):
            elements.forEach { el in
                self.collect(el)
            }
        }
    }

    public func validate() {
        func undefinedSchemaMessage(_ schema: String, requiredByType: Any.Type, requiredBy: String) -> String {
            """
            Schema [\(schema)] required by [\(requiredBy)] \(requiredByType) is not defined. \
            Existing schemas: \(self.schemas.map { $0.id }) in package definition [\(self.id)]
            """
        }

        // inefficiently checking, but the amount of schemas and tables is usually small so we don't mind too much
        for i in self.instruments {
            for s in i.createTables {
                precondition(
                    self.schemas.contains { $0.id.name == s.schemaRef.schemaRefString },
                    undefinedSchemaMessage(s.schemaRef.schemaRefString, requiredByType: type(of: i), requiredBy: i.id)
                )
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

    var columns: [Column] { get }
    func column(_ mnemonic: Mnemonic) -> Column?
    func hasColumn(_ mnemonic: Mnemonic) -> Bool
}

extension Schema {
    public func column(_ mnemonic: Mnemonic) -> Column? {
        self.columns.first(where: { $0.mnemonic == mnemonic })
    }

    public func hasColumn(_ mnemonic: Mnemonic) -> Bool {
        self.column(mnemonic) != nil
    }
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
            self.columns = [
                Column(
                    mnemonic: "start",
                    title: "Start",
                    type: .startTime,
                    expression: "?start",
                    hidden: true
                ),
                Column(
                    mnemonic: "duration",
                    title: "Duration",
                    type: .duration, // TODO: is this right?
                    expression: "?duration",
                    hidden: true
                )
            ]
            self.collect(builder())

            self.validate()
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

        public func validate() {
            for col in self.columns where col.notHidden {
                let variables = col.expression.referencedMnemonics

                for v in variables {
                    precondition(
                        "\(self.startPattern)".contains("\(v)") ||
                        "\(self.endPattern)".contains("\(v)"),
                        """
                        Variable '?\(v)' must appear in pattern to be used in a later expression.
                        Start Pattern: \(self.startPattern)
                        End Pattern: \(self.endPattern)
                        Schema: \(self.id)
                        """
                    )
                }
            }
        }

        public func hasColumn(_ mnemonic: Mnemonic) -> Bool {
            self.columns.contains { $0.mnemonic == mnemonic }
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
            self.columns = [
                Column(
                    mnemonic: "timestamp",
                    title: "Timestamp",
                    type: .uint64,
                    expression: "timestamp",
                    hidden: true
                ),
            ]
            
            self.collect(builder())
            self.validate()
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

        public func validate() {
            for col in self.columns {
                let variables = col.expression.referencedMnemonics

                for v in variables {
                    precondition(
                        "\(self.pattern)".contains("\(v)"),
                        """
                        Variable '?\(v)' must appear in pattern to be used in a later expression.
                        Pattern: \(self.pattern)
                        Schema: \(self.id)\n
                        """
                    )
                }
            }
        }

        public func asPackageElement() -> PackageElement {
            .schema(self)
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

public struct Mnemonic: Encodable, ExpressibleByStringLiteral, Hashable, CustomStringConvertible {
    public let name: String

    /// The mnemonic was set via an explicit reference to a Column or similar,
    /// and thus we should assume we can run checks including it (e.g. if a targeted schema
    /// includes a column identified with this mnemonic etc).
    public var definedUsingWellTypedReference: Bool

    public init(stringLiteral value: StringLiteralType) {
        if value.starts(with: "?") {
            fatalError("Mnemonic values should not start with ?, this is prepended automatically.")
        }

        self.name = value
        self.definedUsingWellTypedReference = false
    }

    public init(raw: String) {
        self.definedUsingWellTypedReference = false
        if raw.starts(with: "?") {
            self.name = "\(raw.dropFirst())"
        } else {
            self.name = raw
        }
    }

    func mnemonicString() -> String {
        "?\(self.name)"
    }

    public var description: String {
        "\(self.name)"
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.name)
    }

    public static func == (lhs: Mnemonic, rhs: Mnemonic) -> Bool {
        if lhs.definedUsingWellTypedReference != rhs.definedUsingWellTypedReference {
            return false
        }
        return true
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
        .init(expression: mnemonic.asMnemonic().mnemonicString())
    }

    public var referencedMnemonics: [Mnemonic] {
        var mnemonics: [Mnemonic] = []
        var remaining = self.expression[...]
        while let idx = remaining.firstIndex(of: "?") {
            remaining = remaining[idx...]
            let to = min(
                remaining.firstIndex(of: ")") ?? remaining.endIndex,
                remaining.firstIndex(of: " ") ?? remaining.endIndex
            )
            mnemonics.append(Mnemonic(raw: String(remaining[idx ..< to])))
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
    public var mnemonic: Mnemonic
    public var title: String
    /// The type of data this column will hold.
    public var type: EngineeringType
    public var guide: String?
    /// Defines how to map an integer expression to a string value.
    // public let `enum`: ColumnEnum
    /// An expression in the CLIPS language that will become the value of this column.
    public var expression: ClipsExpression

    internal var hidden: Bool

    public init(
        mnemonic: Mnemonic,
        title: String,
        type: EngineeringType,
        guide: String? = nil,
        expression: ClipsExpression,
        hidden: Bool = false
    ) {
        self.title = title
        self.type = type
        self.expression = expression
        self.mnemonic = mnemonic
        self.mnemonic.definedUsingWellTypedReference = true // TODO: remove
        self.hidden = hidden
    }

    var notHidden: Bool {
        return !self.hidden
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
        public var importFromFile: String

        public init(importFromFile: String) {
            precondition(
                importFromFile.hasSuffix(".tracetemplate"),
                "importFromFile value MUST end with .tracetemplate, was: \(importFromFile)"
            )
            self.importFromFile = importFromFile
        }

        public func asPackageElement() -> PackageElement {
            .template(self)
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
        public var version: UInt?
        /// Descriptive title that will appear in the Instruments library.
        public var title: String
        /// Category identifier to help group this instrument in the library.
        public var category: Category
        public var purpose: String
        public var icon: Icon
        public var beta: Bool?

        /// Declares the name of a parameter that can be used in table definitions.
        public var importParameters: [Instrument.ImportParameter]

        /// Creates a parameter specific to this instrument.
        /// Parameters show up in the UI and command line as recording options.
        public var createParameters: [Instrument.CreateParameter]

        /// Tells the instrument, when it's added to a trace document, to create a named data table.
        public var createTables: [Instrument.CreateTable]

        /// Defines the graph, or track, that the instrument will present.
        ///
        /// There can be several.
        public var graphs: [Instrument.Graph]

        /// Defines the list, or track, that the instrument will present.
        ///
        /// There can be several.
        public var lists: [Instrument.List]

        public var narratives: [Instrument.Narrative]

        /// Creates an aggregate view (e.g. summary with totals and averages) in the detail area.
        public var aggregations: [Instrument.Aggregation]

        /// Defines engineering type data track data source.
        /// When this Instrument is present in the trace document,
        /// this data source is queried and matching engineering type tracks are created.
        public var engineeringTypeTracks: [EngineeringTypeTrack]

        public init(
            id: String,
            version: UInt? = nil,
            title: String,
            category: Category,
            purpose: String,
            icon: Icon,
            beta: Bool? = nil,
            @InstrumentBuilder _ builder: () -> InstrumentElementConvertible = { InstrumentElement.fragment([]) }
        ) {
            self.id = id
            self.version = version
            self.title = title
            self.category = category
            self.purpose = purpose
            self.icon = icon
            self.beta = beta

            self.importParameters = []
            self.createParameters = []
            self.createTables = []

            self.graphs = []
            self.lists = []
            self.aggregations = []
            self.narratives = []
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
            case .narrative(let element):
                self.narratives.append(element)

            case .fragment(let elements):
                elements.forEach { el in
                    self.collect(el)
                }
            }
        }

        public enum Category: String, Encodable {
            case system = "System"
            case graphics = "Graphics"
            case energy = "Energy"
            case behavior = "Behavior"
            case memory = "Memory"
            case cPU = "CPU"
        }

        public enum Icon: String, Encodable {
            case generic = "Generic"
            case coreLocation = "Core Location"
            case timeProfiler = "Time Profiler"
            case systemLoad = "System load"
            case scheduling = "Scheduling"
            case virtualMemory = "Virtual Memory"
            case systemCalls = "System Calls"
            case pointsOfInterest = "Points of Interest"
            case signposts = "Signposts"
            case activityMonitor = "Activity Monitor"
            case sceneKit = "SceneKit"
            case dispatch = "Dispatch"
            case network = "Network"
            case energy = "Energy"
            case energySleepWake = "Energy:Sleep/Wake"
            case energyCPUActivity = "Energy:CPU Activity"
            case energyBrightness = "Energy:Brightness"
            case energyWiFi = "Energy:Wi-Fi"
            case energyGPS = "Energy:GPS"
            case energyBluetooth = "Energy:Bluetooth"
            case energyNetworking = "Energy:Networking"
            case metalApplication = "Metal Application"
            case graphicsDriverUtility = "Graphics Driver Utility"
            case gPUHardware = "GPU Hardware"
            case displaySurfaces = "Display Surfaces"
            case coreAnimation = "Core Animation"
            case coreDataSaves = "Core Data Saves"
            case coreDataFetches = "Core Data Fetches"
            case coreDataFaults = "Core Data Faults"
            case diskUsage = "Disk Usage"
            case diskIOLatency = "Disk IO Latency"
            case filesystemActivity = "Filesystem Activity"
            case filesystemSuggestions = "Filesystem Suggestions"
            case metalGPUAllocations = "Metal GPU Allocations"
            case metalGPUCounters = "Metal GPU Counters"
            case thermalState = "Thermal State"
            case aRKit = "ARKit"
            case coreML = "CoreML"
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

    public enum SchemaRef: Encodable {
        case schema(Schema)
        case id(String)

        var id: String {
            switch self {
            case .id(let i):
                return i
            case .schema(let s):
                return s.id.name
            }
        }

        // Attempts to validate, if a string id is used it always returns true.
        func hasColumn(_ col: Mnemonic) -> Bool {
            switch self {
            case .schema(let s):
                return s.hasColumn(col)
            default:
                return true // stringly typed reference, cannot cross check mnemonics
            }
        }

        public var columnNames: [String] {
            switch self {
            case .schema(let schema):
                return schema.columns.map(\.mnemonic.name)
            default:
                return []
            }
        }

        public var schemaRefString: String {
            switch self {
            case .schema(let schema):
                return schema.id.name
            case .id(let id):
                return id
            }
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

    /// Specifies a filter that should be applied to the input data in table-ref.
    public struct Slice: Encodable {
        // /// If supplied, only activates the selection predicate when the conditions are true.
        var when: [When]

        /// Column to set a constraint on.
        var column: Column

        /// The values that should be allowed in the column element to include this data in a table or graph.
        var equals: [String]

        public init(when: [When] = [], column: Column, _ equals: String...) {
            self.when = when
            self.column = column
            self.equals = equals
        }

        public enum When: Encodable {
            case parameterIsTrue(Mnemonic)
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
            public var histograms: [PackageDefinition.Instrument.Graph.Histogram] = []
            // public var histogramTemplates: [PackageDefinition.Instrument.Graph.HistogramTemplate] = []

            public init(
                title: String,
                table: PackageDefinition.Instrument.CreateTable,
                guide: String? = nil,
                baseColor: String? = nil,
                file: String = #file, line: UInt = #line,
                @GraphLaneBuilder _ builder: () -> GraphLaneElementConvertible = { GraphLaneElement.fragment([]) }
            ) {
                self.title = title
                self.tableRef = .init(table)

                self.guide = guide
                self.baseColor = baseColor
                self.collect(builder())

                self.validate(file: file, line: line)
            }

            private mutating func collect(_ element: GraphLaneElementConvertible) {
                switch element.asGraphLaneElement() {
                case .plot(let plot):
                    self.plots.append(plot)
                case .plotTemplate(let template):
                    self.plotTemplates.append(template)
                case .histogram(let histogram):
                    self.histograms.append(histogram)
                case .fragment(let fragments):
                    for f in fragments {
                        self.collect(f)
                    }
                }
            }

            public func validate(file: String, line: UInt) {
                let schemaRef = self.tableRef.schemaRef

                func failureMessage(_ ref: SchemaRef, _ type: Any.Type, missing: Mnemonic) -> String {
                    """
                    Error in Lane defined at [\(file):\(line)] \
                    Schema [\(ref.id)] referred to by [\(type)], \
                    does not define the required column [\(missing.name)]! \
                    Available columns: \(ref.columnNames)
                    """
                }

                for p in self.plots {
                    if p.valueFrom.definedUsingWellTypedReference {
                        precondition(schemaRef.hasColumn(p.valueFrom), failureMessage(schemaRef, type(of: p), missing: p.valueFrom))
                    }
                    if let m = p.colorFrom, m.definedUsingWellTypedReference {
                        precondition(schemaRef.hasColumn(m), failureMessage(schemaRef, type(of: p), missing: m))
                    }
                    if let m = p.labelFrom, m.definedUsingWellTypedReference {
                        precondition(schemaRef.hasColumn(m), failureMessage(schemaRef, type(of: p), missing: m))
                    }
                }
                for p in self.plotTemplates {
                    if p.valueFrom.definedUsingWellTypedReference {
                        precondition(schemaRef.hasColumn(p.valueFrom), failureMessage(schemaRef, type(of: p), missing: p.valueFrom))
                    }
                    if let m = p.colorFrom, m.definedUsingWellTypedReference {
                        precondition(schemaRef.hasColumn(m), failureMessage(schemaRef, type(of: p), missing: m))
                    }
                    if let m = p.labelFrom, m.definedUsingWellTypedReference {
                        precondition(schemaRef.hasColumn(m), failureMessage(schemaRef, type(of: p), missing: m))
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
                case .histogram(let histogram):
                    self.elements.append(.histogram(histogram))
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

            public var colorFrom: Mnemonic?

            // public var priority-from? // TODO:

            /// The column where the label text on hover-over should be pulled.
            public var labelFrom: Mnemonic?

            // public var (qualified-by | disable-implicit-qualifier)?

            // public var qualifier-treatment* // TODO:

            // public var containment-level-from? // TODO:

            // public var (peer-group | ignore-peer-group)? // TODO:

            public init(
                valueFrom: MnemonicConvertible,
                colorFrom: MnemonicConvertible? = nil,
                labelFrom: MnemonicConvertible? = nil
            ) {
                self.valueFrom = valueFrom.asMnemonic()
                self.colorFrom = colorFrom?.asMnemonic()
                self.labelFrom = labelFrom?.asMnemonic()
            }

            public init(
                valueFrom: Column,
                colorFrom: Column? = nil,
                labelFrom: Column? = nil
            ) {
                self.valueFrom = valueFrom.asMnemonic()
                self.colorFrom = colorFrom?.asMnemonic()
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

            // TODO: need a lot of overloads here since any of the mnemonic convertibles may be a Column for the nice .syntax
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

        /// Creates a histogram to aggregate activity over a given time period.
        ///
        /// - SeeAlso: https://help.apple.com/instruments/developer/mac/current/#/dev455934374
        public struct Histogram: Encodable, GraphLaneElementConvertible {
             /// Specifies a filter that should be applied to the input data in table-ref
             public var slice: [Slice] // 1-3

            // /// Flags the histogram as being ideal for a particular time resolution.
            // best-for-resolution {1,3}

            /// The number of nanoseconds each bucket of the histogram will divided into.
            public var nanosecondsPerBucket: Int

            var mode: Mode
            public enum Mode {
                /// Picks any value arbitrarily.
                case chooseAny(Column)

                /// If all the data is the same, choose it, else choose nothing.
                case chooseUnique(Column)

                /// The number of data points in the aggregation.
                case count(Column)

                /// Total the value in the column mnemonic supplied.
                case sum(Column)

                /// Minimum value in the column mnemonic supplied.
                case min(Column)

                /// Maximum value in the column mnemonic supplied.
                case max(Column)

                /// Average value in the column mnemonic supplied.
                case average(Column)

                /// Standard deviation (quick estimate) of the value in the column mnemonic supplied.
                case standardDeviation(Column)

                /// The distance between the first point in the aggregate and the last.
                case range(Column)

                /// Totals a column value, divides by the capacity constant, and multiplies by 100.
                case percentOfCapacity(Column)
            }

//            var peerGroup: PeerGroupMode?
//            public enum PeerGroupMode {
//                /// Specifies the peer group which should be used for scaling of the value graphed by this plot.
//                case peerGroup
//
//                /// Specifies the plot doesn't belong to any of the peer groups and value shouldn't be scaled accordingly to any other visible plots.
//                case ignorePeerGroup
//            }

            public init(
                slice: [Slice] = [],
                nanosecondsPerBucket: Int,
                mode: Mode
            ) {
                self.slice = slice
                self.nanosecondsPerBucket = nanosecondsPerBucket
                self.mode = mode
            }

            public func asGraphLaneElement() -> GraphLaneElement {
                .histogram(self)
            }
        }
    }

    public struct List: Encodable, InstrumentElementConvertible {
        public let title: String
        public let slice: Slice?
        public let tableRef: TableRef
        public var columns: [Mnemonic]

        public init(
            title: String,
            slice: Slice? = nil,
            table: PackageDefinition.Instrument.CreateTable,
            @ColumnsBuilder columns: () -> [MnemonicConvertible]
        ) {
            self.title = title
            self.slice = slice
            self.tableRef = .init(table)
            self.columns = columns().map { $0.asMnemonic() }

            self.validate()
        }

        public func validate() {
            precondition(self.columns.count > 0, "\(Self.self) MUST have at least one column: \(self)")

            for col in self.columns {
                precondition(
                    "\(self.tableRef.schemaRef.columnNames)".contains("\(col.name)"),
                    """
                    Column '?\(col.name)' must be defined in table \(self.tableRef.id) used by \(Self.self).
                    Available columns: \(self.tableRef.schemaRef.columnNames)
                    List: \(self.title)
                    """
                )
            }
        }

        public func asInstrumentElement() -> InstrumentElement {
            .list(self)
        }
    }

    /// Creates a view in the detail area optimized for the "narrative" engineering type.
    public struct Narrative: Encodable, InstrumentElementConvertible {
        /// The title that will be used to refer to this narrative detail view.
        public let title: String?

        /// The table that will provide the narrative data.
        public let tableRef: TableRef

        // /// A note that documentation tools may extract when creating a user's guide.
        // public var guide: String?

        /// The title of a detail view to visit when the user attempts to focus on a specific row.
        public var visitOnFocus: VisitOnFocus?

        // /// When a narrative is empty, this empty content suggestion helps explain why.
        // public var emptyContentSuggestion: String?

        // /// Deprecated. Has no effect and will be removed in a future update.
        // public var timeColumn: Mnemonic?

        /// The column from the schema where the narrative text should be displayed from.
        public var narrativeColumn: Mnemonic

        /// Extra columns that should be displayed as longer-form annotations of the narrative, like a backtrace or long file path.
        public var annotationColumns: [Mnemonic] // {0, 20}

        public init(
            title: String?,
            table: PackageDefinition.Instrument.CreateTable,
            visitOnFocus: VisitOnFocus? = nil,
            narrativeColumn: Column,
            annotationColumns: [Column] = []
        ) {
            precondition(annotationColumns.count <= 20, "annotationColumns.count MUST be <= 20, was: \(annotationColumns.count)")
            self.title = title
            self.tableRef = .init(table)
            self.visitOnFocus = visitOnFocus
            self.narrativeColumn = narrativeColumn.mnemonic
            self.annotationColumns = annotationColumns.map { $0.mnemonic }
        }

        public func asInstrumentElement() -> InstrumentElement {
            .narrative(self)
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
        public var visitOnFocus: VisitOnFocus?
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
            visitOnFocus viewOnFocusTarget: VisitOnFocusTarget? = nil,
            columns: [AggregationColumn],
            columnsHidden: [Column] = []
        ) {
            self.title = title
            self.tableRef = TableRef(table)
            self.emptyContentSuggestion = emptyContentSuggestion
            self.hierarchy = hierarchy
            self.visitOnFocus = viewOnFocusTarget.map { VisitOnFocus($0) }
            self.columns = columns
            self.columnsHidden = columnsHidden
        }

        public enum AggregationColumn: Encodable {
            case chooseAny(title: String?, Column)
            case chooseUnique(title: String?, Column)
            case count0(title: String?)
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

            /// Renders a `<count/>` node
            public static func count(title: String?) -> AggregationColumn {
                .count0(title: title)
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
    }

    /// Defines engineering type data track data source.
    /// When this Instrument is present in the trace document, this data source is queried and matching engineering type tracks are created.
    public struct EngineeringTypeTrack: Encodable, InstrumentElementConvertible {
        /// The data table that the engineering types will be created from.
        public var tableRef: TableRef
        public var hierarchy: Hierarchy

        public init(table: PackageDefinition.Instrument.CreateTable, hierarchy: Hierarchy) {
            self.tableRef = .init(table)
            self.hierarchy = hierarchy
        }

        public func asInstrumentElement() -> InstrumentElement {
            .engineeringTypeTrack(self)
        }

        /// Defines table and hierarchy of columns that should be used to form a hierarchy.
        public struct Hierarchy: Encodable, ExpressibleByArrayLiteral {
            public typealias ArrayLiteralElement = Level
            /// Describes each level in the hierarchy and how to roll up data from one level to the next.
            let levels: [Level]

            public init(arrayLiteral elements: Self.ArrayLiteralElement...) {
                precondition(elements.count > 0, "engineeringTypeTrack.hierarchy.count MUST be > 0, was \(elements.count)")
                precondition(elements.count <= 4, "engineeringTypeTrack.hierarchy.count MUST be <= 4, was \(elements.count)")
                self.levels = elements
            }

            public struct Level: Encodable {
                let type: LevelType
                /// A priority that specifies what should be the order of the tracks, when multiple types are available on the same hierarchy level.
                let typePriority: Int?

                public init(_ type: LevelType, typePriority: Int? = nil) {
                    self.type = type
                    self.typePriority = typePriority
                }

                public static var `self`: Level {
                    .init(.self)
                }

                public static func column(_ column: Column) -> Level {
                    .init(.column(column))
                }

                public enum LevelType {
                    /// Specifies that engineering type track parent is the defined instrument type. Only usable for the first level of hierarchy.
                    case `self`
                    /// A reference to the name of a column that will be queried for the engineering type track identity.
                    case column(Column)
                }
            }
        }
    }

    /// A reference to a `Table` a given `Instrument` reads from.
    public struct TableRef: Encodable {
        public var id: String
        public var schemaRef: SchemaRef

        func hasColumn(_ col: Mnemonic) -> Bool {
            self.schemaRef.hasColumn(col)
        }
        
        public init(_ table: PackageDefinition.Instrument.CreateTable) {
            self.id = table.id
            self.schemaRef = table.schemaRef
        }
    }
}

public protocol VisitOnFocusTarget {
    var title: String { get }
}

extension Instrument.List: VisitOnFocusTarget {}
extension Instrument.Graph: VisitOnFocusTarget {}

public enum EngineeringType: String, CodingKey, Codable {
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
