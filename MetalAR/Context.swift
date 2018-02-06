//
//  Context.swift
//  MetalAR
//
//  Created by naru on 2018/02/01.
//  Copyright © 2018年 naru. All rights reserved.
//

import Foundation
import Metal
import CoreVideo

class Context {
    
    init() {
        
        // MTLDevice
        guard let device: MTLDevice = MTLCreateSystemDefaultDevice() else {
            fatalError("Failed to create MTLDevice instance.")
        }
        self.device = device
        
        // MTLLibrary
        guard let library: MTLLibrary = device.makeDefaultLibrary() else {
            fatalError("Filed to create MTLLibrary instance.")
        }
        self.library = library
        
        // MTLCommandQueue
        guard let commandQueue: MTLCommandQueue = device.makeCommandQueue() else {
            fatalError("Filed to create MTLCommandQueue instance.")
        }
        self.commandQueue = commandQueue
        
        // CVMetalTextureCache
        var textureCache: CVMetalTextureCache?
        if CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache) != kCVReturnSuccess {
            fatalError("Failed to create texture cache.")
        }
        guard let _textureCache: CVMetalTextureCache = textureCache else {
            fatalError("Failed to get texture cache.")
        }
        self.textureCache = _textureCache
    }
    
    // MARK: - Elements
    
    let device: MTLDevice
    
    let library: MTLLibrary
    
    let commandQueue: MTLCommandQueue
    
    let textureCache: CVMetalTextureCache
}
