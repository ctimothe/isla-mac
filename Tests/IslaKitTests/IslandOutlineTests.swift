import SwiftUI
import XCTest
@testable import IslaKit

/// The island's outline (redesign spec §19.2): one black shape hung from the top
/// of the screen, its shoulders and bottom corners quadratic Béziers — the
/// shoulder's control point on the top edge, the bottom corner's on the corner
/// — rather than circular arcs, which read heavier and do not fit the measured
/// outlines.
final class IslandOutlineTests: XCTestCase {
    /// The path's elements, flattened to something a test can compare.
    private enum Element: Equatable {
        case move(CGPoint)
        case line(CGPoint)
        case quad(to: CGPoint, control: CGPoint)
        case cubic
        case close
    }

    private func elements(of path: Path) -> [Element] {
        var out: [Element] = []
        path.forEach { element in
            switch element {
            case .move(let to): out.append(.move(to))
            case .line(let to): out.append(.line(to))
            case .quadCurve(let to, let control): out.append(.quad(to: to, control: control))
            case .curve: out.append(.cubic)
            case .closeSubpath: out.append(.close)
            }
        }
        return out
    }

    /// `M 0 0 Q rt 0 rt rt L rt h−rb Q rt h rt+rb h L W−rt−rb h Q W−rt h W−rt
    /// h−rb L W−rt rt Q W−rt 0 W 0`, open along the top.
    private func expectedOpenPath(width w: CGFloat, height h: CGFloat, top rt: CGFloat, bottom rb: CGFloat) -> [Element] {
        [
            .move(CGPoint(x: 0, y: 0)),
            .quad(to: CGPoint(x: rt, y: rt), control: CGPoint(x: rt, y: 0)),
            .line(CGPoint(x: rt, y: h - rb)),
            .quad(to: CGPoint(x: rt + rb, y: h), control: CGPoint(x: rt, y: h)),
            .line(CGPoint(x: w - rt - rb, y: h)),
            .quad(to: CGPoint(x: w - rt, y: h - rb), control: CGPoint(x: w - rt, y: h)),
            .line(CGPoint(x: w - rt, y: rt)),
            .quad(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - rt, y: 0)),
        ]
    }

    private func assertEqual(
        // `Path` keeps its points in single precision: 8.67 comes back as
        // 8.670000076, so the comparison allows a thousandth of a point.
        _ actual: [Element], _ expected: [Element], accuracy: CGFloat = 0.001,
        _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, "\(message): element count", file: file, line: line)
        for (index, (a, e)) in zip(actual, expected).enumerated() {
            switch (a, e) {
            case (.move(let p), .move(let q)), (.line(let p), .line(let q)):
                XCTAssertEqual(p.x, q.x, accuracy: accuracy, "\(message) [\(index)] x", file: file, line: line)
                XCTAssertEqual(p.y, q.y, accuracy: accuracy, "\(message) [\(index)] y", file: file, line: line)
            case (.quad(let p, let pc), .quad(let q, let qc)):
                XCTAssertEqual(p.x, q.x, accuracy: accuracy, "\(message) [\(index)] x", file: file, line: line)
                XCTAssertEqual(p.y, q.y, accuracy: accuracy, "\(message) [\(index)] y", file: file, line: line)
                XCTAssertEqual(pc.x, qc.x, accuracy: accuracy, "\(message) [\(index)] control x", file: file, line: line)
                XCTAssertEqual(pc.y, qc.y, accuracy: accuracy, "\(message) [\(index)] control y", file: file, line: line)
            case (.close, .close):
                break
            default:
                XCTFail("\(message) [\(index)]: \(a) is not \(e)", file: file, line: line)
            }
        }
    }

    /// The three reference shapes the spec names: the resting notch, the
    /// player, and an alert.
    private let references: [(name: String, size: CGSize, top: CGFloat, bottom: CGFloat)] = [
        ("the resting notch", CGSize(width: 225.4, height: 38), 8.67, 12.67),
        ("the player", CGSize(width: 425.4, height: 198), 34, 44),
        ("Battery Low", CGSize(width: 325.4, height: 113), 22, 40),
    ]

    func testEveryReferenceShapeIsTheSpecsQuadraticConstruction() {
        for ref in references {
            let rect = CGRect(origin: .zero, size: ref.size)
            let shape = NotchShape(topRadius: ref.top, bottomRadius: ref.bottom)
            let expected = expectedOpenPath(width: ref.size.width, height: ref.size.height, top: ref.top, bottom: ref.bottom)
            assertEqual(elements(of: shape.openPath(in: rect)), expected, ref.name + ", open")
            assertEqual(elements(of: shape.path(in: rect)), expected + [.close], ref.name + ", filled")
        }
    }

    /// The shoulders' control points lie on the top edge and the bottom
    /// corners' on the corners — the property that makes them quadratic
    /// fillets and not arcs. No cubic anywhere: a circular arc is drawn as one.
    func testShouldersAreControlledFromTheTopEdgeAndCornersFromTheCorners() {
        for ref in references {
            let rect = CGRect(origin: .zero, size: ref.size)
            let quads = elements(of: NotchShape(topRadius: ref.top, bottomRadius: ref.bottom).path(in: rect))
                .compactMap { element -> CGPoint? in
                    if case .quad(_, let control) = element { return control }
                    return nil
                }
            XCTAssertEqual(quads.count, 4, ref.name)
            XCTAssertEqual(quads[0].y, 0, ref.name + ": the left shoulder's control on the top edge")
            XCTAssertEqual(quads[3].y, 0, ref.name + ": the right shoulder's control on the top edge")
            XCTAssertEqual(quads[1].x, ref.top, accuracy: 0.001, ref.name + ": bottom-left on the corner")
            XCTAssertEqual(quads[1].y, ref.size.height, accuracy: 0.001, ref.name + ": bottom-left on the corner")
            XCTAssertEqual(quads[2].x, ref.size.width - ref.top, accuracy: 0.001, ref.name + ": bottom-right on the corner")
            XCTAssertEqual(quads[2].y, ref.size.height, accuracy: 0.001, ref.name + ": bottom-right on the corner")
            XCTAssertFalse(
                elements(of: NotchShape(topRadius: ref.top, bottomRadius: ref.bottom).path(in: rect)).contains(.cubic),
                ref.name + ": no circular arc"
            )
        }
    }

    /// Both radii are the animatable pair, so a shape springing from the notch
    /// to the player carries its corners with it.
    func testBothRadiiAnimate() {
        var shape = NotchShape(topRadius: 8.67, bottomRadius: 12.67)
        XCTAssertEqual(shape.animatableData.first, 8.67)
        XCTAssertEqual(shape.animatableData.second, 12.67)
        shape.animatableData = AnimatablePair(34, 44)
        XCTAssertEqual(shape.topRadius, 34)
        XCTAssertEqual(shape.bottomRadius, 44)

        let from = NotchShape(topRadius: 8.67, bottomRadius: 12.67).animatableData
        let to = NotchShape(topRadius: 34, bottomRadius: 44).animatableData
        var halfway = from
        halfway += (to - from).scaled(by: 0.5)
        XCTAssertEqual(halfway.first, (8.67 + 34) / 2, accuracy: 0.0001)
        XCTAssertEqual(halfway.second, (12.67 + 44) / 2, accuracy: 0.0001)
    }

    /// The stroke follows the open path: no segment along the top edge, the
    /// bezel, from either shoulder's inner end to the other's.
    func testTheStrokesPathHasNoTopSegment() {
        for ref in references {
            let rect = CGRect(origin: .zero, size: ref.size)
            let open = elements(of: IslandStrokeShape(topRadius: ref.top, bottomRadius: ref.bottom).path(in: rect))
            XCTAssertFalse(open.contains(.close), ref.name + ": never closed along the top")
            for element in open {
                if case .line(let to) = element {
                    XCTAssertGreaterThan(to.y, 0, ref.name + ": no line drawn to the top edge")
                }
            }
            XCTAssertEqual(open.first, .move(.zero), ref.name)
            if case .quad(let to, _) = open.last {
                XCTAssertEqual(to.x, ref.size.width, accuracy: 0.001, ref.name + ": ends at the top-right, where it began on the left")
                XCTAssertEqual(to.y, 0, ref.name)
            } else {
                XCTFail(ref.name + ": the path ends on the right shoulder")
            }
        }
    }
}
