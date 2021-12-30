//
//  ObjectRenderer.swift
//  test_metal
//
//  Created by Minoru Harada on 2021/11/20.
//

import Foundation
import Metal
import MetalKit
import simd

// The 256 byte aligned size of our uniform structure
let alignedUniformsSize = (MemoryLayout<Uniforms>.size + 0xFF) & -0x100
let maxBuffersInFlight = 3


class Sphere {
    var rotationAxis: SIMD3<Float> = SIMD3<Float>(0.0, 1.0, 0.0)
    var rotationRadians: Float = 0.0
    var position: SIMD3<Float> = SIMD3<Float>(0.0, 0.0, 0.0)
    
    var velocity: SIMD3<Float> = SIMD3<Float>(0.0, 0.0, 0.0)
    var acceleration: SIMD3<Float> = SIMD3<Float>(0.0, 0.0, 0.0)

    init(position: SIMD3<Float>, gravityCenter: SIMD3<Float>, velocity: Float) {
        let vec: SIMD3<Float> = (gravityCenter - position)
        
        let a_val: [Float] = [vec.x, vec.y, vec.z]
        let dimension = (m: 3, n: 1)
        let x = get_orthogonal_vector(vec: a_val,
                                      dimension: dimension)
        let acc: SIMD3<Float> = [
            Float.random(in: -1.0 ... 1.0),
            Float.random(in: -1.0 ... 1.0),
            Float.random(in: -1.0 ... 1.0)
        ]
        
        if let x = x {
            self.velocity     = velocity * acc
            self.acceleration = 1.0 * SIMD3<Float>(x[0], x[1], x[2])
        } else {
            self.acceleration = 4.0 * SIMD3<Float>(vec.x, -vec.y, 0)
        }
        self.position = position
    }

    func move(gravityCenter: SIMD3<Float>) {
        let dt = Float(0.1)
        
        // Update velocity based on acceleration
        self.velocity = self.velocity + dt * self.acceleration

        // Get the current velocity and position step
        self.position = self.position + dt * self.velocity
        self.acceleration = 0.1 * (gravityCenter - self.position)
    }
    
}


class ObjectRenderer {
    var pipelineState: MTLRenderPipelineState! = nil
    var depthStencilState: MTLDepthStencilState! = nil

    // for shadows
    var shadowPipelineState: MTLRenderPipelineState! = nil
    var shadowRenderPassDescriptor: MTLRenderPassDescriptor! = nil
    var shadowTexture: MTLTexture! = nil
    
    var dynamicUniformBuffer = [MTLBuffer]()
    var uniformBufferOffset = 0
    var uniformBufferIndex = 0

    var projectionMatrix: matrix_float4x4 = matrix_float4x4()

    let lightMatrix = matrix4x4_cameera_lookat(
        pos: SIMD3<Float>.init(0.0, 60.0, 10.0),
        lookat: SIMD3<Float>.init(0.0, 0.0, 0.0),
        up: SIMD3<Float>.init(0.0, 0.0, -1.0)).inverse
    
    let cameraMatrix = matrix4x4_cameera_lookat(
        pos: SIMD3<Float>.init(10.0, 20.0, 30.0),
        lookat: SIMD3<Float>.init(0.0, 0.0, 0.0),
        up: SIMD3<Float>.init(0.0, 1.0, 0.0)).inverse
    
    var mesh: [MTKMesh] = []
    var floor: MTKMesh! = nil
    var colorMap: MTLTexture! = nil
    var spheres: [Sphere] = []

    init?(device: MTLDevice, metalKitView: MTKView) {
        let mtlVertexDescriptor = ObjectRenderer.buildMetalVertexDescriptor()
        let num_obj = 30
        
        for _ in 0..<maxBuffersInFlight {
            dynamicUniformBuffer.append(device.makeBuffer(length: alignedUniformsSize * (num_obj + 1), options: [MTLResourceOptions.storageModeShared])!)
        }

        for _ in 0..<num_obj {
            let cx: Float = Float.random(in: -30 ... 30)
            let cy: Float = Float.random(in: -5 ... 5)
            let cz: Float = Float.random(in: -30 ... 30)
            
            let sph = Sphere(position: SIMD3<Float>(cx, cy, cz),
                             gravityCenter: SIMD3<Float>(0.0, 0.0, 0.0),
                             velocity: Float.random(in: 1.0 ... 5.0))
            self.spheres.append(sph)
        }
        
        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = MTLCompareFunction.less
        depthStateDescriptor.isDepthWriteEnabled = true
        self.depthStencilState = device.makeDepthStencilState(descriptor:depthStateDescriptor)!

        do {
            shadowPipelineState = try self.buildShadowPipelineWithDevice(device: device,
                                                                         metalKitView: metalKitView,
                                                                         mtlVertexDescriptor: mtlVertexDescriptor)
            pipelineState = try self.buildRenderPipelineWithDevice(device: device,
                                                                   metalKitView: metalKitView,
                                                                   mtlVertexDescriptor: mtlVertexDescriptor)
        } catch {
            print("Unable to compile render pipeline state.  Error info: \(error)")
            return nil
        }
        
        do {
            mesh = [
                try self.buildSphereMesh(device: device, mtlVertexDescriptor: mtlVertexDescriptor),
                try self.buildBoxMesh(device: device, mtlVertexDescriptor: mtlVertexDescriptor)
            ]
            floor = try self.buildFloorMesh(device: device, mtlVertexDescriptor: mtlVertexDescriptor)
        } catch {
            print("Unable to build MetalKit Mesh. Error info: \(error)")
            return nil
        }

        do {
            colorMap = try self.loadTexture(device: device, textureName: "ColorMap")
        } catch {
            print("Unable to load texture. Error info: \(error)")
            return nil
        }
    }
    
    func updateProjectionMatrix(matrix: matrix_float4x4) {
        self.projectionMatrix = matrix
    }

    
    func render(commandBuffer: MTLCommandBuffer, view: MTKView) {
        // Delay getting the currentRenderPassDescriptor until we absolutely need it to avoid
        //   holding onto the drawable and blocking the display pipeline any longer than necessary
        let renderPassDescriptor = view.currentRenderPassDescriptor

        for (_, sphere) in self.spheres.enumerated() {
            //sphere.move(gravityCenter: SIMD3<Float>(0.0, 0.0, 0.0))
            sphere.rotationRadians += 0.02
        }
        
        if let renderPassDescriptor = renderPassDescriptor {

            if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: self.shadowRenderPassDescriptor) {
                renderEncoder.label = "Shadow Render Encoder"
                
                renderEncoder.setCullMode(.back)
                renderEncoder.setFrontFacing(.counterClockwise)

                self.renderScene(renderEncoder: renderEncoder, pipelineState: self.shadowPipelineState)
                
                renderEncoder.endEncoding()
            }

            if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
                renderEncoder.label = "Primary Render Encoder"
                
                renderEncoder.setCullMode(.back)
                renderEncoder.setFrontFacing(.counterClockwise)

                self.renderScene(renderEncoder: renderEncoder, pipelineState: pipelineState)
                
                renderEncoder.endEncoding()
            }
        }
    }

    func renderScene(renderEncoder: MTLRenderCommandEncoder, pipelineState: MTLRenderPipelineState   ) {
        uniformBufferIndex = (uniformBufferIndex + 1) % maxBuffersInFlight
        let uniformBuffer = dynamicUniformBuffer[uniformBufferIndex]

        renderEncoder.setDepthStencilState(depthStencilState)
        
        renderEncoder.setVertexBuffer(uniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        renderEncoder.setFragmentBuffer(uniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        
        renderEncoder.pushDebugGroup("Draw Box")
        renderEncoder.setRenderPipelineState(pipelineState)

        for (idx, sphere) in self.spheres.enumerated() {
            let rotateMatrix = matrix4x4_rotation(radians: sphere.rotationRadians, axis: sphere.rotationAxis)
            let transMatrix = matrix4x4_translation(sphere.position.x, sphere.position.y, sphere.position.z)
            let modelViewMatrix = simd_mul(self.cameraMatrix, simd_mul(rotateMatrix, transMatrix))
            let shadowViewMatrix = simd_mul(self.lightMatrix, simd_mul(rotateMatrix, transMatrix))
            
            var uniform = Uniforms(projectionMatrix: self.projectionMatrix, modelViewMatrix: modelViewMatrix, shadowViewMatrix: shadowViewMatrix)
            let offset = alignedUniformsSize * idx
            memcpy(uniformBuffer.contents() + offset, &uniform, alignedUniformsSize)
            
            renderEncoder.setVertexBufferOffset(offset, index: BufferIndex.uniforms.rawValue)
            drawMesh(renderEncoder: renderEncoder, mesh: mesh[idx % 2])

            renderEncoder.popDebugGroup()
        }
        
        let transMatrix = matrix4x4_translation(-0.0, -10.0, -0.0)
        let modelViewMatrix = simd_mul(self.cameraMatrix, transMatrix)
        let shadowViewMatrix = simd_mul(self.lightMatrix, transMatrix)

        var uniform = Uniforms(projectionMatrix: self.projectionMatrix, modelViewMatrix: modelViewMatrix, shadowViewMatrix: shadowViewMatrix)
        let offset = alignedUniformsSize * self.spheres.count
        memcpy(uniformBuffer.contents() + offset, &uniform, alignedUniformsSize)
        
        renderEncoder.setVertexBufferOffset(offset, index: BufferIndex.uniforms.rawValue)
        drawMesh(renderEncoder: renderEncoder, mesh: floor)
        
        renderEncoder.popDebugGroup()

    }

    func drawMesh(renderEncoder: MTLRenderCommandEncoder, mesh: MTKMesh) {
        for (index, element) in mesh.vertexDescriptor.layouts.enumerated() {
            guard let layout = element as? MDLVertexBufferLayout else {
                return
            }
            
            if layout.stride != 0 {
                let buffer = mesh.vertexBuffers[index]
                renderEncoder.setVertexBuffer(buffer.buffer, offset:buffer.offset, index: index)
            }
        }
        
        renderEncoder.setFragmentTexture(colorMap, index: TextureIndex.color.rawValue)
        renderEncoder.setFragmentTexture(shadowTexture, index: TextureIndex.shadow.rawValue)

        for submesh in mesh.submeshes {
            renderEncoder.drawIndexedPrimitives(type: submesh.primitiveType,
                                                indexCount: submesh.indexCount,
                                                indexType: submesh.indexType,
                                                indexBuffer: submesh.indexBuffer.buffer,
                                                indexBufferOffset: submesh.indexBuffer.offset)
        }

        return
    }
    
    
    func buildShadowPipelineWithDevice(device: MTLDevice,
                                             metalKitView: MTKView,
                                             mtlVertexDescriptor: MTLVertexDescriptor) throws -> MTLRenderPipelineState? {

        let library = device.makeDefaultLibrary()
        let shadowVertexFunction = library?.makeFunction(name: "vertex_zOnly")

        // receiving shadow texture
        let shadowTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                                               width: 1024, height: 1024,
                                                                               mipmapped: false)
        shadowTextureDescriptor.usage = [.shaderRead, .renderTarget]
        self.shadowTexture = device.makeTexture(descriptor: shadowTextureDescriptor)
        self.shadowTexture?.label = "shadow map"
        
        self.shadowRenderPassDescriptor = MTLRenderPassDescriptor()
        let shadowAttachment = self.shadowRenderPassDescriptor!.depthAttachment
        shadowAttachment?.texture = shadowTexture
        shadowAttachment?.loadAction = .clear
        shadowAttachment?.storeAction = .store
        shadowAttachment?.clearDepth = 1.0
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = shadowVertexFunction
        pipelineDescriptor.fragmentFunction = nil
        pipelineDescriptor.colorAttachments[0].pixelFormat = .invalid
        pipelineDescriptor.depthAttachmentPixelFormat = shadowTexture.pixelFormat
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor

        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
    
    func buildRenderPipelineWithDevice(device: MTLDevice,
                                             metalKitView: MTKView,
                                             mtlVertexDescriptor: MTLVertexDescriptor) throws -> MTLRenderPipelineState {
        // Build a render state pipeline object
        let library = device.makeDefaultLibrary()

        let vertexFunction = library?.makeFunction(name: "vertexShader")
        let fragmentFunction = library?.makeFunction(name: "fragmentShader")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "RenderPipeline"
        pipelineDescriptor.sampleCount = metalKitView.sampleCount
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor

        pipelineDescriptor.colorAttachments[0].pixelFormat = metalKitView.colorPixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = metalKitView.depthStencilPixelFormat
        pipelineDescriptor.stencilAttachmentPixelFormat = metalKitView.depthStencilPixelFormat

        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
    
    class func buildMetalVertexDescriptor() -> MTLVertexDescriptor {
        // Create a Metal vertex descriptor specifying how vertices will by laid out for input into our render
        //   pipeline and how we'll layout our Model IO vertices

        let mtlVertexDescriptor = MTLVertexDescriptor()

        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].format = MTLVertexFormat.float3
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].offset = 0
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue

        mtlVertexDescriptor.attributes[VertexAttribute.normal.rawValue].format = MTLVertexFormat.float3
        mtlVertexDescriptor.attributes[VertexAttribute.normal.rawValue].offset = MemoryLayout<Float>.size * 3
        mtlVertexDescriptor.attributes[VertexAttribute.normal.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue

        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].format = MTLVertexFormat.float2
        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].offset = 0
        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].bufferIndex = BufferIndex.meshGenerics.rawValue

        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stride = MemoryLayout<Float>.size * 6
        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stepRate = 1
        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stepFunction = MTLVertexStepFunction.perVertex

        mtlVertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue].stride = 8
        mtlVertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue].stepRate = 1
        mtlVertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue].stepFunction = MTLVertexStepFunction.perVertex

        return mtlVertexDescriptor
    }

    
    func buildSphereMesh(device: MTLDevice,
                               mtlVertexDescriptor: MTLVertexDescriptor) throws -> MTKMesh {
        /// Create and condition mesh data to feed into a pipeline using the given vertex descriptor

        let metalAllocator = MTKMeshBufferAllocator(device: device)

        //let mdlMesh = MDLMesh.newBox(withDimensions: SIMD3<Float>(4, 4, 4),
        //                             segments: SIMD3<UInt32>(2, 2, 2),
        //                             geometryType: MDLGeometryType.triangles,
        //                             inwardNormals:false,
        //                             allocator: metalAllocator)

        let mdlMesh = MDLMesh.newEllipsoid(withRadii: SIMD3<Float>(3, 3, 3),
                                           radialSegments: 32,
                                           verticalSegments: 32,
                                           geometryType: MDLGeometryType.triangles,
                                           inwardNormals:false,
                                           hemisphere: false,
                                           allocator: metalAllocator)
        
        let mdlVertexDescriptor = MTKModelIOVertexDescriptorFromMetal(mtlVertexDescriptor)

        guard let attributes = mdlVertexDescriptor.attributes as? [MDLVertexAttribute] else {
            throw RendererError.badVertexDescriptor
        }
        attributes[VertexAttribute.position.rawValue].name = MDLVertexAttributePosition
        attributes[VertexAttribute.normal.rawValue].name = MDLVertexAttributeNormal
        attributes[VertexAttribute.texcoord.rawValue].name = MDLVertexAttributeTextureCoordinate

        mdlMesh.vertexDescriptor = mdlVertexDescriptor

        return try MTKMesh(mesh:mdlMesh, device:device)
    }

    func buildBoxMesh(device: MTLDevice,
                            mtlVertexDescriptor: MTLVertexDescriptor) throws -> MTKMesh {
        /// Create and condition mesh data to feed into a pipeline using the given vertex descriptor

        let metalAllocator = MTKMeshBufferAllocator(device: device)

        //let mdlMesh = MDLMesh.newBox(withDimensions: SIMD3<Float>(4, 4, 4),
        //                             segments: SIMD3<UInt32>(2, 2, 2),
        //                             geometryType: MDLGeometryType.triangles,
        //                             inwardNormals:false,
        //                             allocator: metalAllocator)

        let mdlMesh = MDLMesh.newBox(withDimensions: SIMD3<Float>(4, 4, 4),
                                     segments: SIMD3<UInt32>(2, 2, 2),
                                     geometryType: MDLGeometryType.triangles,
                                     inwardNormals:false,
                                     allocator: metalAllocator)
        
        let mdlVertexDescriptor = MTKModelIOVertexDescriptorFromMetal(mtlVertexDescriptor)

        guard let attributes = mdlVertexDescriptor.attributes as? [MDLVertexAttribute] else {
            throw RendererError.badVertexDescriptor
        }
        attributes[VertexAttribute.position.rawValue].name = MDLVertexAttributePosition
        attributes[VertexAttribute.normal.rawValue].name = MDLVertexAttributeNormal
        attributes[VertexAttribute.texcoord.rawValue].name = MDLVertexAttributeTextureCoordinate

        mdlMesh.vertexDescriptor = mdlVertexDescriptor

        return try MTKMesh(mesh:mdlMesh, device:device)
    }

    func buildFloorMesh(device: MTLDevice,
                            mtlVertexDescriptor: MTLVertexDescriptor) throws -> MTKMesh {
        /// Create and condition mesh data to feed into a pipeline using the given vertex descriptor

        let metalAllocator = MTKMeshBufferAllocator(device: device)

        //let mdlMesh = MDLMesh.newBox(withDimensions: SIMD3<Float>(4, 4, 4),
        //                             segments: SIMD3<UInt32>(2, 2, 2),
        //                             geometryType: MDLGeometryType.triangles,
        //                             inwardNormals:false,
        //                             allocator: metalAllocator)

        let mdlMesh = MDLMesh.newPlane(withDimensions: SIMD2<Float>(100, 100),
                                       segments: SIMD2<UInt32>(2, 2),
                                       geometryType: MDLGeometryType.triangles,
                                       allocator: metalAllocator)
        
        let mdlVertexDescriptor = MTKModelIOVertexDescriptorFromMetal(mtlVertexDescriptor)

        guard let attributes = mdlVertexDescriptor.attributes as? [MDLVertexAttribute] else {
            throw RendererError.badVertexDescriptor
        }
        attributes[VertexAttribute.position.rawValue].name = MDLVertexAttributePosition
        attributes[VertexAttribute.normal.rawValue].name = MDLVertexAttributeNormal
        attributes[VertexAttribute.texcoord.rawValue].name = MDLVertexAttributeTextureCoordinate

        mdlMesh.vertexDescriptor = mdlVertexDescriptor

        return try MTKMesh(mesh:mdlMesh, device:device)
    }

    func loadTexture(device: MTLDevice,
                           textureName: String) throws -> MTLTexture {
        /// Load texture data with optimal parameters for sampling
        let textureLoader = MTKTextureLoader(device: device)

        let textureLoaderOptions = [
            MTKTextureLoader.Option.textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            MTKTextureLoader.Option.textureStorageMode: NSNumber(value: MTLStorageMode.`private`.rawValue)
        ]

        return try textureLoader.newTexture(name: textureName,
                                            scaleFactor: 1.0,
                                            bundle: nil,
                                            options: textureLoaderOptions)

    }
}
