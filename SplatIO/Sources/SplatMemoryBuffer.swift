import Foundation

public struct SplatMemoryBuffer {
    private class BufferReader: SplatSceneReaderDelegate {
        enum Error: Swift.Error {
            case unknown
        }

        private let continuation: CheckedContinuation<[SplatScenePoint], Swift.Error>
        private var points: [SplatScenePoint] = []

        public init(continuation: CheckedContinuation<[SplatScenePoint], Swift.Error>) {
            self.continuation = continuation
        }

        public func didStartReading(withPointCount pointCount: UInt32?) {}

        public func didRead(points: [SplatIO.SplatScenePoint]) {
            self.points.append(contentsOf: points)
        }

        public func didFinishReading() {
            continuation.resume(returning: points)
        }

        public func didFailReading(withError error: Swift.Error?) {
            continuation.resume(throwing: error ?? BufferReader.Error.unknown)
        }
    }
    
    private class BufferReaderPicky: SplatSceneReaderDelegate {
        public var enforcePointMaximum = 0
        public var enforcePointSkip = 0
        public var numPoints = 0
        private var skippedPoints = 0
        
        enum Error: Swift.Error {
            case unknown
        }

        private let continuation: CheckedContinuation<[SplatScenePoint], Swift.Error>
        private var points: [SplatScenePoint] = []

        public init(continuation: CheckedContinuation<[SplatScenePoint], Swift.Error>) {
            self.continuation = continuation
        }

        public func didStartReading(withPointCount pointCount: UInt32?) {}

        public func didRead(points: [SplatIO.SplatScenePoint]) {
            // TODO ehhhh do this better
            self.numPoints += points.count
            if self.enforcePointSkip > 0 && self.skippedPoints < self.enforcePointSkip {
                self.skippedPoints += points.count
                return
            }
            if self.enforcePointMaximum > 0 && self.points.count >= self.enforcePointMaximum {
                return
            }

            self.points.append(contentsOf: points)
        }

        public func didFinishReading() {
            continuation.resume(returning: points)
        }

        public func didFailReading(withError error: Swift.Error?) {
            continuation.resume(throwing: error ?? BufferReader.Error.unknown)
        }
    }

    public var points: [SplatScenePoint] = []
    public var numPoints: Int = 0

    public init() {}

    /** Replace the content of points with the content read from the given SplatSceneReader. */
    mutating public func read(from reader: SplatSceneReader, _ skip: Int = 0, _ maxCount: Int = 0) async throws {
        points = try await withCheckedThrowingContinuation { continuation in
            if skip != 0 || maxCount != 0 {
                let bufferReader = BufferReaderPicky(continuation: continuation)
                bufferReader.enforcePointSkip = skip
                bufferReader.enforcePointMaximum = maxCount

                reader.read(to: bufferReader)
                numPoints = bufferReader.numPoints
            }
            else {
                let bufferReader = BufferReader(continuation: continuation)

                reader.read(to: bufferReader)
            }
        }
        
        if skip == 0 && maxCount == 0 {
            numPoints = points.count
        }
    }
}
