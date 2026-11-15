import CoreGraphics

/// An SVG path's `d` attribute read into a `CGPath`, for the vendored Hugeicons
/// drawings (`Hugeicons.swift`).
///
/// Only the commands the free set's 4.4.0 drawings use are read: M, L, H, V, C
/// and Z, absolute or relative. `Scripts/vendor-hugeicons.mjs` refuses an icon
/// that needs anything else, so a reader that quietly skipped an arc could
/// never ship a glyph with a piece missing; `parse` returns nil for the same
/// reason rather than drawing what it understood.
enum SVGPath {
    static func parse(_ d: String) -> CGPath? {
        var scanner = Scanner(Array(d.utf8))
        let path = CGMutablePath()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var command: UInt8 = 0

        while true {
            scanner.skipSeparators()
            guard let next = scanner.peek else { break }
            if Scanner.isCommand(next) {
                command = next
                scanner.advance()
            } else if command == 0 {
                return nil
            }
            // A bare number after M or m continues as L or l, as SVG says.
            let relative = command >= UInt8(ascii: "a")
            func point() -> CGPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            switch command | 0x20 {
            case UInt8(ascii: "m"):
                guard let p = point() else { return nil }
                path.move(to: p)
                current = p
                subpathStart = p
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "l"):
                guard let p = point() else { return nil }
                path.addLine(to: p)
                current = p
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return nil }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return nil }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
            case UInt8(ascii: "c"):
                guard let c1 = point(), let c2 = point(), let p = point() else { return nil }
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = subpathStart
                // Z takes no numbers: a number straight after it is malformed.
                scanner.skipSeparators()
                if let following = scanner.peek, !Scanner.isCommand(following) { return nil }
            default:
                return nil
            }
        }
        return path.isEmpty ? nil : path
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var peek: UInt8? { index < bytes.count ? bytes[index] : nil }
        mutating func advance() { index += 1 }

        static func isCommand(_ byte: UInt8) -> Bool {
            switch byte | 0x20 {
            case UInt8(ascii: "m"), UInt8(ascii: "l"), UInt8(ascii: "h"), UInt8(ascii: "v"),
                 UInt8(ascii: "c"), UInt8(ascii: "z"),
                 // Read so that a drawing using one fails loudly, not as a number.
                 UInt8(ascii: "s"), UInt8(ascii: "q"), UInt8(ascii: "t"), UInt8(ascii: "a"):
                return true
            default:
                return false
            }
        }

        mutating func skipSeparators() {
            while let byte = peek, byte == UInt8(ascii: " ") || byte == UInt8(ascii: ",")
                || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r") {
                advance()
            }
        }

        /// One number in SVG's grammar: "-.5.5" is two numbers, "1e-3" one.
        mutating func number() -> CGFloat? {
            skipSeparators()
            let start = index
            if let sign = peek, sign == UInt8(ascii: "-") || sign == UInt8(ascii: "+") { advance() }
            var digits = 0
            var sawDot = false
            while let byte = peek {
                if byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") {
                    digits += 1
                    advance()
                } else if byte == UInt8(ascii: "."), !sawDot {
                    sawDot = true
                    advance()
                } else {
                    break
                }
            }
            guard digits > 0 else {
                index = start
                return nil
            }
            if let e = peek, e == UInt8(ascii: "e") || e == UInt8(ascii: "E") {
                let mark = index
                advance()
                if let sign = peek, sign == UInt8(ascii: "-") || sign == UInt8(ascii: "+") { advance() }
                var exponentDigits = 0
                while let byte = peek, byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") {
                    exponentDigits += 1
                    advance()
                }
                if exponentDigits == 0 { index = mark }
            }
            guard let text = String(bytes: bytes[start..<index], encoding: .ascii),
                  let value = Double(text) else { return nil }
            return CGFloat(value)
        }
    }
}
