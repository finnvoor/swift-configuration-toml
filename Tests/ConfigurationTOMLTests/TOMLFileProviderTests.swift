import Testing
import ConfigurationTestingInternal
@testable import ConfigurationTOML
import Configuration
import Foundation
import ConfigurationTesting
import SystemPackage

private let fileProviderResourcesPath = FilePath(
    try! #require(Bundle.module.path(forResource: "Resources", ofType: nil))
)
private let tomlSnapshotConfigFile = fileProviderResourcesPath.appending("/config.toml")

struct TOMLFileProviderTests {

    @available(Configuration 1.0, *)
    var snapshot: TOMLSnapshot {
        get throws {
            try TOMLSnapshot(
                data: Data(contentsOf: URL(filePath: tomlSnapshotConfigFile.string)),
                providerName: "TestProvider",
                parsingOptions: .default
            )
        }
    }

    @available(Configuration 1.0, *)
    @Test func printingDescription() async throws {
        let expectedDescription = #"""
            TestProvider[20 values]
            """#
        try #expect(snapshot.description == expectedDescription)
    }

    @available(Configuration 1.0, *)
    @Test func printingDebugDescription() async throws {
        let expectedDebugDescription = #"""
            TestProvider[20 values: bool=true, booly.array=true,false, byteChunky.array=bWFnaWM=,bWFnaWMy, bytes=bWFnaWM=, double=3.14, doubly.array=3.14,2.72, int=42, inty.array=42,24, other.bool=false, other.booly.array=false,true,true, other.byteChunky.array=bWFnaWM=,bWFnaWMy,bWFnaWM=, other.bytes=bWFnaWMy, other.double=2.72, other.doubly.array=0.9,1.8, other.int=24, other.inty.array=16,32, other.string=Other Hello, other.stringy.array=Hello,Swift, string=Hello, stringy.array=Hello,World]
            """#
        try #expect(snapshot.debugDescription == expectedDebugDescription)
    }

    @available(Configuration 1.0, *)
    @Test func compat() async throws {
        try await ProviderCompatTest(
            provider: FileProvider<TOMLSnapshot>(filePath: tomlSnapshotConfigFile)
        )
        .runTest()
    }
}
