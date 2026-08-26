@preconcurrency import UIKit

nonisolated enum KeyboardReplayModifier: Equatable, Sendable {
    case leftShift
    case rightAlt
}

nonisolated struct KeyboardReplayEvent: Equatable, Sendable {
    let down: Bool
    let virtualKey: UInt16
    let scanCode: UInt16
    let modifiers: UInt16

    var modifier: KeyboardReplayModifier? {
        switch virtualKey {
        case 0xA0: .leftShift
        case 0xA5: .rightAlt
        default: nil
        }
    }
}

nonisolated struct KeyboardReplayPlan: Equatable, Sendable {
    let events: [KeyboardReplayEvent]
}

nonisolated enum KeyboardReplayPlanningResult: Equatable, Sendable {
    case supported(KeyboardReplayPlan)
    case unsupportedCharacters
    case unsupportedLayout
    case tooLong
}

nonisolated enum KeyboardReplayLayout: String, CaseIterable, Sendable {
    case englishUS = "en-US"
    case englishGB = "en-GB"
    case german = "de-DE"
    case french = "fr-FR"

    init?(identifier: String) {
        switch identifier.replacingOccurrences(of: "_", with: "-").lowercased() {
        case "en-us": self = .englishUS
        case "en-gb": self = .englishGB
        case "de-de": self = .german
        case "fr-fr": self = .french
        default: return nil
        }
    }
}

nonisolated enum KeyboardReplayPlanner {
    static let maxEventCount = 256
    static let maxTextUTF8ByteCount = 1024

    private struct Modifiers: OptionSet {
        let rawValue: UInt8

        static let shift = Modifiers(rawValue: 1 << 0)
        static let altGr = Modifiers(rawValue: 1 << 1)
    }

    private struct Stroke {
        let usage: UIKeyboardHIDUsage
        let modifiers: Modifiers

        init(_ usage: UIKeyboardHIDUsage, _ modifiers: Modifiers = []) {
            self.usage = usage
            self.modifiers = modifiers
        }
    }

    static func plan(
        for text: String,
        keyboardLayout: String,
        appendEnter: Bool = true
    ) -> KeyboardReplayPlanningResult {
        guard let layout = KeyboardReplayLayout(identifier: keyboardLayout) else {
            return .unsupportedLayout
        }
        guard text.utf8.prefix(maxTextUTF8ByteCount + 1).count <= maxTextUTF8ByteCount else {
            return .tooLong
        }

        var events: [KeyboardReplayEvent] = []
        events.reserveCapacity(maxEventCount)
        for character in text {
            guard let strokes = strokes(for: character, layout: layout) else {
                return .unsupportedCharacters
            }
            for stroke in strokes {
                guard append(stroke, to: &events) else { return .tooLong }
            }
        }

        if appendEnter, !append(Stroke(.keyboardReturnOrEnter), to: &events) {
            return .tooLong
        }
        return .supported(KeyboardReplayPlan(events: events))
    }

    private static func append(_ stroke: Stroke, to events: inout [KeyboardReplayEvent]) -> Bool {
        guard let mapping = CloudKeyboardHIDMapper.mapping(for: stroke.usage) else { return false }
        let modifierMask = protocolModifierMask(for: stroke.modifiers)
        let requiredEventCount = 2 + (stroke.modifiers.contains(.shift) ? 2 : 0)
            + (stroke.modifiers.contains(.altGr) ? 2 : 0)
        guard events.count <= maxEventCount - requiredEventCount else { return false }

        if stroke.modifiers.contains(.shift),
           let shift = CloudKeyboardHIDMapper.mapping(for: .keyboardLeftShift)
        {
            events.append(event(down: true, mapping: shift, modifiers: modifierMask))
        }
        if stroke.modifiers.contains(.altGr),
           let rightAlt = CloudKeyboardHIDMapper.mapping(for: .keyboardRightAlt)
        {
            events.append(event(down: true, mapping: rightAlt, modifiers: modifierMask))
        }

        events.append(event(down: true, mapping: mapping, modifiers: modifierMask))
        events.append(event(down: false, mapping: mapping, modifiers: modifierMask))

        if stroke.modifiers.contains(.altGr),
           let rightAlt = CloudKeyboardHIDMapper.mapping(for: .keyboardRightAlt)
        {
            let remainingMask = stroke.modifiers.contains(.shift) ? UInt16(0x0001) : 0
            events.append(event(down: false, mapping: rightAlt, modifiers: remainingMask))
        }
        if stroke.modifiers.contains(.shift),
           let shift = CloudKeyboardHIDMapper.mapping(for: .keyboardLeftShift)
        {
            events.append(event(down: false, mapping: shift, modifiers: 0))
        }
        return true
    }

    private static func event(
        down: Bool,
        mapping: CloudKeyboardHIDMapping,
        modifiers: UInt16
    ) -> KeyboardReplayEvent {
        KeyboardReplayEvent(
            down: down,
            virtualKey: mapping.virtualKey,
            scanCode: mapping.scanCode,
            modifiers: modifiers
        )
    }

    private static func protocolModifierMask(for modifiers: Modifiers) -> UInt16 {
        var mask: UInt16 = 0
        if modifiers.contains(.shift) {
            mask |= 0x0001
        }
        if modifiers.contains(.altGr) {
            mask |= 0x0004
        }
        return mask
    }

    private static func strokes(
        for character: Character,
        layout: KeyboardReplayLayout
    ) -> [Stroke]? {
        if character == " " {
            return [Stroke(.keyboardSpacebar)]
        }
        if character == "\n" || character == "\r" {
            return [Stroke(.keyboardReturnOrEnter)]
        }
        if character == "\t" {
            return [Stroke(.keyboardTab)]
        }

        if let letter = letterStroke(for: character, layout: layout) {
            return [letter]
        }
        if let digit = digitStroke(for: character, layout: layout) {
            return [digit]
        }

        switch layout {
        case .englishUS: return englishUSStrokes(for: character)
        case .englishGB: return englishGBStrokes(for: character)
        case .german: return germanStrokes(for: character)
        case .french: return frenchStrokes(for: character)
        }
    }

    private static func letterStroke(
        for character: Character,
        layout: KeyboardReplayLayout
    ) -> Stroke? {
        let value = String(character)
        guard value.unicodeScalars.count == 1, let scalar = value.unicodeScalars.first else {
            return nil
        }
        let isLowercase = scalar.value >= 97 && scalar.value <= 122
        let isUppercase = scalar.value >= 65 && scalar.value <= 90
        guard isLowercase || isUppercase else { return nil }

        let lowerValue = isUppercase ? scalar.value + 32 : scalar.value
        let lowerCharacter = Character(UnicodeScalar(lowerValue)!)
        let usage: UIKeyboardHIDUsage? = switch (layout, lowerCharacter) {
        case (.german, "y"): .keyboardZ
        case (.german, "z"): .keyboardY
        case (.french, "a"): .keyboardQ
        case (.french, "m"): .keyboardSemicolon
        case (.french, "q"): .keyboardA
        case (.french, "w"): .keyboardZ
        case (.french, "z"): .keyboardW
        default:
            UIKeyboardHIDUsage(
                rawValue: UIKeyboardHIDUsage.keyboardA.rawValue + Int(lowerValue - 97)
            )
        }
        guard let usage else { return nil }
        return Stroke(usage, isUppercase ? .shift : [])
    }

    private static func digitStroke(
        for character: Character,
        layout: KeyboardReplayLayout
    ) -> Stroke? {
        let usages: [Character: UIKeyboardHIDUsage] = [
            "1": .keyboard1, "2": .keyboard2, "3": .keyboard3, "4": .keyboard4,
            "5": .keyboard5, "6": .keyboard6, "7": .keyboard7, "8": .keyboard8,
            "9": .keyboard9, "0": .keyboard0,
        ]
        guard let usage = usages[character] else { return nil }
        return Stroke(usage, layout == .french ? .shift : [])
    }

    private static func englishUSStrokes(for character: Character) -> [Stroke]? {
        let mapping: [Character: Stroke] = [
            "-": Stroke(.keyboardHyphen), "_": Stroke(.keyboardHyphen, .shift),
            "=": Stroke(.keyboardEqualSign), "+": Stroke(.keyboardEqualSign, .shift),
            "[": Stroke(.keyboardOpenBracket), "{": Stroke(.keyboardOpenBracket, .shift),
            "]": Stroke(.keyboardCloseBracket), "}": Stroke(.keyboardCloseBracket, .shift),
            "\\": Stroke(.keyboardBackslash), "|": Stroke(.keyboardBackslash, .shift),
            ";": Stroke(.keyboardSemicolon), ":": Stroke(.keyboardSemicolon, .shift),
            "'": Stroke(.keyboardQuote), "\"": Stroke(.keyboardQuote, .shift),
            "`": Stroke(.keyboardGraveAccentAndTilde), "~": Stroke(.keyboardGraveAccentAndTilde, .shift),
            ",": Stroke(.keyboardComma), "<": Stroke(.keyboardComma, .shift),
            ".": Stroke(.keyboardPeriod), ">": Stroke(.keyboardPeriod, .shift),
            "/": Stroke(.keyboardSlash), "?": Stroke(.keyboardSlash, .shift),
            "!": Stroke(.keyboard1, .shift), "@": Stroke(.keyboard2, .shift),
            "#": Stroke(.keyboard3, .shift), "$": Stroke(.keyboard4, .shift),
            "%": Stroke(.keyboard5, .shift), "^": Stroke(.keyboard6, .shift),
            "&": Stroke(.keyboard7, .shift), "*": Stroke(.keyboard8, .shift),
            "(": Stroke(.keyboard9, .shift), ")": Stroke(.keyboard0, .shift),
        ]
        return mapping[character].map { [$0] }
    }

    private static func englishGBStrokes(for character: Character) -> [Stroke]? {
        if character == "@" {
            return [Stroke(.keyboardQuote, .shift)]
        }
        if character == "\"" {
            return [Stroke(.keyboard2, .shift)]
        }
        if character == "#" {
            return [Stroke(.keyboardNonUSPound)]
        }
        if character == "~" {
            return [Stroke(.keyboardNonUSPound, .shift)]
        }
        if character == "£" {
            return [Stroke(.keyboard3, .shift)]
        }
        return englishUSStrokes(for: character)
    }

    private static func germanStrokes(for character: Character) -> [Stroke]? {
        let mapping: [Character: Stroke] = [
            "ä": Stroke(.keyboardQuote), "Ä": Stroke(.keyboardQuote, .shift),
            "ö": Stroke(.keyboardSemicolon), "Ö": Stroke(.keyboardSemicolon, .shift),
            "ü": Stroke(.keyboardOpenBracket), "Ü": Stroke(.keyboardOpenBracket, .shift),
            "ß": Stroke(.keyboardHyphen), "?": Stroke(.keyboardHyphen, .shift),
            "+": Stroke(.keyboardCloseBracket), "*": Stroke(.keyboardCloseBracket, .shift),
            "#": Stroke(.keyboardBackslash), "'": Stroke(.keyboardBackslash, .shift),
            ",": Stroke(.keyboardComma), ";": Stroke(.keyboardComma, .shift),
            ".": Stroke(.keyboardPeriod), ":": Stroke(.keyboardPeriod, .shift),
            "-": Stroke(.keyboardSlash), "_": Stroke(.keyboardSlash, .shift),
            "<": Stroke(.keyboardNonUSPound), ">": Stroke(.keyboardNonUSPound, .shift),
            "!": Stroke(.keyboard1, .shift), "\"": Stroke(.keyboard2, .shift),
            "§": Stroke(.keyboard3, .shift), "$": Stroke(.keyboard4, .shift),
            "%": Stroke(.keyboard5, .shift), "&": Stroke(.keyboard6, .shift),
            "/": Stroke(.keyboard7, .shift), "(": Stroke(.keyboard8, .shift),
            ")": Stroke(.keyboard9, .shift), "=": Stroke(.keyboard0, .shift),
            "°": Stroke(.keyboardGraveAccentAndTilde, .shift),
            "@": Stroke(.keyboardQ, .altGr), "€": Stroke(.keyboardE, .altGr),
            "{": Stroke(.keyboard7, .altGr), "[": Stroke(.keyboard8, .altGr),
            "]": Stroke(.keyboard9, .altGr), "}": Stroke(.keyboard0, .altGr),
            "\\": Stroke(.keyboardHyphen, .altGr), "~": Stroke(.keyboardCloseBracket, .altGr),
            "|": Stroke(.keyboardNonUSPound, .altGr),
        ]
        if character == "^" {
            return [Stroke(.keyboardGraveAccentAndTilde), Stroke(.keyboardSpacebar)]
        }
        if character == "´" {
            return [Stroke(.keyboardEqualSign), Stroke(.keyboardSpacebar)]
        }
        if character == "`" {
            return [Stroke(.keyboardEqualSign, .shift), Stroke(.keyboardSpacebar)]
        }
        return mapping[character].map { [$0] }
    }

    private static func frenchStrokes(for character: Character) -> [Stroke]? {
        let mapping: [Character: Stroke] = [
            "&": Stroke(.keyboard1), "é": Stroke(.keyboard2), "\"": Stroke(.keyboard3),
            "'": Stroke(.keyboard4), "(": Stroke(.keyboard5), "-": Stroke(.keyboard6),
            "è": Stroke(.keyboard7), "_": Stroke(.keyboard8), "ç": Stroke(.keyboard9),
            "à": Stroke(.keyboard0), ")": Stroke(.keyboardHyphen), "=": Stroke(.keyboardEqualSign),
            "$": Stroke(.keyboardCloseBracket), "£": Stroke(.keyboardCloseBracket, .shift),
            "*": Stroke(.keyboardBackslash), "µ": Stroke(.keyboardBackslash, .shift),
            "ù": Stroke(.keyboardQuote), "%": Stroke(.keyboardQuote, .shift),
            ",": Stroke(.keyboardM), "?": Stroke(.keyboardM, .shift),
            ";": Stroke(.keyboardComma), ".": Stroke(.keyboardComma, .shift),
            ":": Stroke(.keyboardPeriod), "/": Stroke(.keyboardPeriod, .shift),
            "!": Stroke(.keyboardSlash), "<": Stroke(.keyboardNonUSPound),
            ">": Stroke(.keyboardNonUSPound, .shift),
            "~": Stroke(.keyboard2, .altGr), "#": Stroke(.keyboard3, .altGr),
            "{": Stroke(.keyboard4, .altGr), "[": Stroke(.keyboard5, .altGr),
            "|": Stroke(.keyboard6, .altGr), "`": Stroke(.keyboard7, .altGr),
            "\\": Stroke(.keyboard8, .altGr), "@": Stroke(.keyboard0, .altGr),
            "]": Stroke(.keyboardHyphen, .altGr), "}": Stroke(.keyboardEqualSign, .altGr),
            "€": Stroke(.keyboardE, .altGr),
        ]
        if character == "^" {
            return [Stroke(.keyboardOpenBracket), Stroke(.keyboardSpacebar)]
        }
        if character == "¨" {
            return [Stroke(.keyboardOpenBracket, .shift), Stroke(.keyboardSpacebar)]
        }
        return mapping[character].map { [$0] }
    }
}
