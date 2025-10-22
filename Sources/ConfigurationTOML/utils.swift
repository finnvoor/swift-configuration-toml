import Configuration

/// Mirrors `Configuration`'s internal error type so that TOML providers can surface
/// compatible failures when values cannot be converted or cast.
enum ConfigError: Error, CustomStringConvertible, Equatable {
    case missingRequiredConfigValue(AbsoluteConfigKey)
    case configValueNotConvertible(name: String, type: ConfigType)
    case configValueFailedToCast(name: String, type: String)

    var description: String {
        switch self {
        case .missingRequiredConfigValue(let key):
            return "Missing required config value for key: \(key)."
        case .configValueNotConvertible(let name, let type):
            return "Config value for key '\(name)' failed to convert to type \(type)."
        case .configValueFailedToCast(let name, let type):
            return "Config value for key '\(name)' failed to cast to type \(type)."
        }
    }
}

/// Convenience helper that wraps a value lookup into a `LookupResult`,
/// mirroring `Configuration`'s internal helper to avoid leaking sensitive details.
@discardableResult
func withConfigValueLookup<Failure: Error>(
    encodedKey: String,
    work: () throws(Failure) -> ConfigValue?
) throws(Failure) -> LookupResult {
    let value = try work()
    return .init(encodedKey: encodedKey, value: value)
}

/// Async variant of `withConfigValueLookup`, matching the behavior provided by `Configuration`.
@discardableResult
func withConfigValueLookup<Failure: Error>(
    encodedKey: String,
    work: () async throws(Failure) -> ConfigValue?
) async throws(Failure) -> LookupResult {
    let value = try await work()
    return .init(encodedKey: encodedKey, value: value)
}
