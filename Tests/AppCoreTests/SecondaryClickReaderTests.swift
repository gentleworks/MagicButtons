import Testing
@testable import AppCore

// The system secondary-click side is encoded entirely in `MouseButtonMode`
// (confirmed by toggling System Settings → Mouse and diffing the domain).

@Suite struct SecondaryClickReaderTests {

    private func reader(_ mode: String?) -> SecondaryClickReader {
        SecondaryClickReader(readMode: { mode })
    }

    @Test func twoButtonIsRightHanded() {
        #expect(reader("TwoButton").currentSide() == .right)
    }

    @Test func twoButtonSwappedIsLeftHanded() {
        #expect(reader("TwoButtonSwapped").currentSide() == .left)
    }

    @Test func oneButtonHasNoSideSoDefaultsRight() {
        // Secondary click off: no side preference — fall back to the unswapped default.
        #expect(reader("OneButton").currentSide() == .right)
    }

    @Test func missingPreferenceDefaultsRight() {
        // Never read (fresh account) or an unexpected value: default, never crash.
        #expect(reader(nil).currentSide() == .right)
        #expect(reader("something-unexpected").currentSide() == .right)
    }
}
