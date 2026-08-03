import Foundation
import Testing

private final class FixtureBundleToken: NSObject {}

enum TestFixture {
    enum Error: Swift.Error, CustomStringConvertible {
        case missing(String)
        case invalidHex(String)

        var description: String {
            switch self {
            case let .missing(path):
                "Missing test fixture: \(path)"
            case let .invalidHex(path):
                "Invalid hexadecimal test fixture: \(path)"
            }
        }
    }

    static func data(_ name: String, subdirectory: String? = nil) throws -> Data {
        let path = fixturePath(name, subdirectory: subdirectory)
        let bundle = Bundle(for: FixtureBundleToken.self)
        let nameParts = splitFilename(name)
        let fixtureDirectory = subdirectory.map { "Fixtures/\($0)" } ?? "Fixtures"
        let candidates = [
            bundle.url(
                forResource: nameParts.name,
                withExtension: nameParts.extension,
                subdirectory: fixtureDirectory
            ),
            bundle.url(
                forResource: nameParts.name,
                withExtension: nameParts.extension,
                subdirectory: subdirectory
            ),
            bundle.url(forResource: nameParts.name, withExtension: nameParts.extension),
        ]

        guard let url = candidates.compactMap(\.self).first else {
            throw Error.missing(path)
        }
        return try Data(contentsOf: url)
    }

    static func string(_ name: String, subdirectory: String? = nil) throws -> String {
        let data = try data(name, subdirectory: subdirectory)
        return try #require(
            String(data: data, encoding: .utf8),
            "Fixture \(fixturePath(name, subdirectory: subdirectory)) is not UTF-8"
        )
    }

    static func hexData(_ name: String, subdirectory: String? = nil) throws -> Data {
        let contents = try string(name, subdirectory: subdirectory)
        let digits = contents.filter(\.isHexDigit)
        guard digits.count.isMultiple(of: 2) else {
            throw Error.invalidHex(fixturePath(name, subdirectory: subdirectory))
        }

        var result = Data()
        var index = digits.startIndex
        while index < digits.endIndex {
            let end = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index ..< end], radix: 16) else {
                throw Error.invalidHex(fixturePath(name, subdirectory: subdirectory))
            }
            result.append(byte)
            index = end
        }
        return result
    }

    private static func splitFilename(_ filename: String) -> (name: String, extension: String?) {
        let url = URL(fileURLWithPath: filename)
        let pathExtension = url.pathExtension
        return (
            name: url.deletingPathExtension().lastPathComponent,
            extension: pathExtension.isEmpty ? nil : pathExtension
        )
    }

    private static func fixturePath(_ name: String, subdirectory: String?) -> String {
        ["Fixtures", subdirectory, name].compactMap(\.self).joined(separator: "/")
    }
}
