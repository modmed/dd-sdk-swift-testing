/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2020-2021 Datadog, Inc.
 */

import Foundation
import OpenTelemetrySdk

internal class SpansExporter {
    let spansDirectory = "com.datadog.civisibility/spans/v1"
    let configuration: ExporterConfiguration
    let spansStorage: FeatureStorage
    let spansUpload: FeatureUpload

    init(config: ExporterConfiguration) throws {
        self.configuration = config

        let filesOrchestrator = FilesOrchestrator(
            directory: try Directory(withSubdirectoryPath: spansDirectory),
            performance: configuration.performancePreset,
            dateProvider: SystemDateProvider()
        )

        let genericMetadata = """
        "*": {
        "runtime-id": "\(UUID().uuidString)",
        "language": "swift",
        "env": "\(configuration.environment)"
        }
        """

        let prefix = """
        {"version": 1, "metadata": { \(genericMetadata) }, "events": [
        """

        let suffix = "]}"

        let dataFormat = DataFormat(prefix: prefix, suffix: suffix, separator: ",")

        let spanFileWriter = FileWriter(
            dataFormat: dataFormat,
            orchestrator: filesOrchestrator
        )

        let spanFileReader = FileReader(
            dataFormat: dataFormat,
            orchestrator: filesOrchestrator
        )

        spansStorage = FeatureStorage(writer: spanFileWriter, reader: spanFileReader)

        let requestBuilder = RequestBuilder(
            url: configuration.endpoint.spansURL,
            queryItems: [],
            headers: [
                .contentTypeHeader(contentType: .applicationJSON),
                .userAgentHeader(
                    appName: configuration.applicationName,
                    appVersion: configuration.version,
                    device: Device.current
                ),
                .ddAPIKeyHeader(apiKey: config.apiKey)
            ] + (configuration.payloadCompression ? [RequestBuilder.HTTPHeader.contentEncodingHeader(contentEncoding: .deflate)] : [])
        )

        spansUpload = FeatureUpload(featureName: "spansUpload",
                                    storage: spansStorage,
                                    requestBuilder: requestBuilder,
                                    performance: configuration.performancePreset)
    }

    func exportSpan(span: SpanData) {
        let ciTestEnvelope: CITestEnvelope
        if let spanType = span.attributes["type"] {
            ciTestEnvelope = CITestEnvelope(spanType: spanType.description,
                                            content: DDSpan(spanData: span, serviceName: configuration.serviceName, applicationVersion: configuration.version))
        } else {
            ciTestEnvelope = CITestEnvelope(spanType: "span",
                                            content: DDSpan(spanData: span, serviceName: configuration.serviceName, applicationVersion: configuration.version))
        }

        if configuration.performancePreset.synchronousWrite {
            spansStorage.writer.writeSync(value: ciTestEnvelope)
        } else {
            spansStorage.writer.write(value: ciTestEnvelope)
        }
    }
}