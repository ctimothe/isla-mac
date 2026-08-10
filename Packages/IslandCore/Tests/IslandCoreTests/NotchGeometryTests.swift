import CoreGraphics
import Testing
@testable import IslandCore

struct NotchGeometryTests {
    @Test func returnsNilWhenNoNotchSignalPresent() {
        let result = NotchGeometry.compute(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            topInset: 0,
            auxiliaryLeft: nil,
            auxiliaryRight: nil
        )
        #expect(result == nil)
    }

    @Test func fallsBackToHardcodedWidthWhenAuxiliaryAreasMissing() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let result = NotchGeometry.compute(
            screenFrame: screenFrame,
            topInset: 32,
            auxiliaryLeft: nil,
            auxiliaryRight: nil
        )
        #expect(result != nil)
        #expect(result?.frameInScreen.width == NotchGeometry.fallbackWidth)
        #expect(result?.frameInScreen.midX == screenFrame.midX)
    }

    @Test func computesRectFromAuxiliaryAreasWhenBothPresent() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let left = CGRect(x: 0, y: 950, width: 660, height: 32)
        let right = CGRect(x: 852, y: 950, width: 660, height: 32)

        let result = NotchGeometry.compute(
            screenFrame: screenFrame,
            topInset: 32,
            auxiliaryLeft: left,
            auxiliaryRight: right
        )

        #expect(result?.frameInScreen == CGRect(x: 660, y: screenFrame.maxY - 32, width: 192, height: 32))
    }
}
