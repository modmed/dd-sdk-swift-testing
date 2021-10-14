/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2020-2021 Datadog, Inc.
 */

import Foundation
@_implementationOnly import Kronos
@_implementationOnly import OpenTelemetrySdk

class NTPClock: OpenTelemetrySdk.Clock {
    init() {
        Kronos.Clock.sync()
    }

    var now: Date {
        if Thread.isMainThread {
            return Kronos.Clock.now ?? Date()
        } else {
            var date = Date()
            DispatchQueue.main.sync {
                if let now = Kronos.Clock.now {
                    date = now
                }
            }
            return date
        }
    }
}
