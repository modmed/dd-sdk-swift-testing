/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2020-2021 Datadog, Inc.
 */

import Foundation
@_implementationOnly import OpenTelemetryApi

public class DDTestSuite: NSObject, Encodable {
    var name: String
    var session: DDTestSession
    var id: SpanId
    let startTime: Date
    var duration: UInt64
    var meta: [String: String] = [:]
    var status: DDTestStatus
    var localization: String

    init(name: String, session: DDTestSession, startTime: Date? = nil) {
        self.name = name
        self.session = session
        self.startTime = startTime ?? DDTestMonitor.clock.now
        self.duration = 0
        self.status = .pass

        if DDTestMonitor.instance?.crashedSessionInfo?.crashedSuiteName == name {
            self.id = DDTestMonitor.instance?.crashedSessionInfo?.crashedSuiteId ?? SpanId.random()
            DDTestMonitor.instance?.crashedSessionInfo = nil
        } else {
            self.id = SpanId.random()
        }
        self.localization = PlatformUtils.getLocalization()
    }

    func internalEnd(endTime: Date? = nil) {
        duration = (endTime ?? DDTestMonitor.clock.now).timeIntervalSince(startTime).toNanoseconds
        /// Export session event

        let sessionStatus: String
        switch status {
            case .pass:
                sessionStatus = DDTagValues.statusPass
            case .fail:
                sessionStatus = DDTagValues.statusFail
            case .skip:
                sessionStatus = DDTagValues.statusSkip
        }

        let defaultAttributes: [String: String] = [
            DDTags.service: DDTestMonitor.env.ddService ?? DDTestMonitor.env.getRepositoryName() ?? "unknown-swift-repo",
            DDGenericTags.type: DDTagValues.typeSuiteEnd,
            DDGenericTags.language: "swift",
            DDTestTags.testSuite: name,
            DDTestTags.testFramework: session.testFramework,
            DDTestTags.testBundle: session.bundleName,
            DDTestTags.testStatus: sessionStatus,
            DDOSTags.osPlatform: DDTestMonitor.env.osName,
            DDOSTags.osArchitecture: DDTestMonitor.env.osArchitecture,
            DDOSTags.osVersion: DDTestMonitor.env.osVersion,
            DDDeviceTags.deviceName: DDTestMonitor.env.deviceName,
            DDDeviceTags.deviceModel: DDTestMonitor.env.deviceModel,
            DDRuntimeTags.runtimeName: DDTestMonitor.env.runtimeName,
            DDRuntimeTags.runtimeVersion: DDTestMonitor.env.runtimeVersion,
            DDTestSessionTags.testSessionId: String(session.id.rawValue),
            DDTestSessionTags.testSuiteId: String(id.rawValue)
        ]

        meta.merge(defaultAttributes) { _, new in new }
        meta.merge(DDEnvironmentValues.gitAttributes) { _, new in new }
        meta.merge(DDEnvironmentValues.ciAttributes) { _, new in new }
        meta[DDUISettingsTags.uiSettingsSuiteLocalization] = localization
        meta[DDUISettingsTags.uiSettingsSessionLocalization] = session.localization
        DDTestMonitor.tracer.opentelemetryExporter?.exportEvent(event: DDTestSuiteEnvelope(self))
        /// We need to wait for all the traces to be written to the backend before exiting
    }

    /// Ends the test suite
    /// - Parameters:
    ///   - endTime: Optional, the time where the suite ended
    @objc(endWithTime:) public func end(endTime: Date? = nil) { internalEnd(endTime: endTime) }
    @objc public func end() { internalEnd() }

    /// Adds a extra tag or attribute to the test suite, any number of tags can be reported
    /// - Parameters:
    ///   - key: The name of the tag, if a tag exists with the name it will be
    ///     replaced with the new value
    ///   - value: The value of the tag, can be a number or a string.
    @objc public func setTag(key: String, value: Any) {}

    /// Starts a test in this suite
    /// - Parameters:
    ///   - name: name of the suite
    ///   - startTime: Optional, the time where the test started
    @objc public func testStart(name: String, startTime: Date? = nil) -> DDTest {
        return DDTest(name: name, suite: self, session: session, startTime: startTime)
    }

    @objc public func testStart(name: String) -> DDTest {
        return testStart(name: name, startTime: nil)
    }
}

extension DDTestSuite {
    enum StaticCodingKeys: String, CodingKey {
        case test_session_id
        case test_suite_id
        case start
        case duration
        case meta
        case error
        case name
        case resource
        case service
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StaticCodingKeys.self)
        try container.encode(session.id.rawValue, forKey: .test_session_id)
        try container.encode(id.rawValue, forKey: .test_suite_id)
        try container.encode(startTime.timeIntervalSince1970.toNanoseconds, forKey: .start)
        try container.encode(duration, forKey: .duration)
        try container.encode(meta, forKey: .meta)
        try container.encode(status == .fail ? 1 : 0, forKey: .error)
        try container.encode("\(session.testFramework).suite", forKey: .name)
        try container.encode("\(name)", forKey: .resource)
        try container.encode(DDTestMonitor.env.ddService ?? DDTestMonitor.env.getRepositoryName() ?? "unknown-swift-repo", forKey: .service)
    }

    struct DDTestSuiteEnvelope: Encodable {
        enum CodingKeys: String, CodingKey {
            case type
            case version
            case content
        }

        let version: Int = 1

        let type: String = DDTagValues.typeSuiteEnd
        let content: DDTestSuite

        init(_ content: DDTestSuite) {
            self.content = content
        }
    }
}