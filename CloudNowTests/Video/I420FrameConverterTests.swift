@testable import CloudNow
import CoreVideo
@preconcurrency import LiveKitWebRTC
import Testing

@Suite("I420 software frame conversion")
struct I420FrameConverterTests {
    @Test("Padded I420 rows convert to exact NV12 luma and chroma bytes")
    func paddedInputStrides() throws {
        let source = makeBuffer(
            width: 4,
            height: 3,
            strideY: 7,
            strideU: 4,
            strideV: 5,
            yRows: [
                [1, 2, 3, 4],
                [5, 6, 7, 8],
                [9, 10, 11, 12],
            ],
            uRows: [
                [21, 22],
                [23, 24],
            ],
            vRows: [
                [31, 32],
                [33, 34],
            ]
        )

        let converted = try #require(I420FrameConverter().convert(source))

        #expect(CVPixelBufferGetPixelFormatType(converted) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(try planeRows(converted, plane: 0, byteWidth: 4, height: 3) == [
            [1, 2, 3, 4],
            [5, 6, 7, 8],
            [9, 10, 11, 12],
        ])
        #expect(try planeRows(converted, plane: 1, byteWidth: 4, height: 2) == [
            [21, 31, 22, 32],
            [23, 33, 24, 34],
        ])
    }

    @Test("Odd dimensions round chroma planes up without losing edge samples")
    func oddDimensions() throws {
        let source = makeBuffer(
            width: 5,
            height: 3,
            strideY: 8,
            strideU: 5,
            strideV: 4,
            yRows: [
                [1, 2, 3, 4, 5],
                [6, 7, 8, 9, 10],
                [11, 12, 13, 14, 15],
            ],
            uRows: [
                [41, 42, 43],
                [44, 45, 46],
            ],
            vRows: [
                [51, 52, 53],
                [54, 55, 56],
            ]
        )

        let converted = try #require(I420FrameConverter().convert(source))

        #expect(CVPixelBufferGetWidth(converted) == 5)
        #expect(CVPixelBufferGetHeight(converted) == 3)
        #expect(try planeRows(converted, plane: 0, byteWidth: 5, height: 3) == [
            [1, 2, 3, 4, 5],
            [6, 7, 8, 9, 10],
            [11, 12, 13, 14, 15],
        ])
        #expect(try planeRows(converted, plane: 1, byteWidth: 6, height: 2) == [
            [41, 51, 42, 52, 43, 53],
            [44, 54, 45, 55, 46, 56],
        ])
    }

    @Test("Converted frames carry propagated BT.709 SDR metadata")
    func colorAttachments() throws {
        let source = makeBuffer(
            width: 2,
            height: 2,
            strideY: 2,
            strideU: 1,
            strideV: 1,
            yRows: [[16, 17], [18, 19]],
            uRows: [[128]],
            vRows: [[129]]
        )

        let converted = try #require(I420FrameConverter().convert(source))

        try expectAttachment(
            kCVImageBufferYCbCrMatrixKey,
            equals: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            on: converted
        )
        try expectAttachment(
            kCVImageBufferColorPrimariesKey,
            equals: kCVImageBufferColorPrimaries_ITU_R_709_2,
            on: converted
        )
        try expectAttachment(
            kCVImageBufferTransferFunctionKey,
            equals: kCVImageBufferTransferFunction_ITU_R_709_2,
            on: converted
        )
        try expectAttachment(
            kCVImageBufferChromaLocationTopFieldKey,
            equals: kCVImageBufferChromaLocation_Center,
            on: converted
        )
    }

    @Test("Changing frame size preserves output dimensions and pixels")
    func frameSizeChanges() throws {
        let converter = I420FrameConverter()
        let small = makeBuffer(
            width: 2,
            height: 2,
            strideY: 2,
            strideU: 1,
            strideV: 1,
            yRows: [[1, 2], [3, 4]],
            uRows: [[5]],
            vRows: [[6]]
        )
        let larger = makeBuffer(
            width: 4,
            height: 2,
            strideY: 4,
            strideU: 2,
            strideV: 2,
            yRows: [[11, 12, 13, 14], [15, 16, 17, 18]],
            uRows: [[21, 22]],
            vRows: [[31, 32]]
        )

        let first = try #require(converter.convert(small))
        let resized = try #require(converter.convert(larger))
        let restored = try #require(converter.convert(small))

        #expect(CVPixelBufferGetWidth(first) == 2)
        #expect(CVPixelBufferGetHeight(first) == 2)
        #expect(CVPixelBufferGetWidth(resized) == 4)
        #expect(CVPixelBufferGetHeight(resized) == 2)
        #expect(CVPixelBufferGetWidth(restored) == 2)
        #expect(CVPixelBufferGetHeight(restored) == 2)
        #expect(try planeRows(resized, plane: 0, byteWidth: 4, height: 2) == [
            [11, 12, 13, 14],
            [15, 16, 17, 18],
        ])
        #expect(try planeRows(restored, plane: 1, byteWidth: 2, height: 1) == [[5, 6]])
    }

    private func makeBuffer(
        width: Int,
        height: Int,
        strideY: Int,
        strideU: Int,
        strideV: Int,
        yRows: [[UInt8]],
        uRows: [[UInt8]],
        vRows: [[UInt8]]
    ) -> LKRTCMutableI420Buffer {
        let buffer = LKRTCMutableI420Buffer(
            width: Int32(width),
            height: Int32(height),
            strideY: Int32(strideY),
            strideU: Int32(strideU),
            strideV: Int32(strideV)
        )
        write(yRows, to: buffer.mutableDataY, stride: strideY)
        write(uRows, to: buffer.mutableDataU, stride: strideU)
        write(vRows, to: buffer.mutableDataV, stride: strideV)
        return buffer
    }

    private func write(
        _ rows: [[UInt8]],
        to destination: UnsafeMutablePointer<UInt8>,
        stride: Int
    ) {
        precondition(stride >= 0)
        for (rowIndex, row) in rows.enumerated() {
            precondition(row.count <= stride)
            let rowStart = destination.advanced(by: rowIndex * stride)
            for column in 0 ..< stride {
                rowStart[column] = 0xEE
            }
            for (column, value) in row.enumerated() {
                rowStart[column] = value
            }
        }
    }

    private func planeRows(
        _ buffer: CVPixelBuffer,
        plane: Int,
        byteWidth: Int,
        height: Int
    ) throws -> [[UInt8]] {
        try #require(plane >= 0)
        try #require(plane < CVPixelBufferGetPlaneCount(buffer))
        try #require(byteWidth >= 0)
        try #require(height >= 0)
        try #require(height <= CVPixelBufferGetHeightOfPlane(buffer, plane))

        let lockStatus = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        try #require(lockStatus == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let baseAddress = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        try #require(stride >= byteWidth)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        return (0 ..< height).map { row in
            Array(UnsafeBufferPointer(start: bytes.advanced(by: row * stride), count: byteWidth))
        }
    }

    private func expectAttachment(
        _ key: CFString,
        equals expected: CFTypeRef,
        on buffer: CVPixelBuffer
    ) throws {
        var mode = CVAttachmentMode.shouldNotPropagate
        let value = try #require(CVBufferCopyAttachment(buffer, key, &mode))
        #expect(mode == .shouldPropagate)
        #expect(CFEqual(value, expected))
    }
}
