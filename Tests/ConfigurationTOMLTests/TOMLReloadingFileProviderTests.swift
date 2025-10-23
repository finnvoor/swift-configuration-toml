#if ReloadingSupport

import Testing
import ConfigurationTestingInternal
@testable import ConfigurationTOML
import Configuration
import Foundation
import ConfigurationTesting
import Logging
import SystemPackage

private let reloadingResourcesPath = FilePath(
    try! #require(Bundle.module.path(forResource: "Resources", ofType: nil))
)
private let reloadingTomlConfigFile = reloadingResourcesPath.appending("/config.toml")

struct TOMLReloadingFileProviderTests {
    @available(Configuration 1.0, *)
    @Test func printingDescription() async throws {
        let provider = try await ReloadingFileProvider<TOMLSnapshot>(filePath: reloadingTomlConfigFile)
        let expectedDescription = #"""
            ReloadingFileProvider<TOMLSnapshot>[20 values]
            """#
        #expect(provider.description == expectedDescription)
    }

    @available(Configuration 1.0, *)
    @Test func printingDebugDescription() async throws {
        let provider = try await ReloadingFileProvider<TOMLSnapshot>(filePath: reloadingTomlConfigFile)
        let expectedDebugDescription = #"""
            ReloadingFileProvider<TOMLSnapshot>[20 values: bool=true, booly.array=true,false, byteChunky.array=bWFnaWM=,bWFnaWMy, bytes=bWFnaWM=, double=3.14, doubly.array=3.14,2.72, int=42, inty.array=42,24, other.bool=false, other.booly.array=false,true,true, other.byteChunky.array=bWFnaWM=,bWFnaWMy,bWFnaWM=, other.bytes=bWFnaWMy, other.double=2.72, other.doubly.array=0.9,1.8, other.int=24, other.inty.array=16,32, other.string=Other Hello, other.stringy.array=Hello,Swift, string=Hello, stringy.array=Hello,World]
            """#
        #expect(provider.debugDescription == expectedDebugDescription)
    }

    @available(Configuration 1.0, *)
    @Test func compat() async throws {
        let provider = try await ReloadingFileProvider<TOMLSnapshot>(filePath: reloadingTomlConfigFile)
        try await ProviderCompatTest(provider: provider).runTest()
    }

    @available(Configuration 1.0, *)
    @Test func initializationWithConfig() async throws {
        let envProvider = InMemoryProvider(values: [
            "toml.filePath": ConfigValue(.string(reloadingTomlConfigFile.string), isSecret: false),
            "toml.pollIntervalSeconds": 30,
        ])
        let config = ConfigReader(provider: envProvider)

        let reloadingProvider = try await ReloadingFileProvider<TOMLSnapshot>(
            config: config.scoped(to: "toml")
        )

        #expect(reloadingProvider.providerName == "ReloadingFileProvider<TOMLSnapshot>")
        #expect(reloadingProvider.description.contains("ReloadingFileProvider<TOMLSnapshot>[20 values]"))
    }
}

#endif
