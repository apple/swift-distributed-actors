//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2023 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedCluster
import Testing

struct PluginsSettingsTests {
    
    @Test
    func test_pluginsSettings_isInstalled() {
        var pluginsSettings = PluginsSettings()

        let clusterSingletonPlugin = ClusterSingletonPlugin()
        #expect(pluginsSettings.isInstalled(plugin: clusterSingletonPlugin) == false)

        pluginsSettings.install(plugin: clusterSingletonPlugin)
        #expect(pluginsSettings.isInstalled(plugin: clusterSingletonPlugin) == true)
    }
}
