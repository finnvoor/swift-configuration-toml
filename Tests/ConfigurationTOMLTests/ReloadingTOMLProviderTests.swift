#if ReloadingSupport

import Testing
import ConfigurationTestingInternal
@testable import ConfigurationTOML
import Foundation
import ConfigurationTesting
import SystemPackage
import ServiceLifecycle
import Configuration

struct ReloadingTOMLProviderTests {
    @Test func printingDescription() async throws {
        let fileSystem = InMemoryFileSystem(files: [:])
        let filePath = FilePath("/config.toml")
        
        let content = """
            key1 = "value1"
            key2 = "value2"
            """
            
        fileSystem.update(
            filePath: filePath, 
            timestamp: Date(), 
            contents: .file(Data(content.utf8))
        )

        let provider = try await ReloadingTOMLProvider(
            filePath: filePath,
            fileSystem: fileSystem
        )

        #expect(provider.description == "ReloadingTOMLProvider[2 values]")
        #expect(provider.debugDescription.contains("ReloadingTOMLProvider[2 values"))
        #expect(provider.debugDescription.contains("key1=value1"))
        #expect(provider.debugDescription.contains("key2=value2"))
    }

    @Test func compat() async throws {
        let fileSystem = InMemoryFileSystem(files: [:])
        let filePath = FilePath("/config.toml")
        
        // Use the same content as the static provider tests
        let content = """
            string = "Hello"
            int = 42
            double = 3.14
            bool = true
            bytes = "bWFnaWM="
            
            [other]
            string = "Other Hello"
            int = 24
            double = 2.72
            bool = false
            bytes = "bWFnaWMy"
            
            [other.stringy]
            array = ["Hello", "Swift"]
            
            [other.inty]
            array = [16, 32]
            
            [other.doubly]
            array = [0.9, 1.8]
            
            [other.booly]
            array = [false, true, true]
            
            [other.byteChunky]
            array = ["bWFnaWM=", "bWFnaWMy", "bWFnaWM="]
            
            [stringy]
            array = ["Hello", "World"]
            
            [inty]
            array = [42, 24]
            
            [doubly]
            array = [3.14, 2.72]
            
            [booly]
            array = [true, false]
            
            [byteChunky]
            array = ["bWFnaWM=", "bWFnaWMy"]
            """
            
        fileSystem.update(
            filePath: filePath, 
            timestamp: Date(), 
            contents: .file(Data(content.utf8))
        )

        let provider = try await ReloadingTOMLProvider(
            filePath: filePath,
            fileSystem: fileSystem
        )

        try await ProviderCompatTest(provider: provider).run()
    }
}

#endif
