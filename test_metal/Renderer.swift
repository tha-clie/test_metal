//
//  Renderer.swift
//  test_metal
//
//  Created by Minoru Harada on 2021/11/15.
//

// Our platform independent renderer class

import Metal
import MetalKit
import simd


enum RendererError: Error {
    case badVertexDescriptor
}


class Renderer: NSObject, MTKViewDelegate {

    public let device: MTLDevice
    let commandQueue: MTLCommandQueue

    let inFlightSemaphore = DispatchSemaphore(value: maxBuffersInFlight)

    var renderer: ObjectRenderer? = nil
    
    init?(metalKitView: MTKView) {
        self.device = metalKitView.device!
        self.commandQueue = self.device.makeCommandQueue()!

        metalKitView.depthStencilPixelFormat = MTLPixelFormat.depth32Float_stencil8
        metalKitView.colorPixelFormat = MTLPixelFormat.bgra8Unorm_srgb
        metalKitView.sampleCount = 1

        self.renderer = ObjectRenderer(device: device, metalKitView: metalKitView)
        super.init()
    }
    

    func draw(in view: MTKView) {
        /// Per frame updates hare
        
        _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)
        
        if let commandBuffer = commandQueue.makeCommandBuffer() {
            let semaphore = inFlightSemaphore
            commandBuffer.addCompletedHandler { (_ commandBuffer)-> Swift.Void in
                semaphore.signal()
            }

            self.renderer?.render(commandBuffer: commandBuffer, view: view)

            if let drawable = view.currentDrawable {
                commandBuffer.present(drawable)
            }
            commandBuffer.commit()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        /// Respond to drawable size or orientation changes here

        let aspect = Float(size.width) / Float(size.height)
        let projectionMatrix = matrix_perspective_right_hand(fovyRadians: radians_from_degrees(80),
                                                             aspectRatio:aspect, nearZ: 0.1, farZ: 100.0)
        
        self.renderer?.updateProjectionMatrix(matrix: projectionMatrix)
    }
}

// Generic matrix math utility functions
func matrix4x4_rotation(radians: Float, axis: SIMD3<Float>) -> matrix_float4x4 {
    let unitAxis = normalize(axis)
    let ct = cosf(radians)
    let st = sinf(radians)
    let ci = 1 - ct
    let x = unitAxis.x, y = unitAxis.y, z = unitAxis.z
    return matrix_float4x4.init(columns:(vector_float4(    ct + x * x * ci, y * x * ci + z * st, z * x * ci - y * st, 0),
                                         vector_float4(x * y * ci - z * st,     ct + y * y * ci, z * y * ci + x * st, 0),
                                         vector_float4(x * z * ci + y * st, y * z * ci - x * st,     ct + z * z * ci, 0),
                                         vector_float4(                  0,                   0,                   0, 1)))
}

func matrix4x4_translation(_ translationX: Float, _ translationY: Float, _ translationZ: Float) -> matrix_float4x4 {
    return matrix_float4x4.init(columns:(vector_float4(1, 0, 0, 0),
                                         vector_float4(0, 1, 0, 0),
                                         vector_float4(0, 0, 1, 0),
                                         vector_float4(translationX, translationY, translationZ, 1)))
}

func matrix_perspective_right_hand(fovyRadians fovy: Float, aspectRatio: Float, nearZ: Float, farZ: Float) -> matrix_float4x4 {
    let ys = 1 / tanf(fovy * 0.5)
    let xs = ys / aspectRatio
    let zs = farZ / (nearZ - farZ)
    return matrix_float4x4.init(columns:(vector_float4(xs,  0, 0,   0),
                                         vector_float4( 0, ys, 0,   0),
                                         vector_float4( 0,  0, zs, -1),
                                         vector_float4( 0,  0, zs * nearZ, 0)))
}

func radians_from_degrees(_ degrees: Float) -> Float {
    return (degrees / 180) * .pi
}

func matrix4x4_cameera_lookat(pos: SIMD3<Float>, lookat: SIMD3<Float>, up: SIMD3<Float>) -> matrix_float4x4 {
    let ez: SIMD3<Float> = normalize(pos - lookat)
    let ex: SIMD3<Float> = normalize(cross(up, ez))
    let ey: SIMD3<Float> = normalize(cross(ez, ex))
    
    let rot_mtx = matrix_float4x4.init(columns: (vector_float4(ex.x, ex.y, ex.z, 0.0),
                                                 vector_float4(ey.x, ey.y, ey.z, 0.0),
                                                 vector_float4(ez.x, ez.y, ez.z, 0.0),
                                                 vector_float4(0.0,  0.0,  0.0,  1.0)))
    let trns_mtx = matrix4x4_translation(pos.x, pos.y, pos.z)

    return trns_mtx * rot_mtx
}
