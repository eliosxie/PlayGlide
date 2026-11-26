#if PLAYGLIDE_DEVELOPMENT
    import CoreImage
    import CoreImage.CIFilterBuiltins
    import CoreMedia
    import CoreText
    import CoreVideo
    import Foundation

    struct TestPattern {
        static func image(size: VideoSize, time: Double, cut: Bool = false) -> CIImage {
            let width = Double(size.width)
            let height = Double(size.height)
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            let checker = CIFilter.checkerboardGenerator()
            checker.color0 =
                cut ? CIColor(red: 0.70, green: 0.65, blue: 0.60) : CIColor(red: 0.035, green: 0.065, blue: 0.09)
            checker.color1 =
                cut ? CIColor(red: 0.85, green: 0.75, blue: 0.60) : CIColor(red: 0.065, green: 0.12, blue: 0.15)
            checker.width = Float(width / 24)
            let background = checker.outputImage!.cropped(to: bounds)
            let x = width * (0.1 + 0.7 * (time.truncatingRemainder(dividingBy: 3) / 3))
            let block = CIImage(color: CIColor(red: cut ? 1 : 0.2, green: 0.85, blue: 0.66))
                .cropped(to: CGRect(x: x, y: height * 0.38, width: width * 0.13, height: height * 0.23))
            let bar = CIImage(color: CIColor(red: 0.95, green: 0.68, blue: 0.25))
                .cropped(to: CGRect(x: width - x, y: height * 0.23, width: max(4, width / 160), height: height * 0.54))
            let hud = CIImage(color: CIColor(red: 0.08, green: 0.14, blue: 0.21))
                .cropped(to: CGRect(x: width * 0.06, y: height * 0.08, width: width * 0.88, height: height * 0.1))
            return bar.composited(over: block.composited(over: hud.composited(over: background))).cropped(to: bounds)
        }
    }
    actor SyntheticVideoSource: VideoCaptureSource {
        let size: VideoSize
        let signal: TestSignal
        private let mailbox: FrameMailbox?
        private let generation: UUID
        private var task: Task<Void, Never>?
        private var continuation: AsyncThrowingStream<VideoFrame, Error>.Continuation?
        init(size: VideoSize, signal: TestSignal, mailbox: FrameMailbox? = nil, generation: UUID = UUID()) {
            self.size = size
            self.signal = signal
            self.mailbox = mailbox
            self.generation = generation
        }

        func start() async throws -> AsyncThrowingStream<VideoFrame, Error> {
            guard task == nil else { throw PipelineError(AppText("测试源已经启动", "The test pattern is already running.")) }
            let pair = AsyncThrowingStream<VideoFrame, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
            continuation = pair.continuation
            task = Task { await produce(pair.continuation) }
            return pair.stream
        }
        func stop() async {
            task?.cancel()
            continuation?.finish()
            let running = task
            task = nil
            continuation = nil
            await running?.value
        }
        private func produce(_ continuation: AsyncThrowingStream<VideoFrame, Error>.Continuation) async {
            do {
                let converter = PixelConverter()
                let pool = try PixelBufferPool(size: size, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                // Independent-buffer signals stand in for a capture card: every transport frame enters
                // through the same ingest as AVFoundation callbacks, timed from callback entry.
                let ingest = signal.copiesRepeatedBuffers ? CaptureFrameIngest() : nil
                let clock = ContinuousClock()
                let start = clock.now
                var sequence: Int64 = 0
                var previousContent: Int64 = -1
                var pixel: CVReadOnlyPixelBuffer?
                while !Task.isCancelled {
                    let (content, firstTransport) = signal.content(atTransport: sequence)
                    let pts = CMTimeMultiply(signal.transportDuration, multiplier: Int32(sequence))
                    if content != previousContent {
                        // Motion follows each picture's first transport time, so a held picture's successor has moved further.
                        let contentTime = Double(firstTransport) * signal.transportDuration.seconds
                        let cut = signal == .sceneCuts && Int(contentTime / 3) % 2 == 1
                        pixel = try converter.render(
                            TestPattern.image(size: size, time: contentTime, cut: cut), pool: pool)
                        previousContent = content
                    }
                    guard let pixel else {
                        throw PipelineError(AppText("测试画面生成失败", "Could not generate the test pattern."))
                    }
                    let arrival = mediaHostTime()
                    let frame: VideoFrame
                    if let ingest {
                        let owned = try pixel.withUnsafeBuffer { try ingest.ingest($0) }
                        frame = VideoFrame(
                            pixelBuffer: owned.pixelBuffer, presentationTime: pts, duration: signal.transportDuration,
                            sequence: sequence, arrivalTime: arrival)
                        mailbox?.recordCaptureIngest(
                            copied: owned.copied, seconds: mediaHostTime() - arrival,
                            surface: owned.changedDescription?.summary, generation: generation)
                    } else {
                        frame = VideoFrame(
                            pixelBuffer: pixel, presentationTime: pts, duration: signal.transportDuration,
                            sequence: sequence, arrivalTime: arrival)
                    }
                    mailbox?.capture(frame, generation: generation)
                    switch continuation.yield(frame) {
                    case .terminated: return
                    case .dropped(let dropped): mailbox?.recordInputOverwrite(dropped, generation: generation)
                    case .enqueued: break
                    @unknown default: break
                    }
                    sequence += 1
                    let deadline = start.advanced(by: .seconds(Double(sequence) * signal.transportDuration.seconds))
                    try await clock.sleep(until: deadline, tolerance: .milliseconds(1))
                    // Do not burst queued historical frames after a long stall.
                    let elapsed = start.duration(to: clock.now)
                    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                    sequence = max(sequence, Int64(seconds / signal.transportDuration.seconds))
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
#endif
