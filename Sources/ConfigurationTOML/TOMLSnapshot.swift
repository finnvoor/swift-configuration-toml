//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-configuration-toml open source project
//
// Copyright (c) 2025
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

public import Configuration
import TOMLDecoder

/// A snapshot of configuration values parsed from TOML data.
///
/// This structure represents a point-in-time view of configuration values. It handles
/// the conversion from TOML types to configuration value types.
///
/// Commonly used with ``FileProvider`` and ``ReloadingFileProvider``.
@available(Configuration 1.0, *)
public struct TOMLSnapshot {

    /// Parsing options for TOML snapshot creation.
    ///
    /// This struct provides configuration options for parsing TOML data into configuration snapshots,
    /// including byte decoding and secrets specification.
    public struct ParsingOptions: FileParsingOptionsProtocol {
        /// A decoder of bytes from a string.
        public var bytesDecoder: any ConfigBytesFromStringDecoder

        /// A specifier for determining which configuration values should be treated as secrets.
        public var secretsSpecifier: SecretsSpecifier<String, any Sendable>

        /// Creates parsing options for TOML snapshots.
        ///
        /// - Parameters:
        ///   - bytesDecoder: The decoder to use for converting string values to byte arrays.
        ///   - secretsSpecifier: The specifier for identifying secret values.
        public init(
            bytesDecoder: some ConfigBytesFromStringDecoder = .base64,
            secretsSpecifier: SecretsSpecifier<String, any Sendable> = .none
        ) {
            self.bytesDecoder = bytesDecoder
            self.secretsSpecifier = secretsSpecifier
        }

        /// The default parsing options.
        ///
        /// Uses base64 byte decoding and treats no values as secrets.
        public static var `default`: Self {
            .init()
        }
    }

    /// The key encoder for TOML.
    static let keyEncoder: SeparatorKeyEncoder = .dotSeparated

    /// A TOML number-like value.
    enum TOMLNumber: CustomStringConvertible, Sendable {
        /// An integer.
        case int(Int64)
        /// A floating point value.
        case double(Double)

        var description: String {
            switch self {
            case .int(let int):
                return "\(int)"
            case .double(let double):
                return "\(double)"
            }
        }
    }

    /// A parsed TOML value compatible with the config system.
    enum TOMLValue: CustomStringConvertible, Sendable {
        /// A string value.
        case string(String)
        /// A number-ish value.
        case number(TOMLNumber)
        /// A boolean value.
        case bool(Bool)
        /// An empty array.
        case emptyArray
        /// A string array.
        case stringArray([String])
        /// A number-ish array.
        case numberArray([TOMLNumber])
        /// A boolean array.
        case boolArray([Bool])

        var description: String {
            switch self {
            case .string(let string):
                return "\(string)"
            case .number(let number):
                return "\(number)"
            case .bool(let bool):
                return "\(bool)"
            case .emptyArray:
                return "[]"
            case .stringArray(let strings):
                return strings.joined(separator: ",")
            case .numberArray(let numbers):
                return numbers.map(\.description).joined(separator: ",")
            case .boolArray(let bools):
                return bools.map { "\($0)" }.joined(separator: ",")
            }
        }
    }

    /// A wrapper of a TOML value with the information of whether it's secret.
    struct ValueWrapper: CustomStringConvertible, Sendable {
        /// The underlying TOML value.
        var value: TOMLValue

        /// Whether it should be treated as secret and not logged in plain text.
        var isSecret: Bool

        var description: String {
            if isSecret {
                return "<REDACTED>"
            }
            return "\(value)"
        }
    }

    /// The internal TOML provider error type.
    enum TOMLConfigError: Error, CustomStringConvertible {
        /// The top level TOML value was not a table.
        case topLevelTOMLValueIsNotTable
        /// The primitive type returned by TOMLDecoder is not supported.
        case unsupportedPrimitiveValue([String], String)
        /// Detected a heterogeneous array, which isn't supported.
        case unexpectedValueInArray([String], String)

        var description: String {
            switch self {
            case .topLevelTOMLValueIsNotTable:
                return "The top-level value of the TOML file must be a table."
            case .unsupportedPrimitiveValue(let keyPath, let typeName):
                return "Unsupported primitive value type: \(typeName) at \(keyPath.joined(separator: "."))."
            case .unexpectedValueInArray(let keyPath, let typeName):
                return "Unexpected value type: \(typeName) in array at \(keyPath.joined(separator: "."))."
            }
        }
    }

    /// The underlying config values.
    var values: [String: ValueWrapper]

    /// The name of the provider that created this snapshot.
    public let providerName: String

    /// A decoder of bytes from a string.
    var bytesDecoder: any ConfigBytesFromStringDecoder

    /// Creates a new TOML snapshot with parsed values.
    init(
        values: [String: ValueWrapper],
        providerName: String,
        bytesDecoder: some ConfigBytesFromStringDecoder
    ) {
        self.values = values
        self.providerName = providerName
        self.bytesDecoder = bytesDecoder
    }

    /// Parses config content from the provided TOML value.
    /// - Parameters:
    ///   - valueWrapper: The wrapped TOML value.
    ///   - key: The config key.
    ///   - type: The config type.
    /// - Returns: The parsed config value.
    /// - Throws: If the value cannot be parsed.
    private func parseValue(
        _ valueWrapper: ValueWrapper,
        key: AbsoluteConfigKey,
        type: ConfigType
    ) throws -> ConfigValue {
        func throwMismatch() throws -> Never {
            throw ConfigError.configValueNotConvertible(name: key.description, type: type)
        }

        func intValue(from number: TOMLNumber) throws -> Int {
            switch number {
            case .int(let int):
                guard let converted = Int(exactly: int) else {
                    try throwMismatch()
                }
                return converted
            case .double(let double):
                guard let converted = Int(exactly: double) else {
                    try throwMismatch()
                }
                return converted
            }
        }

        func doubleValue(from number: TOMLNumber) -> Double {
            switch number {
            case .int(let int):
                return Double(int)
            case .double(let double):
                return double
            }
        }

        let value = valueWrapper.value
        let content: ConfigContent
        switch type {
        case .string:
            guard case .string(let string) = value else {
                try throwMismatch()
            }
            content = .string(string)
        case .int:
            guard case .number(let number) = value else {
                try throwMismatch()
            }
            content = .int(try intValue(from: number))
        case .double:
            switch value {
            case .number(let number):
                content = .double(doubleValue(from: number))
            case .bool, .string, .emptyArray, .stringArray, .numberArray, .boolArray:
                try throwMismatch()
            }
        case .bool:
            guard case .bool(let bool) = value else {
                try throwMismatch()
            }
            content = .bool(bool)
        case .bytes:
            guard
                case .string(let string) = value,
                let bytesValue = bytesDecoder.decode(string)
            else {
                try throwMismatch()
            }
            content = .bytes(bytesValue)
        case .stringArray:
            guard case .stringArray(let array) = value else {
                try throwMismatch()
            }
            content = .stringArray(array)
        case .intArray:
            guard case .numberArray(let array) = value else {
                try throwMismatch()
            }
            content = .intArray(try array.map(intValue(from:)))
        case .doubleArray:
            guard case .numberArray(let array) = value else {
                try throwMismatch()
            }
            content = .doubleArray(array.map(doubleValue(from:)))
        case .boolArray:
            guard case .boolArray(let array) = value else {
                try throwMismatch()
            }
            content = .boolArray(array)
        case .byteChunkArray:
            guard case .stringArray(let array) = value else {
                try throwMismatch()
            }
            let chunkArray = try array.map { stringValue in
                guard let bytesValue = bytesDecoder.decode(stringValue) else {
                    try throwMismatch()
                }
                return bytesValue
            }
            content = .byteChunkArray(chunkArray)
        }
        return ConfigValue(content, isSecret: valueWrapper.isSecret)
    }
}

@available(Configuration 1.0, *)
extension TOMLSnapshot: FileConfigSnapshotProtocol {
    // swift-format-ignore: AllPublicDeclarationsHaveDocumentation
    public init(data: Data, providerName: String, parsingOptions: ParsingOptions) throws {
        let parsedTable = try TOMLDecoder.tomlTable(from: data)
        guard !parsedTable.isEmpty else {
            // It's valid for TOML files to be empty, but treat it as an empty table.
            self.init(values: [:], providerName: providerName, bytesDecoder: parsingOptions.bytesDecoder)
            return
        }
        let values = try parseValues(
            parsedTable,
            keyEncoder: Self.keyEncoder,
            secretsSpecifier: parsingOptions.secretsSpecifier
        )
        self.init(
            values: values,
            providerName: providerName,
            bytesDecoder: parsingOptions.bytesDecoder
        )
    }
}

@available(Configuration 1.0, *)
extension TOMLSnapshot: ConfigSnapshotProtocol {
    // swift-format-ignore: AllPublicDeclarationsHaveDocumentation
    public func value(forKey key: AbsoluteConfigKey, type: ConfigType) throws -> LookupResult {
        let encodedKey = Self.keyEncoder.encode(key)
        return try withConfigValueLookup(encodedKey: encodedKey) {
            guard let value = values[encodedKey] else {
                return nil
            }
            return try parseValue(value, key: key, type: type)
        }
    }
}

@available(Configuration 1.0, *)
extension TOMLSnapshot: CustomStringConvertible {
    // swift-format-ignore: AllPublicDeclarationsHaveDocumentation
    public var description: String {
        "\(providerName)[\(values.count) values]"
    }
}

@available(Configuration 1.0, *)
extension TOMLSnapshot: CustomDebugStringConvertible {
    // swift-format-ignore: AllPublicDeclarationsHaveDocumentation
    public var debugDescription: String {
        let prettyValues =
            values
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        return "\(providerName)[\(values.count) values: \(prettyValues)]"
    }
}

/// Parses a value emitted by `TOMLDecoder` into a TOML config value.
/// - Parameters:
///   - parsedTable: The parsed TOML table from TOMLDecoder.
///   - keyEncoder: The key encoder.
///   - secretsSpecifier: The secrets specifier.
/// - Throws: When parsing fails.
/// - Returns: The parsed and validated TOML config values.
@available(Configuration 1.0, *)
internal func parseValues(
    _ parsedTable: [String: Any],
    keyEncoder: some ConfigKeyEncoder,
    secretsSpecifier: SecretsSpecifier<String, any Sendable>
) throws -> [String: TOMLSnapshot.ValueWrapper] {
    var values: [String: TOMLSnapshot.ValueWrapper] = [:]
    var valuesToProcess: [([String], Any)] = parsedTable.map { ([$0], $1) }
    while !valuesToProcess.isEmpty {
        let (components, rawValue) = valuesToProcess.removeLast()
        if let dictionary = rawValue as? [String: Any] {
            valuesToProcess.append(contentsOf: dictionary.map { (components + [$0], $1) })
            continue
        }
        let (tomlValue, sendableValue) = try makeValue(rawValue, at: components)
        let encodedKey = keyEncoder.encode(AbsoluteConfigKey(components))
        let isSecret = secretsSpecifier.isSecret(key: encodedKey, value: sendableValue)
        values[encodedKey] = .init(value: tomlValue, isSecret: isSecret)
    }
    return values
}

/// Converts an arbitrary TOML decoded value into a `TOMLSnapshot.TOMLValue`.
@available(Configuration 1.0, *)
private func makeValue(
    _ rawValue: Any,
    at keyPath: [String]
) throws -> (TOMLSnapshot.TOMLValue, any Sendable) {
    if let string = rawValue as? String {
        return (.string(string), string)
    } else if let bool = rawValue as? Bool {
        return (.bool(bool), bool)
    } else if let number = rawValue as? Int64 {
        return (.number(.int(number)), number)
    } else if let number = rawValue as? Int {
        return (.number(.int(Int64(number))), number)
    } else if let double = rawValue as? Double {
        return (.number(.double(double)), double)
    } else if let array = rawValue as? [Any] {
        guard !array.isEmpty else {
            let empty: [String] = []
            return (.emptyArray, empty)
        }
        if array.first is String {
            var strings: [String] = []
            strings.reserveCapacity(array.count)
            for (index, element) in array.enumerated() {
                guard let string = element as? String else {
                    throw TOMLSnapshot.TOMLConfigError.unexpectedValueInArray(
                        keyPath + ["\(index)"],
                        "\(type(of: element))"
                    )
                }
                strings.append(string)
            }
            return (.stringArray(strings), strings)
        } else if array.first is Bool {
            var bools: [Bool] = []
            bools.reserveCapacity(array.count)
            for (index, element) in array.enumerated() {
                guard let bool = element as? Bool else {
                    throw TOMLSnapshot.TOMLConfigError.unexpectedValueInArray(
                        keyPath + ["\(index)"],
                        "\(type(of: element))"
                    )
                }
                bools.append(bool)
            }
            return (.boolArray(bools), bools)
        } else {
            var numbers: [TOMLSnapshot.TOMLNumber] = []
            numbers.reserveCapacity(array.count)
            var containsDouble = false
            for (index, element) in array.enumerated() {
                if let intValue = element as? Int64 {
                    numbers.append(.int(intValue))
                } else if let intValue = element as? Int {
                    let converted = Int64(intValue)
                    numbers.append(.int(converted))
                } else if let doubleValue = element as? Double {
                    numbers.append(.double(doubleValue))
                    containsDouble = true
                } else {
                    throw TOMLSnapshot.TOMLConfigError.unexpectedValueInArray(
                        keyPath + ["\(index)"],
                        "\(type(of: element))"
                    )
                }
            }
            if containsDouble {
                let doubles = numbers.map { number -> Double in
                    switch number {
                    case .int(let int):
                        return Double(int)
                    case .double(let double):
                        return double
                    }
                }
                return (.numberArray(numbers), doubles)
            } else {
                let ints = numbers.compactMap { number -> Int64? in
                    if case .int(let value) = number {
                        return value
                    }
                    return nil
                }
                return (.numberArray(numbers), ints)
            }
        }
    } else if let date = rawValue as? Date {
        throw TOMLSnapshot.TOMLConfigError.unsupportedPrimitiveValue(keyPath, "\(type(of: date))")
    } else if let dateComponents = rawValue as? DateComponents {
        throw TOMLSnapshot.TOMLConfigError.unsupportedPrimitiveValue(keyPath, "\(type(of: dateComponents))")
    } else {
        throw TOMLSnapshot.TOMLConfigError.unsupportedPrimitiveValue(keyPath, "\(type(of: rawValue))")
    }
}
