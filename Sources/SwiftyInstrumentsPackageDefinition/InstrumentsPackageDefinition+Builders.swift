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

public protocol PackageElementConvertible {
    func asPackageElement() -> PackageElement
}

extension PackageElement: PackageElementConvertible {
    public func asPackageElement() -> PackageElement {
        self
    }
}

extension Array: PackageElementConvertible where Element: PackageElementConvertible {
    public func asPackageElement() -> PackageElement {
        .fragment(map {
            $0.asPackageElement()
        })
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Package Definition

@_functionBuilder
public struct PackageDefinitionBuilder {
    public static func buildBlock(_ components: PackageElement...) -> PackageElement {
        .fragment(components)
    }

    public static func buildBlock(_ components: PackageElementConvertible...) -> PackageElement {
        .fragment(components.map { $0.asPackageElement() })
    }

    public static func buildIf(_ component: PackageElement?) -> PackageElement {
        component ?? PackageElement.fragment([])
    }

    public static func buildEither(first: PackageElement) -> PackageElement {
        first
    }

    public static func buildEither(second: PackageElement) -> PackageElement {
        second
    }
}

public enum PackageElement: Encodable {
    case schema(Schema)
    case instrument(Instrument)
    case template(Template)
    case fragment([PackageElement])
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Schema

public enum SchemaElement {
    case column(Column)
    case fragment([SchemaElement])
}

public protocol SchemaElementConvertible {
    func asSchemaElement() -> SchemaElement
}

extension SchemaElement: SchemaElementConvertible {
    public func asSchemaElement() -> SchemaElement {
        self
    }
}

extension Array: SchemaElementConvertible where Element: SchemaElementConvertible {
    public func asSchemaElement() -> SchemaElement {
        .fragment(map {
            $0.asSchemaElement()
        })
    }
}

@_functionBuilder
public struct SchemaBuilder {
    public static func buildBlock(_ components: SchemaElement...) -> SchemaElement {
        .fragment(components)
    }

    public static func buildBlock(_ components: SchemaElementConvertible...) -> SchemaElement {
        .fragment(components.map { $0.asSchemaElement() })
    }

    public static func buildIf(_ component: SchemaElement?) -> SchemaElement {
        component ?? SchemaElement.fragment([])
    }

    public static func buildEither(first: SchemaElement) -> SchemaElement {
        first
    }

    public static func buildEither(second: SchemaElement) -> SchemaElement {
        second
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Instrument

public enum InstrumentElement: Encodable {
    case importParameter(Instrument.ImportParameter)
    case createParameter(Instrument.CreateParameter)
    case createTable(Instrument.CreateTable)
    case engineeringTypeTrack(PackageDefinition.Instrument.EngineeringTypeTrack)

    case graph(PackageDefinition.Instrument.Graph)
    case list(PackageDefinition.Instrument.List)

    case fragment([InstrumentElement])
}

public protocol InstrumentElementConvertible {
    func asInstrumentElement() -> InstrumentElement
}

extension InstrumentElement: InstrumentElementConvertible {
    public func asInstrumentElement() -> InstrumentElement {
        self
    }
}

extension Array: InstrumentElementConvertible where Element: InstrumentElementConvertible {
    public func asInstrumentElement() -> InstrumentElement {
        .fragment(map { $0.asInstrumentElement() })
    }
}

@_functionBuilder
public struct InstrumentBuilder {
    public static func buildBlock(_ components: InstrumentElement...) -> InstrumentElement {
        .fragment(components)
    }

    public static func buildBlock(_ components: InstrumentElementConvertible...) -> InstrumentElement {
        .fragment(components.map { $0.asInstrumentElement() })
    }

    public static func buildIf(_ component: InstrumentElement?) -> InstrumentElement {
        component ?? InstrumentElement.fragment([])
    }

    public static func buildEither(first: InstrumentElement) -> InstrumentElement {
        first
    }

    public static func buildEither(second: InstrumentElement) -> InstrumentElement {
        second
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Graph

public enum GraphElement: Encodable {
    case lane(PackageDefinition.Instrument.Graph.Lane)
    case laneTemplate(PackageDefinition.Instrument.Graph.LaneTemplate)

    case fragment([GraphElement])
}

public protocol GraphElementConvertible {
    func asGraphElement() -> GraphElement
}

extension GraphElement: GraphElementConvertible {
    public func asGraphElement() -> GraphElement {
        self
    }
}

extension Array: GraphElementConvertible where Element: GraphElementConvertible {
    public func asGraphElement() -> GraphElement {
        .fragment(map { $0.asGraphElement() })
    }
}

@_functionBuilder
public struct GraphBuilder {
    public static func buildBlock(_ components: GraphElement...) -> GraphElement {
        .fragment(components)
    }

    public static func buildBlock(_ components: GraphElementConvertible...) -> GraphElement {
        .fragment(components.map { $0.asGraphElement() })
    }

    public static func buildIf(_ component: GraphElement?) -> GraphElement {
        component ?? GraphElement.fragment([])
    }

    public static func buildEither(first: GraphElement) -> GraphElement {
        first
    }

    public static func buildEither(second: GraphElement) -> GraphElement {
        second
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: GraphLaneElement

public enum GraphLaneElement: Encodable {
    case plot(PackageDefinition.Instrument.Graph.Plot)
    case plotTemplate(PackageDefinition.Instrument.Graph.PlotTemplate)
//    case histogram(PackageDefinition.Instrument.Graph.Histogram)
//    case histogramTemplate(PackageDefinition.Instrument.Graph.HistogramTemplate)

    case fragment([GraphLaneElement])
}

public protocol GraphLaneElementConvertible {
    func asGraphLaneElement() -> GraphLaneElement
}

extension GraphLaneElement: GraphLaneElementConvertible {
    public func asGraphLaneElement() -> GraphLaneElement {
        self
    }
}

extension Array: GraphLaneElementConvertible where Element: GraphLaneElementConvertible {
    public func asGraphLaneElement() -> GraphLaneElement {
        .fragment(map {
            $0.asGraphLaneElement()
        })
    }
}

@_functionBuilder
public struct GraphLaneBuilder {
    public static func buildBlock(_ components: GraphLaneElement...) -> GraphLaneElement {
        .fragment(components)
    }

    public static func buildBlock(_ components: GraphLaneElementConvertible...) -> GraphLaneElement {
        .fragment(components.map { $0.asGraphLaneElement() })
    }

    public static func buildIf(_ component: GraphLaneElement?) -> GraphLaneElement {
        component ?? GraphLaneElement.fragment([])
    }

    public static func buildEither(first: GraphLaneElement) -> GraphLaneElement {
        first
    }

    public static func buildEither(second: GraphLaneElement) -> GraphLaneElement {
        second
    }
}

#endif
