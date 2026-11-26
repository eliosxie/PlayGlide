import CoreImage
import Metal
import MetalFX

/// Confined to one renderer/executor; all commands use the caller's serial Metal queue.
final class SpatialUpscaler {
    private let device: any MTLDevice
    private var scaler: (any MTLFXSpatialScaler)?
    private var inputTexture: (any MTLTexture)?
    private var outputTexture: (any MTLTexture)?

    init(device: any MTLDevice) { self.device = device }

    func prepare(input: VideoSize, output: VideoSize) throws -> (
        input: any MTLTexture, output: any MTLTexture, scaler: any MTLFXSpatialScaler
    ) {
        try configure(input: input, output: output)
        guard let scaler, let inputTexture, let outputTexture else {
            throw PipelineError(AppText("Spatial 资源不可用", "MetalFX Spatial resources are unavailable."))
        }
        scaler.colorTexture = inputTexture
        scaler.outputTexture = outputTexture
        scaler.inputContentWidth = input.width
        scaler.inputContentHeight = input.height
        return (inputTexture, outputTexture, scaler)
    }

    func encode(
        _ image: CIImage, input: VideoSize, output: VideoSize,
        context: CIContext, command: any MTLCommandBuffer
    ) throws -> CIImage {
        let resources = try prepare(input: input, output: output)
        context.render(
            image, to: resources.input, commandBuffer: command,
            bounds: image.extent, colorSpace: PixelConverter.sRGB)
        resources.scaler.encode(commandBuffer: command)
        guard let result = CIImage(mtlTexture: resources.output, options: [.colorSpace: PixelConverter.sRGB]) else {
            throw PipelineError(AppText("无法读取 Spatial 输出", "Could not read MetalFX Spatial output."))
        }
        return result
    }

    private func configure(input: VideoSize, output: VideoSize) throws {
        if inputTexture?.width == input.width, inputTexture?.height == input.height,
            outputTexture?.width == output.width, outputTexture?.height == output.height
        {
            return
        }
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = input.width
        descriptor.inputHeight = input.height
        descriptor.outputWidth = output.width
        descriptor.outputHeight = output.height
        descriptor.colorTextureFormat = .bgra8Unorm
        descriptor.outputTextureFormat = .bgra8Unorm
        descriptor.colorProcessingMode = .perceptual
        guard let scaler = descriptor.makeSpatialScaler(device: device) else {
            throw PipelineError(
                AppText("MetalFX 不接受此输入/输出尺寸", "MetalFX does not support these input and output resolutions."))
        }
        let source = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: input.width,
            height: input.height, mipmapped: false)
        source.storageMode = .private
        source.usage = scaler.colorTextureUsage.union([.renderTarget, .shaderRead, .shaderWrite])
        let destination = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: output.width,
            height: output.height, mipmapped: false)
        destination.storageMode = .private
        destination.usage = scaler.outputTextureUsage.union([.renderTarget, .shaderRead, .shaderWrite])
        guard let sourceTexture = device.makeTexture(descriptor: source),
            let destinationTexture = device.makeTexture(descriptor: destination)
        else { throw PipelineError(AppText("MetalFX 纹理分配失败", "Could not allocate MetalFX textures.")) }
        self.scaler = scaler
        inputTexture = sourceTexture
        outputTexture = destinationTexture
    }
}
