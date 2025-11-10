//
//  GameViewController.swift
//  Untoldios
//
//  Created by Harold Serrano on 11/9/25.
//

import UIKit
import MetalKit
import UntoldEngine

// Our iOS specific view controller
class GameViewController: UIViewController, MTKViewDelegate {
    var renderer: UntoldRenderer!
    var mtkView: MTKView!

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let mtkView = view as? MTKView else {
            print("View of Gameview controller is not an MTKView")
            return
        }

        // Select the device to render with.  We choose the default device
        guard let defaultDevice = MTLCreateSystemDefaultDevice() else {
            print("Metal is not supported")
            return
        }
        
        mtkView.device = defaultDevice
        view.backgroundColor = UIColor.clear
        mtkView.colorPixelFormat = .bgra8Unorm_srgb
        mtkView.depthStencilPixelFormat = .depth32Float
        
        guard let newRenderer = UntoldRenderer.createiOS(device: mtkView.device!, view: mtkView)else{
            print("Failed to initialize the renderer")
            return
        }
        
        renderer = newRenderer
        
        renderer.mtkView(mtkView, drawableSizeWillChange: mtkView.drawableSize)
        
        mtkView.delegate = self

        loadAssets()
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer.mtkView(view, drawableSizeWillChange: size)
    }
    
    // Called whenever the view needs to render
    func draw(in view: MTKView) {
        renderer.draw(in: view)
    }
}

