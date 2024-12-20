/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2020-Present Datadog, Inc.
 */

@_implementationOnly import EventsExporter
import Foundation

class IntelligentTestRunner {
    private let skippableFileName = "skippableTests"
    private var _skippableTests: SkipTests? = nil {
        didSet {
            skippableTests = _skippableTests.map { SkippableTests(tests: $0.tests) }
        }
    }

    var configurations: [String: String]
    var customConfigurations: [String: String]
    var itrFolder: Directory

    private(set) var skippableTests: SkippableTests? = nil
    var correlationId: String? { _skippableTests?.correlationId }

    init(configurations: [String: String], custom: [String: String], folder: Directory) {
        self.configurations = configurations
        self.customConfigurations = custom
        self.itrFolder = folder
    }

    func start() {
        if itrFolder.hasFile(named: skippableFileName) {
            // We have cached skippable tests. Try to load
            loadSkippableTestsFromDisk()
        }
        if _skippableTests == nil {
            getSkippableTests(repository: DDTestMonitor.env.git.repositoryURL)
            saveSkippableTestsToDisk()
        } else {
            Log.debug("Skippable tests loaded from disk")
        }
    }

    func getSkippableTests(repository: URL?) {
        guard let commit = DDTestMonitor.env.git.commitSHA, let url = repository else { return }
        _skippableTests = DDTestMonitor.tracer.eventsExporter?.skippableTests(
            repositoryURL: url.spanAttribute, sha: commit, testLevel: .test,
            configurations: configurations, customConfigurations: customConfigurations
        )
        Log.debug("Skippable Tests: \(_skippableTests.map {"\($0)"} ?? "nil")")
    }

    private func loadSkippableTestsFromDisk() {
        if let skippableData = try? itrFolder.file(named: skippableFileName).read(),
           let skippableTests = try? JSONDecoder().decode(SkipTests.self, from: skippableData)
        {
            _skippableTests = skippableTests
        }
        Log.debug("Load Skippable Tests: \(_skippableTests.map {"\($0)"} ?? "nil")")
    }

    private func saveSkippableTestsToDisk() {
        if let tests = _skippableTests, let data = try? JSONEncoder().encode(tests) {
            let skippableTestsFile = try? itrFolder.createFile(named: skippableFileName)
            
            try? skippableTestsFile?.append(data: data)
        }
    }
}

struct SkippableTests {
    struct Configuration {
        let standard: [String: String]?
        let custom: [String: String]?
    }
    
    struct Test {
        let name: String
        var configurations: [Configuration]
    }
    
    struct Suite {
        let name: String
        var methods: [String: Test]
        
        subscript(_ method: String) -> Test? { methods[method] }
    }
    
    let suites: [String: Suite]
    
    init(tests: [SkipTestPublicFormat]) {
        var suites = [String: Suite]()
        for test in tests {
            suites.get(key: test.suite, or: Suite(name: test.suite, methods: [:])) { suite in
                suite.methods.get(key: test.name, or: Test(name: test.name, configurations: [])) {
                    $0.configurations.append(Configuration(standard: test.configuration, custom: test.customConfiguration))
                }
            }
        }
        self.suites = suites
    }
    
    subscript(_ suite: String) -> Suite? { suites[suite] }
    
    subscript(_ suite: String, _ name: String) -> Test? { self[suite]?[name] }
}
