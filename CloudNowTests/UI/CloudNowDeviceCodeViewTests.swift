@testable import CloudNow
import Testing

@Suite("Device-code QR rendering")
struct CloudNowDeviceCodeViewTests {
    @Test("Changing the payload clears the old image and rejects stale completion")
    func payloadChangeClearsOldImage() {
        var state = QRCodeRenderState<Int>()

        state.begin(payload: "first")
        state.complete(with: 1, payload: "first")
        #expect(state.value == 1)

        state.begin(payload: "second")
        #expect(state.value == nil)

        state.complete(with: 2, payload: "first")
        #expect(state.value == nil)

        state.complete(with: 3, payload: "second")
        #expect(state.value == 3)
    }
}
