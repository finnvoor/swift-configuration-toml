public import SystemPackage
public import Configuration

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A configuration provider that loads values from TOML files.
///
/// This provider reads TOML files from the file system and makes their values
/// available as configuration. The TOML structure is flattened using dot notation,
/// allowing nested tables to be accessed with hierarchical keys.
///
/// The provider loads the TOML file once during initialization and never reloads
/// it, making it a constant provider suitable for configuration that doesn't
/// change during application runtime.
///
/// > Tip: Do you need to watch the TOML files on disk for changes, and reload them automatically? Check out ``ReloadingTOMLProvider``.
///
/// ## Package traits
///
/// This provider is guarded by the `TOMLSupport` package trait.
///
/// ## Supported TOML types
///
/// The provider supports these TOML value types:
/// - **Strings**: Basic and literal strings
/// - **Integers**: 64-bit signed integers
/// - **Floats**: IEEE 754 double precision floating point
/// - **Booleans**: true and false
/// - **Arrays**: Homogeneous arrays of the above types
/// - **Tables**: Nested objects that are flattened using dot notation
///
/// ## Key flattening
///
/// Nested TOML tables are flattened into dot-separated keys:
///
/// ```toml
/// [database]
/// host = "localhost"
/// port = 5432
///
/// [features]
/// enabled = true
/// ```
///
/// Becomes accessible as:
/// - `database.host` → `"localhost"`
/// - `database.port` → `5432`
/// - `features.enabled` → `true`
///
/// ## Secret handling
///
/// The provider supports marking values as secret using a ``SecretsSpecifier``.
/// Secret values are automatically redacted in logs and debug output.
///
/// ## Usage
///
/// ```swift
/// // Load from a TOML file
/// let provider = try await TOMLProvider(filePath: "/etc/config.toml")
/// let config = ConfigReader(provider: provider)
///
/// // Access nested values using dot notation
/// let host = config.string(forKey: "database.host")
/// let port = config.int(forKey: "database.port")
/// let isEnabled = config.bool(forKey: "features.enabled", default: false)
/// ```
///
/// ## Configuration context
///
/// This provider ignores the context passed in ``AbsoluteConfigKey/context``.
/// All keys are resolved using only their component path.
public struct TOMLProvider: Sendable {

    /// A snapshot of the internal state.
    private let _snapshot: TOMLProviderSnapshot

    /// Creates a new TOML provider by loading the specified file.
    ///
    /// This initializer loads and parses the TOML file during initialization.
    /// The file must contain a valid TOML document.
    ///
    /// ```swift
    /// // Load configuration from a TOML file
    /// let provider = try await TOMLProvider(
    ///     filePath: "/etc/app-config.toml",
    ///     secretsSpecifier: .keyBased { key in
    ///         key.contains("password") || key.contains("secret")
    ///     }
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - filePath: The file system path to the TOML configuration file.
    ///   - bytesDecoder: The decoder used to convert string values to byte arrays.
    ///   - secretsSpecifier: Specifies which configuration values should be treated as secrets.
    /// - Throws: If the file cannot be read or parsed, or if the TOML structure is invalid.
    public init(
        filePath: FilePath,
        bytesDecoder: some ConfigBytesFromStringDecoder = .base64,
        secretsSpecifier: SecretsSpecifier<String, Void> = .none
    ) async throws {
        try await self.init(
            filePath: filePath,
            fileSystem: LocalCommonProviderFileSystem(),
            bytesDecoder: bytesDecoder,
            secretsSpecifier: secretsSpecifier
        )
    }

    /// Creates a new TOML provider using a file path from configuration.
    ///
    /// This convenience initializer reads the TOML file path from another
    /// configuration source, allowing the TOML provider to be configured
    /// through configuration itself.
    ///
    /// ```swift
    /// // Configure TOML provider through environment variables
    /// let envProvider = EnvironmentVariablesProvider()
    /// let config = ConfigReader(provider: envProvider)
    ///
    /// // TOML_FILE_PATH environment variable specifies the file
    /// let tomlProvider = try await TOMLProvider(
    ///     config: config.scoped(to: "toml")
    /// )
    /// ```
    ///
    /// ## Required configuration keys
    ///
    /// - `filePath` (string): The file path to the TOML configuration file.
    ///
    /// - Parameters:
    ///   - config: The configuration reader containing the file path.
    ///   - bytesDecoder: The decoder used to convert string values to byte arrays.
    ///   - secretsSpecifier: Specifies which configuration values should be treated as secrets.
    /// - Throws: If the file path is missing, or if the file cannot be read or parsed.
    public init(
        config: ConfigReader,
        bytesDecoder: some ConfigBytesFromStringDecoder = .base64,
        secretsSpecifier: SecretsSpecifier<String, Void> = .none
    ) async throws {
        try await self.init(
            filePath: config.requiredString(forKey: "filePath", as: FilePath.self),
            bytesDecoder: bytesDecoder,
            secretsSpecifier: secretsSpecifier
        )
    }

    /// Creates a new provider.
    /// - Parameters:
    ///   - filePath: The path of the TOML file.
    ///   - fileSystem: The underlying file system.
    ///   - bytesDecoder: A decoder of bytes from a string.
    ///   - secretsSpecifier: A secrets specifier in case some of the values should be treated as secret.
    /// - Throws: If the file cannot be read or parsed, or if the TOML structure is invalid.
    internal init(
        filePath: FilePath,
        fileSystem: some CommonProviderFileSystem,
        bytesDecoder: some ConfigBytesFromStringDecoder = .base64,
        secretsSpecifier: SecretsSpecifier<String, Void> = .none
    ) async throws {
        self._snapshot = try await .init(
            filePath: filePath,
            fileSystem: fileSystem,
            bytesDecoder: bytesDecoder,
            secretsSpecifier: secretsSpecifier
        )
    }
}

extension TOMLProvider: CustomStringConvertible {
    // swift-format-ignore: AllPublicDeclarationsHaveDocumentation
    public var description: String {
        "TOMLProvider[\(_snapshot.values.count) values]"
    }
}

extension TOMLProvider: CustomDebugStringConvertible {
    // swift-format-ignore: AllPublicDeclarationsHaveDocumentation
    public var debugDescription: String {
        let prettyValues = _snapshot.values
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        return "TOMLProvider[\(_snapshot.values.count) values: \(prettyValues)]"
    }
}

extension TOMLProvider: ConfigProvider {
    // swift-format-ignore: AllPublicDeclarationsHaveDocumentation
    public var providerName: String {
        _snapshot.providerName
    }

    // swift-format-ignore: AllPublicDeclarationsHaveDocumentation
    public func value(
        forKey key: AbsoluteConfigKey,
        type: ConfigType
    ) throws -> LookupResult {
        try _snapshot.value(forKey: key, type: type)
    }

    // swift-format-ignore: AllPublicDeclarationsHaveDocumentation
    public func fetchValue(
        forKey key: AbsoluteConfigKey,
        type: ConfigType
    ) async throws -> LookupResult {
        try value(forKey: key, type: type)
    }

    // swift-format-ignore: AllPublicDeclarationsHaveDocumentation
    public func watchValue<Return>(
        forKey key: AbsoluteConfigKey,
        type: ConfigType,
        updatesHandler: (
            ConfigUpdatesAsyncSequence<Result<LookupResult, any Error>, Never>
        ) async throws -> Return
    ) async throws -> Return {
        try await watchValueFromValue(forKey: key, type: type, updatesHandler: updatesHandler)
    }

    // swift-format-ignore: AllPublicDeclarationsHaveDocumentation
    public func snapshot() -> any ConfigSnapshotProtocol {
        _snapshot
    }

    // swift-format-ignore: AllPublicDeclarationsHaveDocumentation
    public func watchSnapshot<Return>(
        updatesHandler: (ConfigUpdatesAsyncSequence<any ConfigSnapshotProtocol, Never>) async throws -> Return
    ) async throws -> Return {
        try await watchSnapshotFromSnapshot(updatesHandler: updatesHandler)
    }
}
