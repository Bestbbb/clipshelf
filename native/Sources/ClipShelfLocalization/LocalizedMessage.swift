import Foundation

/// A source message and its arguments remain separate until the selected catalog
/// is rendered. Argument text is never parsed as a localization template.
public struct LocalizedMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Sendable {
    let key: String
    let arguments: [String]
    let source: String

    public init(stringLiteral value: String) {
        key = Self.escape(value)
        arguments = []
        source = value
    }

    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
        source = stringInterpolation.source
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "{", with: "{{").replacingOccurrences(of: "}", with: "}}")
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var key: String
        var arguments: [String]
        var source: String

        public init(literalCapacity: Int, interpolationCount: Int) {
            key = ""; source = ""; arguments = []
            key.reserveCapacity(literalCapacity)
            source.reserveCapacity(literalCapacity)
            arguments.reserveCapacity(interpolationCount)
        }

        public mutating func appendLiteral(_ literal: String) {
            key += LocalizedMessage.escape(literal)
            source += literal
        }

        public mutating func appendInterpolation<Value>(_ value: Value) {
            let description = String(describing: value)
            key += "{\(arguments.count)}"
            arguments.append(description)
            source += description
        }
    }
}

struct LocalizationTemplate: Sendable {
    enum Part: Sendable {
        case literal(String)
        case argument(Int)
    }
    let parts: [Part]
    let placeholders: [Int]

    init?(_ value: String) {
        var parts: [Part] = [], placeholders: [Int] = []
        var literal = "", index = value.startIndex
        func next(_ index: String.Index) -> String.Index { value.index(after: index) }
        while index < value.endIndex {
            let character = value[index]
            if character == "{" {
                let following = next(index)
                guard following < value.endIndex else { return nil }
                if value[following] == "{" {
                    literal.append("{"); index = next(following); continue
                }
                var end = following
                while end < value.endIndex, value[end].asciiValue.map({ (48...57).contains($0) }) == true { end = next(end) }
                guard end > following, end < value.endIndex, value[end] == "}" else { return nil }
                let number = String(value[following..<end])
                guard number == "0" || number.first != "0", let argument = Int(number) else { return nil }
                if !literal.isEmpty { parts.append(.literal(literal)); literal = "" }
                parts.append(.argument(argument)); placeholders.append(argument)
                index = next(end)
            } else if character == "}" {
                let following = next(index)
                guard following < value.endIndex, value[following] == "}" else { return nil }
                literal.append("}"); index = next(following)
            } else {
                literal.append(character); index = next(index)
            }
        }
        if !literal.isEmpty { parts.append(.literal(literal)) }
        self.parts = parts; self.placeholders = placeholders
    }

    /// Appends each parameter once at each template position. Braces, percent
    /// signs and even apparent placeholders inside parameters are ordinary text.
    func render(arguments: [String]) -> String? {
        var result = ""
        for part in parts {
            switch part {
            case .literal(let value): result += value
            case .argument(let index):
                guard arguments.indices.contains(index) else { return nil }
                result += arguments[index]
            }
        }
        return result
    }
}
