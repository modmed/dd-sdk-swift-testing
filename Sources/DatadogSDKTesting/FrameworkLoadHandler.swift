/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2020-2021 Datadog, Inc.
 */

import Foundation

public class FrameworkLoadHandler: NSObject {
    static var environment = ProcessInfo.processInfo.environment

    @objc
    public static func handleLoad() {
        installTestObserver()
    }

    internal static func installTestObserver() {
        /// Only initialize test observer if user configured so and is running tests
        guard let enabled = DDEnvironmentValues.getEnvVariable("DD_TEST_RUNNER") as NSString?,
              enabled.boolValue == true else {
            print("[DatadogSDKTesting] Library loaded but not active, DD_TEST_RUNNER missing or inactive.")
            return
        }

        let isInTestMode = environment["XCInjectBundleInto"] != nil ||
            environment["XCTestConfigurationFilePath"] != nil
        if isInTestMode {
            print("[DatadogSDKTesting] Library loaded and active. Instrumenting tests.")
            DDTestMonitor.instance = DDTestMonitor()
            DDTestMonitor.instance?.startInstrumenting()
        }  else {
            print("[DatadogSDKTesting] Library loaded but not in testing mode.")
        }
    }
}
