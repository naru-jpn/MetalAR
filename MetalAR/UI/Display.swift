//
//  Display.swift
//  MetalAR
//
//  Created by naru on 2018/02/01.
//  Copyright © 2018年 naru. All rights reserved.
//

import UIKit
import Metal
import CoreVideo
import CoreMedia

/// Draw applied texture on display.
class Display: UIView {
    
    init(frame: CGRect, context: Context) {
        self.context = context
        super.init(frame: frame)
        self.configure()
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Elements
    
    override class var layerClass: AnyClass {
        return CAMetalLayer.self
    }
    
    private var metalLayer: CAMetalLayer {
        return self.layer as! CAMetalLayer
    }
    
    let context: Context
    
    private var pipelineState: MTLRenderPipelineState!
    
    private var vertexBuffer: MTLBuffer!
    
    /// Set texture to draw and automatically draw texture.
    var texture: MTLTexture? {
        didSet {
            DispatchQueue.main.async {
                self.draw(.zero)
            }
        }
    }
    
    private var lastDisplayedTexture: MTLTexture?
    
    // MARK: - Configure
    
    private func configure() {
        
        // Layer
        
        metalLayer.device = context.device
        metalLayer.pixelFormat = .bgra8Unorm
        
        // Vertex buffer
        
        let vertices: [Float] = [
            -1, -1, 0, 1, // lower left
            -1,  1, 0, 0, // upper left
            1, -1, 1, 1, // lower right
            1,  1, 1, 0, // upper right
        ]
        vertexBuffer = context.device.makeBuffer(bytes: vertices, length: vertices.count*MemoryLayout<Float>.stride, options: [])
        
        let vertexDescriptor: MTLVertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2 // position
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float2 // texCoords
        vertexDescriptor.attributes[1].offset = 2 * MemoryLayout<Float>.size
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stepRate = 1
        vertexDescriptor.layouts[0].stepFunction = .perVertex
        vertexDescriptor.layouts[0].stride = 4 * MemoryLayout<Float>.size
        
        guard let library: MTLLibrary = context.device.makeDefaultLibrary() else {
            fatalError("Failed to get MTLLibrary on configuration.")
        }
        guard let vertexFunction: MTLFunction = library.makeFunction(name: "vertex_reshape") else {
            fatalError("Failed to make function 'vertex_reshape'.")
        }
        guard let fragmentFunction: MTLFunction = library.makeFunction(name: "fragment_texture") else {
            fatalError("Failed to make function 'fragment_texture'.")
        }
        
        let pipelineDescriptor: MTLRenderPipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.colorAttachments[0].pixelFormat = metalLayer.pixelFormat
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        try! pipelineState = context.device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
    
    // MARK: - Drawing
    
    override func draw(_ rect: CGRect) {
        drawTexture()
    }
    
    private func drawTexture() {
        
        guard let drawable: CAMetalDrawable = metalLayer.nextDrawable(), let texture: MTLTexture = self.texture else {
            return
        }
        
        let passDescriptor: MTLRenderPassDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].texture = drawable.texture
        
        // Currently view port size is equal to screen size so scaling matrix is identity.
        var scaling: matrix_float2x2 = matrix_identity_float2x2
        
        let commandBuffer: MTLCommandBuffer = context.commandQueue.makeCommandBuffer()!
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.lastDisplayedTexture = texture
        }
        
        let commandEncoder: MTLRenderCommandEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)!
        commandEncoder.setRenderPipelineState(pipelineState)
        commandEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        commandEncoder.setVertexBytes(&scaling, length: MemoryLayout<matrix_float2x2>.size, index: 1)
        commandEncoder.setFragmentTexture(texture, index: 0)
        commandEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        commandEncoder.endEncoding()
        
        commandBuffer.present(drawable)
        
        commandBuffer.commit()
    }
    
    // MARK: - Create Image
    
    /// Create and return image from last displayed texture.
    /// - returns: image created
    func currentCGImage(viewportSize: CGSize) -> CGImage? {
        
        guard let texture = lastDisplayedTexture else {
            return nil
        }
        
        let ratio: CGFloat = max(CGFloat(texture.width)/viewportSize.width, CGFloat(texture.height)/viewportSize.height)
        let width: Int = Int(viewportSize.width*ratio)
        let height: Int = Int(viewportSize.height*ratio)
        
        let rowBytes: Int = width * 4
        let length: Int = rowBytes * height
        let bytes: [UInt8] = [UInt8](repeating: 0, count: length)
        let region: MTLRegion = MTLRegionMake2D(0, 0, width, height)
        texture.getBytes(UnsafeMutableRawPointer(mutating: bytes), bytesPerRow: rowBytes, from: region, mipmapLevel: 0)
        
        let colorScape: CGColorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.first.rawValue)
        
        guard let data = CFDataCreate(nil, bytes, length) else {
            return nil
        }
        guard let provider = CGDataProvider(data: data) else {
            return nil
        }
        let result = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: colorScape, bitmapInfo: bitmapInfo, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        return result
    }
}
