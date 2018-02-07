//
//  Renderer.swift
//  MetalAR
//
//  Created by naru on 2018/01/31.
//  Copyright © 2018年 naru. All rights reserved.
//

import Foundation
import MetalKit
import MetalPerformanceShaders
import ARKit

protocol RenderDelegate: class {
    func renderer(_ renderer: Renderer, didFinishProcess texture: MTLTexture)
}

// The max number of command buffers in flight
let kMaxBuffersInFlight: Int = 3

// The max number anchors our uniform buffer will hold
let kMaxAnchorInstanceCount: Int = 64
let kMaxPlaneAnchorInstanceCount: Int = 64

// The 16 byte aligned size of our uniform structures
let kAlignedSharedUniformsSize: Int = (MemoryLayout<SharedUniforms>.size & ~0xFF) + 0x100
let kAlignedInstanceUniformsSize: Int = ((MemoryLayout<InstanceUniforms>.size * kMaxAnchorInstanceCount) & ~0xFF) + 0x100

// Vertex data for an image plane
let kImagePlaneVertexData: [Float] = [
    -1.0, -1.0,  0.0, 1.0,
    1.0, -1.0,  1.0, 1.0,
    -1.0,  1.0,  0.0, 0.0,
    1.0,  1.0,  1.0, 0.0,
]

/// Rendering all objects.
class Renderer {
    
    struct Constants {
        static let DepthStencilPixelFormat: MTLPixelFormat = .depth32Float_stencil8
        static let ColorPixelFormat: MTLPixelFormat = .bgra8Unorm
        static let SampleCount: Int = 1
    }
    
    init(session: ARSession, metalDevice device: MTLDevice) {
        self.session = session
        self.device = device
        loadMetal()
        loadAssets()
    }
    
    // MARK: - Elements
    
    let session: ARSession
    let device: MTLDevice
    let inFlightSemaphore = DispatchSemaphore(value: kMaxBuffersInFlight)
    
    // Metal objects
    var commandQueue: MTLCommandQueue!
    var sharedUniformBuffer: MTLBuffer!
    var anchorUniformBuffer: MTLBuffer!
    var planeAnchorUniformBuffer: MTLBuffer!
    var imagePlaneVertexBuffer: MTLBuffer!
    var capturedImagePipelineState: MTLRenderPipelineState!
    var capturedImageDepthState: MTLDepthStencilState!
    var anchorPipelineState: MTLRenderPipelineState!
    var anchorDepthState: MTLDepthStencilState!
    var capturedImageTextureY: CVMetalTexture?
    var capturedImageTextureCbCr: CVMetalTexture?
    var capturedImageWidth: Int = 0
    var capturedImageHeight: Int = 0
    
    // Captured image texture cache
    var capturedImageTextureCache: CVMetalTextureCache!
    
    // Metal vertex descriptor specifying how vertices will by laid out for input into our
    //   anchor geometry render pipeline and how we'll layout our Model IO verticies
    var geometryVertexDescriptor: MTLVertexDescriptor!
    
    // MetalKit mesh containing vertex data and index buffer for our anchor geometry
    var instanceMesh: MTKMesh!
    
    // MetalKit mesh containing vertex data and index buffer for our plane anchor geometry
    var planeMesh: MTKMesh!
    
    // Used to determine _uniformBufferStride each frame.
    //   This is the current frame number modulo kMaxBuffersInFlight
    var uniformBufferIndex: Int = 0
    
    // Offset within sharedUniformBuffer to set for the current frame
    var sharedUniformBufferOffset: Int = 0
    
    // Offset within anchorUniformBuffer to set for the current frame
    var anchorUniformBufferOffset: Int = 0
    
    // Offset within planeAnchorUniformBuffer to set for the current frame
    var planeAnchorUniformBufferOffset: Int = 0
    
    // Addresses to write shared uniforms to each frame
    var sharedUniformBufferAddress: UnsafeMutableRawPointer!
    
    // Addresses to write anchor uniforms to each frame
    var anchorUniformBufferAddress: UnsafeMutableRawPointer!
    
    // Addresses to write plane anchor uniforms to each frame
    var planeAnchorUniformBufferAddress: UnsafeMutableRawPointer!
    
    // The number of anchor instances to render
    var anchorInstanceCount: Int = 0
    
    // The number of plane anchor instances to render
    var planeAnchorInstanceCount: Int = 0
    
    // The current viewport size
    var viewportSize: CGSize = CGSize()
    
    // Flag for viewport size changes
    var viewportSizeDidChange: Bool = false
    
    /// RendererDeleagte
    weak var delegate: RenderDelegate?
    
    // MARK: - Metal Performance Shader
    
    lazy var sobel: MPSImageSobel = {
        return MPSImageSobel(device: device)
    }()
    
    // MARK: - Update
    
    func drawRectResized(size: CGSize) {
        viewportSize = size
        viewportSizeDidChange = true
        capturedImageWidth = Int(viewportSize.width*UIScreen.main.scale)
        capturedImageHeight = Int(viewportSize.height*UIScreen.main.scale)
    }
    
    func update() {
        // Wait to ensure only kMaxBuffersInFlight are getting proccessed by any stage in the Metal
        //   pipeline (App, Metal, Drivers, GPU, etc)
        let _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)
        
        // Create a new command buffer for each renderpass to the current drawable
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }
        commandBuffer.label = "ARDrawingCommand"
        
        // Add completion hander which signal _inFlightSemaphore when Metal and the GPU has fully
        //   finished proccssing the commands we're encoding this frame.  This indicates when the
        //   dynamic buffers, that we're writing to this frame, will no longer be needed by Metal
        //   and the GPU.
        // Retain our CVMetalTextures for the duration of the rendering cycle. The MTLTextures
        //   we use from the CVMetalTextures are not valid unless their parent CVMetalTextures
        //   are retained. Since we may release our CVMetalTexture ivars during the rendering
        //   cycle, we must retain them separately here.
        var textures = [capturedImageTextureY, capturedImageTextureCbCr]
        
        updateBufferStates()
        updateGameState()
        
        guard capturedImageWidth > 0 && capturedImageHeight > 0 else {
            inFlightSemaphore.signal()
            return
        }
        
        let textureDescriptor: MTLTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: capturedImageWidth, height: capturedImageHeight, mipmapped: false)
        let cameraSourceTexture: MTLTexture = device.makeTexture(descriptor: textureDescriptor)!
        let output: MTLTexture = device.makeTexture(descriptor: textureDescriptor)!
        
        commandBuffer.addCompletedHandler { [weak self] commandBuffer in
            if let strongSelf = self {
                strongSelf.delegate?.renderer(strongSelf, didFinishProcess: output)
                strongSelf.inFlightSemaphore.signal()
            }
            textures.removeAll()
        }
        
        // draw camera source
        let cameraSourceRenderPassDescriptor: MTLRenderPassDescriptor = MTLRenderPassDescriptor()
        cameraSourceRenderPassDescriptor.colorAttachments[0].texture = cameraSourceTexture
        cameraSourceRenderPassDescriptor.colorAttachments[0].loadAction = .dontCare
        cameraSourceRenderPassDescriptor.colorAttachments[0].storeAction = .store
        
        if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: cameraSourceRenderPassDescriptor) {
            renderEncoder.label = "camera source"
            drawCapturedImage(renderEncoder: renderEncoder)
            renderEncoder.endEncoding()
        }
        
        // sobel filter
        sobel.encode(commandBuffer: commandBuffer, sourceTexture: cameraSourceTexture, destinationTexture: output)
        
        // draw instances
        let drawingInstancesRenderPassDescriptor: MTLRenderPassDescriptor = MTLRenderPassDescriptor()
        drawingInstancesRenderPassDescriptor.colorAttachments[0].loadAction = .load
        drawingInstancesRenderPassDescriptor.colorAttachments[0].storeAction = .store
        drawingInstancesRenderPassDescriptor.colorAttachments[0].texture = output
        
        if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: drawingInstancesRenderPassDescriptor) {
            renderEncoder.label = "camera source"
            drawAnchorGeometry(renderEncoder: renderEncoder)
            drawPlaneAnchorGeometry(renderEncoder: renderEncoder)
            renderEncoder.endEncoding()
        }
        
        // Finalize rendering here & push the command buffer to the GPU
        commandBuffer.commit()
    }

    // MARK: - Private
    
    func loadMetal() {
        // Create and load our basic Metal state objects
        
        // Calculate our uniform buffer sizes. We allocate kMaxBuffersInFlight instances for uniform
        //   storage in a single buffer. This allows us to update uniforms in a ring (i.e. triple
        //   buffer the uniforms) so that the GPU reads from one slot in the ring wil the CPU writes
        //   to another. Anchor uniforms should be specified with a max instance count for instancing.
        //   Also uniform storage must be aligned (to 256 bytes) to meet the requirements to be an
        //   argument in the constant address space of our shading functions.
        let sharedUniformBufferSize = kAlignedSharedUniformsSize * kMaxBuffersInFlight
        let anchorUniformBufferSize = kAlignedInstanceUniformsSize * kMaxBuffersInFlight
        let planeAnchorUniformBufferSize = kAlignedInstanceUniformsSize * kMaxBuffersInFlight
        
        // Create and allocate our uniform buffer objects. Indicate shared storage so that both the
        //   CPU can access the buffer
        sharedUniformBuffer = device.makeBuffer(length: sharedUniformBufferSize, options: .storageModeShared)
        sharedUniformBuffer.label = "SharedUniformBuffer"
        
        anchorUniformBuffer = device.makeBuffer(length: anchorUniformBufferSize, options: .storageModeShared)
        anchorUniformBuffer.label = "AnchorUniformBuffer"
        
        planeAnchorUniformBuffer = device.makeBuffer(length: planeAnchorUniformBufferSize, options: .storageModeShared)
        planeAnchorUniformBuffer.label = "PlaneAnchorUniformBuffer"
        
        // Create a vertex buffer with our image plane vertex data.
        let imagePlaneVertexDataCount = kImagePlaneVertexData.count * MemoryLayout<Float>.size
        imagePlaneVertexBuffer = device.makeBuffer(bytes: kImagePlaneVertexData, length: imagePlaneVertexDataCount, options: [])
        imagePlaneVertexBuffer.label = "ImagePlaneVertexBuffer"
        
        // Load all the shader files with a metal file extension in the project
        let defaultLibrary = device.makeDefaultLibrary()!
        
        let capturedImageVertexFunction = defaultLibrary.makeFunction(name: "capturedImageVertexTransform")!
        let capturedImageFragmentFunction = defaultLibrary.makeFunction(name: "capturedImageFragmentShader")!
        
        // Create a vertex descriptor for our image plane vertex buffer
        let imagePlaneVertexDescriptor = MTLVertexDescriptor()
        
        // Positions.
        imagePlaneVertexDescriptor.attributes[0].format = .float2
        imagePlaneVertexDescriptor.attributes[0].offset = 0
        imagePlaneVertexDescriptor.attributes[0].bufferIndex = Int(kBufferIndexMeshPositions.rawValue)
        
        // Texture coordinates.
        imagePlaneVertexDescriptor.attributes[1].format = .float2
        imagePlaneVertexDescriptor.attributes[1].offset = 8
        imagePlaneVertexDescriptor.attributes[1].bufferIndex = Int(kBufferIndexMeshPositions.rawValue)
        
        // Buffer Layout
        imagePlaneVertexDescriptor.layouts[0].stride = 16
        imagePlaneVertexDescriptor.layouts[0].stepRate = 1
        imagePlaneVertexDescriptor.layouts[0].stepFunction = .perVertex
        
        // Create a pipeline state for rendering the captured image
        let capturedImagePipelineStateDescriptor = MTLRenderPipelineDescriptor()
        capturedImagePipelineStateDescriptor.label = "MyCapturedImagePipeline"
        capturedImagePipelineStateDescriptor.sampleCount = Constants.SampleCount
        capturedImagePipelineStateDescriptor.vertexFunction = capturedImageVertexFunction
        capturedImagePipelineStateDescriptor.fragmentFunction = capturedImageFragmentFunction
        capturedImagePipelineStateDescriptor.vertexDescriptor = imagePlaneVertexDescriptor
        capturedImagePipelineStateDescriptor.colorAttachments[0].pixelFormat = Constants.ColorPixelFormat
        capturedImagePipelineStateDescriptor.depthAttachmentPixelFormat = Constants.DepthStencilPixelFormat
        capturedImagePipelineStateDescriptor.stencilAttachmentPixelFormat = Constants.DepthStencilPixelFormat
        
        do {
            try capturedImagePipelineState = device.makeRenderPipelineState(descriptor: capturedImagePipelineStateDescriptor)
        } catch let error {
            print("Failed to created captured image pipeline state, error \(error)")
        }
        
        let capturedImageDepthStateDescriptor = MTLDepthStencilDescriptor()
        capturedImageDepthStateDescriptor.depthCompareFunction = .always
        capturedImageDepthStateDescriptor.isDepthWriteEnabled = false
        capturedImageDepthState = device.makeDepthStencilState(descriptor: capturedImageDepthStateDescriptor)
        
        // Create captured image texture cache
        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        capturedImageTextureCache = textureCache
        
        let anchorGeometryVertexFunction = defaultLibrary.makeFunction(name: "anchorGeometryVertexTransform")!
        let anchorGeometryFragmentFunction = defaultLibrary.makeFunction(name: "anchorGeometryFragmentLighting")!
        
        // Create a vertex descriptor for our Metal pipeline. Specifies the layout of vertices the
        //   pipeline should expect. The layout below keeps attributes used to calculate vertex shader
        //   output position separate (world position, skinning, tweening weights) separate from other
        //   attributes (texture coordinates, normals).  This generally maximizes pipeline efficiency
        geometryVertexDescriptor = MTLVertexDescriptor()
        
        // Positions.
        geometryVertexDescriptor.attributes[0].format = .float3
        geometryVertexDescriptor.attributes[0].offset = 0
        geometryVertexDescriptor.attributes[0].bufferIndex = Int(kBufferIndexMeshPositions.rawValue)
        
        // Texture coordinates.
        geometryVertexDescriptor.attributes[1].format = .float2
        geometryVertexDescriptor.attributes[1].offset = 0
        geometryVertexDescriptor.attributes[1].bufferIndex = Int(kBufferIndexMeshGenerics.rawValue)
        
        // Normals.
        geometryVertexDescriptor.attributes[2].format = .half3
        geometryVertexDescriptor.attributes[2].offset = 8
        geometryVertexDescriptor.attributes[2].bufferIndex = Int(kBufferIndexMeshGenerics.rawValue)
        
        // Position Buffer Layout
        geometryVertexDescriptor.layouts[0].stride = 12
        geometryVertexDescriptor.layouts[0].stepRate = 1
        geometryVertexDescriptor.layouts[0].stepFunction = .perVertex
        
        // Generic Attribute Buffer Layout
        geometryVertexDescriptor.layouts[1].stride = 16
        geometryVertexDescriptor.layouts[1].stepRate = 1
        geometryVertexDescriptor.layouts[1].stepFunction = .perVertex
        
        // Create a reusable pipeline state for rendering anchor geometry
        let anchorPipelineStateDescriptor = MTLRenderPipelineDescriptor()
        anchorPipelineStateDescriptor.label = "MyAnchorPipeline"
        anchorPipelineStateDescriptor.sampleCount = Constants.SampleCount
        anchorPipelineStateDescriptor.vertexFunction = anchorGeometryVertexFunction
        anchorPipelineStateDescriptor.fragmentFunction = anchorGeometryFragmentFunction
        anchorPipelineStateDescriptor.vertexDescriptor = geometryVertexDescriptor
        anchorPipelineStateDescriptor.colorAttachments[0].pixelFormat = Constants.ColorPixelFormat
        anchorPipelineStateDescriptor.depthAttachmentPixelFormat = Constants.DepthStencilPixelFormat
        anchorPipelineStateDescriptor.stencilAttachmentPixelFormat = Constants.DepthStencilPixelFormat
        
        do {
            try anchorPipelineState = device.makeRenderPipelineState(descriptor: anchorPipelineStateDescriptor)
        } catch let error {
            print("Failed to created anchor geometry pipeline state, error \(error)")
        }
        
        let anchorDepthStateDescriptor = MTLDepthStencilDescriptor()
        anchorDepthStateDescriptor.depthCompareFunction = .less
        anchorDepthStateDescriptor.isDepthWriteEnabled = true
        anchorDepthState = device.makeDepthStencilState(descriptor: anchorDepthStateDescriptor)
        
        // Create the command queue
        commandQueue = device.makeCommandQueue()
    }
    
    func loadAssets() {
        // Create and load our assets into Metal objects including meshes and textures
        
        // Create a MetalKit mesh buffer allocator so that ModelIO will load mesh data directly into
        //   Metal buffers accessible by the GPU
        let metalAllocator = MTKMeshBufferAllocator(device: device)
        
        // Creata a Model IO vertexDescriptor so that we format/layout our model IO mesh vertices to
        //   fit our Metal render pipeline's vertex descriptor layout
        let vertexDescriptor = MTKModelIOVertexDescriptorFromMetal(geometryVertexDescriptor)
        
        // Indicate how each Metal vertex descriptor attribute maps to each ModelIO attribute
        (vertexDescriptor.attributes[Int(VertexAttributes.position.rawValue)] as! MDLVertexAttribute).name = MDLVertexAttributePosition
        (vertexDescriptor.attributes[Int(VertexAttributes.texcoord.rawValue)] as! MDLVertexAttribute).name = MDLVertexAttributeTextureCoordinate
        (vertexDescriptor.attributes[Int(VertexAttributes.normal.rawValue)] as! MDLVertexAttribute).name   = MDLVertexAttributeNormal
        
        // Use ModelIO to create a box mesh as our object
        let instanceMeshModel = MDLMesh.newCapsule(withHeight: 0.1, radii: float2(0.05, 0.05), radialSegments: 20, verticalSegments: 10, hemisphereSegments: 10, geometryType: .triangles, inwardNormals: false, allocator: metalAllocator)
        
        // Perform the format/relayout of mesh vertices by setting the new vertex descriptor in our
        //   Model IO mesh
        instanceMeshModel.vertexDescriptor = vertexDescriptor
        
        // Use ModelIO to create a box mesh as our object
        let planeMeshModel = MDLMesh(planeWithExtent: float3(1.0, 1.0, 1.0), segments: uint2(30, 30), geometryType: .lines, allocator: metalAllocator)
        
        // Perform the format/relayout of mesh vertices by setting the new vertex descriptor in our
        //   Model IO mesh
        planeMeshModel.vertexDescriptor = vertexDescriptor
        
        // Create a MetalKit mesh (and submeshes) backed by Metal buffers
        do {
            try instanceMesh = MTKMesh(mesh: instanceMeshModel, device: device)
            try planeMesh = MTKMesh(mesh: planeMeshModel, device: device)
        } catch let error {
            print("Error creating MetalKit mesh, error \(error)")
        }
    }
    
    func updateBufferStates() {
        // Update the location(s) to which we'll write to in our dynamically changing Metal buffers for
        //   the current frame (i.e. update our slot in the ring buffer used for the current frame)
        
        uniformBufferIndex = (uniformBufferIndex + 1) % kMaxBuffersInFlight
        
        sharedUniformBufferOffset = kAlignedSharedUniformsSize * uniformBufferIndex
        anchorUniformBufferOffset = kAlignedInstanceUniformsSize * uniformBufferIndex
        planeAnchorUniformBufferOffset = kAlignedInstanceUniformsSize * uniformBufferIndex
        
        sharedUniformBufferAddress = sharedUniformBuffer.contents().advanced(by: sharedUniformBufferOffset)
        anchorUniformBufferAddress = anchorUniformBuffer.contents().advanced(by: anchorUniformBufferOffset)
        planeAnchorUniformBufferAddress = planeAnchorUniformBuffer.contents().advanced(by: planeAnchorUniformBufferOffset)
    }
    
    func updateGameState() {
        // Update any game state
        
        guard let currentFrame = session.currentFrame else {
            return
        }
        
        updateSharedUniforms(frame: currentFrame)
        updateAnchors(frame: currentFrame)
        updatePlaneAnchors(frame: currentFrame)
        updateCapturedImageTextures(frame: currentFrame)
        
        if viewportSizeDidChange {
            viewportSizeDidChange = false
            
            updateImagePlane(frame: currentFrame)
        }
    }
    
    func updateSharedUniforms(frame: ARFrame) {
        // Update the shared uniforms of the frame
        
        let uniforms = sharedUniformBufferAddress.assumingMemoryBound(to: SharedUniforms.self)
        
        uniforms.pointee.viewMatrix = frame.camera.viewMatrix(for: .portrait)
        uniforms.pointee.projectionMatrix = frame.camera.projectionMatrix(for: .portrait, viewportSize: viewportSize, zNear: 0.001, zFar: 1000)

        // Set up lighting for the scene using the ambient intensity if provided
        var ambientIntensity: Float = 1.0
        
        if let lightEstimate = frame.lightEstimate {
            ambientIntensity = Float(lightEstimate.ambientIntensity) / 1000.0
        }
        
        let ambientLightColor: vector_float3 = vector3(0.5, 0.5, 0.5)
        uniforms.pointee.ambientLightColor = ambientLightColor * ambientIntensity
        
        var directionalLightDirection : vector_float3 = vector3(0.0, 0.0, -1.0)
        directionalLightDirection = simd_normalize(directionalLightDirection)
        uniforms.pointee.directionalLightDirection = directionalLightDirection
        
        let directionalLightColor: vector_float3 = vector3(0.6, 0.6, 0.6)
        uniforms.pointee.directionalLightColor = directionalLightColor * ambientIntensity
        
        uniforms.pointee.materialShininess = 30
    }
    
    func updateAnchors(frame: ARFrame) {
        
        let anchors: [ARAnchor] = frame.anchors.filter({ !$0.isKind(of: ARPlaneAnchor.self) })
        
        // Update the anchor uniform buffer with transforms of the current frame's anchors
        anchorInstanceCount = min(anchors.count, kMaxAnchorInstanceCount)
        
        var anchorOffset: Int = 0
        if anchorInstanceCount == kMaxAnchorInstanceCount {
            anchorOffset = max(anchors.count - kMaxAnchorInstanceCount, 0)
        }
        
        for index in 0..<anchorInstanceCount {
            let anchor = anchors[index + anchorOffset]
            
            // Flip Z axis to convert geometry from right handed to left handed
            var coordinateSpaceTransform = matrix_identity_float4x4
            coordinateSpaceTransform.columns.2.z = -1.0
            
            let modelMatrix = simd_mul(anchor.transform, coordinateSpaceTransform)
            
            let anchorUniforms = anchorUniformBufferAddress.assumingMemoryBound(to: InstanceUniforms.self).advanced(by: index)
            anchorUniforms.pointee.modelMatrix = modelMatrix
        }
    }
    
    func updatePlaneAnchors(frame: ARFrame) {
        
        let anchors: [ARPlaneAnchor] = frame.anchors.filter({ $0.isKind(of: ARPlaneAnchor.self) }) as! [ARPlaneAnchor]
        
        // Update the anchor uniform buffer with transforms of the current frame's anchors
        planeAnchorInstanceCount = min(anchors.count, kMaxPlaneAnchorInstanceCount)
        
        var anchorOffset: Int = 0
        if planeAnchorInstanceCount == kMaxPlaneAnchorInstanceCount {
            anchorOffset = max(anchors.count - kMaxPlaneAnchorInstanceCount, 0)
        }
        
        for index in 0..<planeAnchorInstanceCount {
            let anchor = anchors[index + anchorOffset]
            
            // Flip Z axis to convert geometry from right handed to left handed
            var coordinateSpaceTransform = matrix_identity_float4x4
            coordinateSpaceTransform.columns.2.z = -1.0
            
            let rotation = matrix4x4_rotation(radians: float.pi/2.0, axis: float3(0.0, 0.0, 1.0))
            let modelMatrix = simd_mul(anchor.transform, simd_mul(rotation, coordinateSpaceTransform))
            
            let anchorUniforms = planeAnchorUniformBufferAddress.assumingMemoryBound(to: InstanceUniforms.self).advanced(by: index)
            anchorUniforms.pointee.modelMatrix = modelMatrix
        }
    }
    
    func updateCapturedImageTextures(frame: ARFrame) {
        // Create two textures (Y and CbCr) from the provided frame's captured image
        let pixelBuffer = frame.capturedImage
        
        if (CVPixelBufferGetPlaneCount(pixelBuffer) < 2) {
            return
        }
        
        capturedImageTextureY = createTexture(fromPixelBuffer: pixelBuffer, pixelFormat:.r8Unorm, planeIndex:0)
        capturedImageTextureCbCr = createTexture(fromPixelBuffer: pixelBuffer, pixelFormat:.rg8Unorm, planeIndex:1)
    }
    
    func createTexture(fromPixelBuffer pixelBuffer: CVPixelBuffer, pixelFormat: MTLPixelFormat, planeIndex: Int) -> CVMetalTexture? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
        
        var texture: CVMetalTexture? = nil
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, capturedImageTextureCache, pixelBuffer, nil, pixelFormat, width, height, planeIndex, &texture)
        
        if status != kCVReturnSuccess {
            texture = nil
        }
        
        return texture
    }
    
    func updateImagePlane(frame: ARFrame) {
        // Update the texture coordinates of our image plane to aspect fill the viewport
        let displayToCameraTransform = frame.displayTransform(for: .portrait, viewportSize: viewportSize).inverted()

        let vertexData = imagePlaneVertexBuffer.contents().assumingMemoryBound(to: Float.self)
        for index in 0...3 {
            let textureCoordIndex = 4 * index + 2
            let textureCoord = CGPoint(x: CGFloat(kImagePlaneVertexData[textureCoordIndex]), y: CGFloat(kImagePlaneVertexData[textureCoordIndex + 1]))
            let transformedCoord = textureCoord.applying(displayToCameraTransform)
            vertexData[textureCoordIndex] = Float(transformedCoord.x)
            vertexData[textureCoordIndex + 1] = Float(transformedCoord.y)
        }
    }
    
    func drawCapturedImage(renderEncoder: MTLRenderCommandEncoder) {
        guard let textureY = capturedImageTextureY, let textureCbCr = capturedImageTextureCbCr else {
            return
        }
        
        // Push a debug group allowing us to identify render commands in the GPU Frame Capture tool
        renderEncoder.pushDebugGroup("DrawCapturedImage")
        
        // Set render command encoder state
        renderEncoder.setCullMode(.none)
        renderEncoder.setRenderPipelineState(capturedImagePipelineState)
        renderEncoder.setDepthStencilState(capturedImageDepthState)
        
        // Set mesh's vertex buffers
        renderEncoder.setVertexBuffer(imagePlaneVertexBuffer, offset: 0, index: Int(kBufferIndexMeshPositions.rawValue))
        
        // Set any textures read/sampled from our render pipeline
        renderEncoder.setFragmentTexture(CVMetalTextureGetTexture(textureY), index: Int(kTextureIndexY.rawValue))
        renderEncoder.setFragmentTexture(CVMetalTextureGetTexture(textureCbCr), index: Int(kTextureIndexCbCr.rawValue))
        
        // Draw each submesh of our mesh
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        
        renderEncoder.popDebugGroup()
    }
    
    func drawAnchorGeometry(renderEncoder: MTLRenderCommandEncoder) {
        guard anchorInstanceCount > 0 else {
            return
        }
        
        // Push a debug group allowing us to identify render commands in the GPU Frame Capture tool
        renderEncoder.pushDebugGroup("DrawAnchors")
        
        // Set render command encoder state
        renderEncoder.setCullMode(.back)
        renderEncoder.setRenderPipelineState(anchorPipelineState)
        renderEncoder.setDepthStencilState(anchorDepthState)
        
        // Set any buffers fed into our render pipeline
        renderEncoder.setVertexBuffer(anchorUniformBuffer, offset: anchorUniformBufferOffset, index: Int(kBufferIndexInstanceUniforms.rawValue))
        renderEncoder.setVertexBuffer(sharedUniformBuffer, offset: sharedUniformBufferOffset, index: Int(kBufferIndexSharedUniforms.rawValue))
        renderEncoder.setFragmentBuffer(sharedUniformBuffer, offset: sharedUniformBufferOffset, index: Int(kBufferIndexSharedUniforms.rawValue))
        
        // Set mesh's vertex buffers
        for bufferIndex in 0..<instanceMesh.vertexBuffers.count {
            let vertexBuffer = instanceMesh.vertexBuffers[bufferIndex]
            renderEncoder.setVertexBuffer(vertexBuffer.buffer, offset: vertexBuffer.offset, index:bufferIndex)
        }
        
        // Draw each submesh of our mesh
        for submesh in instanceMesh.submeshes {
            renderEncoder.drawIndexedPrimitives(type: submesh.primitiveType, indexCount: submesh.indexCount, indexType: submesh.indexType, indexBuffer: submesh.indexBuffer.buffer, indexBufferOffset: submesh.indexBuffer.offset, instanceCount: anchorInstanceCount)
        }
        
        renderEncoder.popDebugGroup()
    }
    
    func drawPlaneAnchorGeometry(renderEncoder: MTLRenderCommandEncoder) {
        guard planeAnchorInstanceCount > 0 else {
            return
        }
        
        // Push a debug group allowing us to identify render commands in the GPU Frame Capture tool
        renderEncoder.pushDebugGroup("DrawPlaneAnchors")
        
        // Set render command encoder state
        renderEncoder.setCullMode(.back)
        renderEncoder.setRenderPipelineState(anchorPipelineState)
        renderEncoder.setDepthStencilState(anchorDepthState)
        
        // Set any buffers fed into our render pipeline
        renderEncoder.setVertexBuffer(planeAnchorUniformBuffer, offset: planeAnchorUniformBufferOffset, index: Int(kBufferIndexInstanceUniforms.rawValue))
        renderEncoder.setVertexBuffer(sharedUniformBuffer, offset: sharedUniformBufferOffset, index: Int(kBufferIndexSharedUniforms.rawValue))
        renderEncoder.setFragmentBuffer(sharedUniformBuffer, offset: sharedUniformBufferOffset, index: Int(kBufferIndexSharedUniforms.rawValue))
        
        // Set mesh's vertex buffers
        for bufferIndex in 0..<planeMesh.vertexBuffers.count {
            let vertexBuffer = planeMesh.vertexBuffers[bufferIndex]
            renderEncoder.setVertexBuffer(vertexBuffer.buffer, offset: vertexBuffer.offset, index:bufferIndex)
        }
        
        // Draw each submesh of our mesh
        for submesh in planeMesh.submeshes {
            renderEncoder.drawIndexedPrimitives(type: submesh.primitiveType, indexCount: submesh.indexCount, indexType: submesh.indexType, indexBuffer: submesh.indexBuffer.buffer, indexBufferOffset: submesh.indexBuffer.offset, instanceCount: planeAnchorInstanceCount)
        }
        
        renderEncoder.popDebugGroup()
    }
}
