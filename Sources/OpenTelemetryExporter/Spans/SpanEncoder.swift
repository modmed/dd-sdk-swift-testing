/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2020-2021 Datadog, Inc.
 */

import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

internal enum Constants {
    static let ddsource = "ios"
}

/// `SpanEnvelope` allows encoding multiple spans sharing the same `traceID` to a single payload.
internal struct CITestEnvelope: Encodable {
    enum CodingKeys: String, CodingKey {
        case spanType = "type"
        case version
        case content
    }

    let version: Int = 1

    let spanType: String
    let content: DDSpan

    /// The initializer to encode single `Span` within an envelope.
    init(spanType: String, content: DDSpan) {
        self.spanType = spanType
        self.content = content
    }
}

/// `Encodable` representation of span.
internal struct DDSpan: Encodable {
    let traceID: TraceId
    let spanID: SpanId
    let parentID: SpanId?
    let name: String
    let serviceName: String
    let resource: String
    let startTime: UInt64
    let duration: UInt64
    let error: Bool
    let errorMessage: String?
    let errorType: String?
    let errorStack: String?
    let type: String

    // MARK: - Meta

    let applicationVersion: String

    /// Custom tags, received from user
    var tags: [String: AttributeValue]

    static let filteredTagKeys: Set<String> = [
        "error.message", "error.type", "error.stack", "resource.name"
    ]

    func encode(to encoder: Encoder) throws {
        let sanitizedSpan = SpanSanitizer().sanitize(span: self)
        try SpanEncoder().encode(sanitizedSpan, to: encoder)
    }

    internal init(spanData: SpanData, serviceName: String, applicationVersion: String) {
        self.traceID = spanData.traceId
        self.spanID = spanData.spanId
        self.parentID = spanData.parentSpanId

        if spanData.attributes["type"] != nil {
            self.name = spanData.name
        } else {
            self.name = spanData.name + "." + spanData.kind.rawValue
        }

        self.serviceName = serviceName
        self.resource = spanData.attributes["resource.name"]?.description ?? spanData.name
        self.startTime = spanData.startTime.timeIntervalSince1970.toNanoseconds
        self.duration = spanData.endTime.timeIntervalSince(spanData.startTime).toNanoseconds

        switch spanData.status {
            case .error(let errorDescription):
                self.error = true
                self.errorType = spanData.attributes["error.type"]?.description ?? errorDescription
                self.errorMessage = spanData.attributes["error.message"]?.description
                self.errorStack = spanData.attributes["error.stack"]?.description
            default:
                self.error = false
                self.errorMessage = nil
                self.errorType = nil
                self.errorStack = nil
        }

        let spanType = spanData.attributes["type"] ?? spanData.attributes["db.type"]
        self.type = spanType?.description ?? spanData.kind.rawValue

        self.applicationVersion = applicationVersion
        self.tags = spanData.attributes.filter {
            !DDSpan.filteredTagKeys.contains($0.key)
        }.mapValues { $0 }
    }
}

/// Encodes `SpanData` to given encoder.
internal struct SpanEncoder {
    /// Coding keys for permanent `Span` attributes.
    enum StaticCodingKeys: String, CodingKey {
        // MARK: - Attributes

        case traceID = "trace_id"
        case spanID = "span_id"
        case parentID = "parent_id"
        case name
        case service
        case resource
        case type
        case start
        case duration
        case error
        case errorMessage = "meta.error.message"
        case errorType = "meta.error.type"
        case errorStack = "meta.error.stack"

        // MARK: - Metrics

        case isRootSpan = "metrics._top_level"
        case samplingPriority = "metrics._sampling_priority_v1"

        // MARK: - Meta

        case source = "meta._dd.source"
        case applicationVersion = "meta.version"
    }

    /// Coding keys for dynamic `Span` attributes specified by user.
    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
        init(_ string: String) { self.stringValue = string }
    }

    func encode(_ span: DDSpan, to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StaticCodingKeys.self)

        try container.encode(span.traceID.rawLowerLong, forKey: .traceID)
        try container.encode(span.spanID.rawValue, forKey: .spanID)

        let parentSpanID = span.parentID ?? SpanId.invalid // 0 is a reserved ID for a root span (ref: DDTracer.java#L600)
        try container.encode(parentSpanID.rawValue, forKey: .parentID)

        try container.encode(span.name, forKey: .name)
        try container.encode(span.serviceName, forKey: .service)
        try container.encode(span.resource, forKey: .resource)
        try container.encode(span.type, forKey: .type)

        try container.encode(span.startTime, forKey: .start)
        try container.encode(span.duration, forKey: .duration)

        if span.error {
            try container.encode(1, forKey: .error)
            try container.encode(span.errorMessage, forKey: .errorMessage)
            try container.encode(span.errorType, forKey: .errorType)
            try container.encode(span.errorStack, forKey: .errorStack)
        } else {
            try container.encode(0, forKey: .error)
        }

        try encodeDefaultMetrics(span, to: &container)
        try encodeDefaultMeta(span, to: &container)

        var customAttributesContainer = encoder.container(keyedBy: DynamicCodingKey.self)
        try encodeCustomAttributes(span, to: &customAttributesContainer)
    }

    /// Encodes default `metrics.*` attributes
    private func encodeDefaultMetrics(_ span: DDSpan, to container: inout KeyedEncodingContainer<StaticCodingKeys>) throws {
        // NOTE: RUMM-299 only numeric values are supported for `metrics.*` attributes
        if span.parentID == nil {
            try container.encode(1, forKey: .isRootSpan)
        }
        try container.encode(1, forKey: .samplingPriority)
    }

    /// Encodes default `meta.*` attributes
    private func encodeDefaultMeta(_ span: DDSpan, to container: inout KeyedEncodingContainer<StaticCodingKeys>) throws {
        // NOTE: RUMM-299 only string values are supported for `meta.*` attributes
        try container.encode(Constants.ddsource, forKey: .source)
        try container.encode(span.applicationVersion, forKey: .applicationVersion)
    }

    /// Encodes `meta.*` attributes coming from user
    private func encodeCustomAttributes(_ span: DDSpan, to container: inout KeyedEncodingContainer<DynamicCodingKey>) throws {
        // NOTE: RUMM-299 only string values are supported for `meta.*` attributes
        try span.tags.forEach {
            switch $0.value {
                case .int(let intValue):
                    let metricsKey = "metrics.\($0.key)"
                    try container.encode(intValue, forKey: DynamicCodingKey(metricsKey))
                case .double(let doubleValue):
                    let metricsKey = "metrics.\($0.key)"
                    try container.encode(doubleValue, forKey: DynamicCodingKey(metricsKey))
                case .string(let stringValue):
                    let metaKey = "meta.\($0.key)"
                    try container.encode(stringValue, forKey: DynamicCodingKey(metaKey))
                case .bool(let boolValue):
                    let metaKey = "meta.\($0.key)"
                    try container.encode(boolValue, forKey: DynamicCodingKey(metaKey))
                default:
                    break
            }
        }
    }
}