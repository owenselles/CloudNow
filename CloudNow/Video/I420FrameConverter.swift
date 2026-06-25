import Accelerate
import CoreVideo
import LiveKitWebRTC
import os

final class I420FrameConverter: @unchecked Sendable {
    private final nonisolated class PoolBox: @unchecked Sendable {
        let pool: CVPixelBufferPool

        init(_ pool: CVPixelBufferPool) {
            self.pool = pool
        }
    }

    private nonisolated struct PoolState: @unchecked Sendable {
        var width = 0
        var height = 0
        var poolBox: PoolBox?
    }

    private static let allocationThreshold = 6
    private let poolState = OSAllocatedUnfairLock(initialState: PoolState())

    func convert(_ i420: LKRTCI420Buffer) -> CVPixelBuffer? {
        let width = Int(i420.width)
        let height = Int(i420.height)
        guard width > 0, height > 0, let poolBox = pixelBufferPool(width: width, height: height) else {
            return nil
        }

        let auxiliaryAttributes = [
            kCVPixelBufferPoolAllocationThresholdKey as String: Self.allocationThreshold,
        ] as CFDictionary
        var pixelBuffer: CVPixelBuffer?
        let allocationStatus = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            poolBox.pool,
            auxiliaryAttributes,
            &pixelBuffer
        )
        guard allocationStatus == kCVReturnSuccess, let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard copyLuma(i420, to: pixelBuffer, width: width, height: height),
              interleaveChroma(i420, to: pixelBuffer, width: width, height: height)
        else {
            return nil
        }
        applySDRColorAttachments(to: pixelBuffer)
        return pixelBuffer
    }

    private func pixelBufferPool(width: Int, height: Int) -> PoolBox? {
        poolState.withLock { state in
            if state.width == width, state.height == height, let poolBox = state.poolBox {
                return poolBox
            }

            let poolAttributes = [
                kCVPixelBufferPoolMinimumBufferCountKey as String: 3,
            ] as CFDictionary
            let pixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferBytesPerRowAlignmentKey as String: 64,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]

            var createdPool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                poolAttributes,
                pixelBufferAttributes as CFDictionary,
                &createdPool
            )
            guard status == kCVReturnSuccess else {
                state = PoolState()
                return nil
            }

            state.width = width
            state.height = height
            guard let createdPool else { return nil }
            let poolBox = PoolBox(createdPool)
            state.poolBox = poolBox
            return poolBox
        }
    }

    private func copyLuma(
        _ i420: LKRTCI420Buffer,
        to pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int
    ) -> Bool {
        guard let destination = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return false }
        let sourceStride = Int(i420.strideY)
        let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)

        if sourceStride == width, destinationStride == width {
            memcpy(destination, i420.dataY, width * height)
            return true
        }
        for row in 0 ..< height {
            memcpy(
                destination.advanced(by: row * destinationStride),
                i420.dataY.advanced(by: row * sourceStride),
                width
            )
        }
        return true
    }

    private func interleaveChroma(
        _ i420: LKRTCI420Buffer,
        to pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int
    ) -> Bool {
        guard let destination = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return false }
        let chromaWidth = (width + 1) / 2
        let chromaHeight = (height + 1) / 2
        let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

        var uBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: i420.dataU),
            height: vImagePixelCount(chromaHeight),
            width: vImagePixelCount(chromaWidth),
            rowBytes: Int(i420.strideU)
        )
        var vBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: i420.dataV),
            height: vImagePixelCount(chromaHeight),
            width: vImagePixelCount(chromaWidth),
            rowBytes: Int(i420.strideV)
        )

        return withUnsafePointer(to: &uBuffer) { uPointer in
            withUnsafePointer(to: &vBuffer) { vPointer in
                var sourcePlanes: [UnsafePointer<vImage_Buffer>?] = [uPointer, vPointer]
                var destinationChannels: [UnsafeMutableRawPointer?] = [
                    destination,
                    destination.advanced(by: 1),
                ]
                return sourcePlanes.withUnsafeMutableBufferPointer { sourcePointers in
                    destinationChannels.withUnsafeMutableBufferPointer { destinationPointers in
                        vImageConvert_PlanarToChunky8(
                            sourcePointers.baseAddress!,
                            destinationPointers.baseAddress!,
                            2,
                            2,
                            vImagePixelCount(chromaWidth),
                            vImagePixelCount(chromaHeight),
                            destinationStride,
                            vImage_Flags(kvImageDoNotTile)
                        ) == kvImageNoError
                    }
                }
            }
        }
    }

    private func applySDRColorAttachments(to pixelBuffer: CVPixelBuffer) {
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferChromaLocationTopFieldKey,
            kCVImageBufferChromaLocation_Center,
            .shouldPropagate
        )
    }
}
