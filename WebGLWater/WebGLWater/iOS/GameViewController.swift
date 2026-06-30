//
//  GameViewController.swift  (iOS)
//  WebGLWater
//

import UIKit
import MetalKit
import simd
import UntoldEngine

final class GameViewController: UIViewController, MTKViewDelegate {
    var renderer: UntoldRenderer!
    var mtkView: MTKView!
    var game: WaterGame!

    override func loadView() {
        mtkView = MTKView()
        view = mtkView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let defaultDevice = MTLCreateSystemDefaultDevice() else {
            print("Metal is not supported")
            return
        }

        mtkView.device = defaultDevice
        // Non-sRGB so the water shader's display-space colors show as-is (matches the
        // original WebGL canvas) rather than being sRGB-encoded and washed out.
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.depthStencilPixelFormat = .depth32Float
        mtkView.backgroundColor = .black

        // Must be set before the renderer is created so the engine skips its
        // deferred pipelines (44 bytes of tile memory > the iOS sim's 32-byte limit).
        setWaterOnlyMode(true)

        guard let newRenderer = UntoldRenderer.createiOS(device: mtkView.device!, view: mtkView) else {
            print("Failed to initialize the renderer")
            return
        }
        renderer = newRenderer
        renderer.mtkView(mtkView, drawableSizeWillChange: mtkView.drawableSize)

        game = WaterGame()
        game.start()

        renderer.setupCallbacks(
            gameUpdate: { [weak self] deltaTime in self?.game.update(deltaTime: deltaTime) },
            handleInput: { [weak self] in self?.game.handleInput() }
        )

        mtkView.delegate = self

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        mtkView.addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        mtkView.addGestureRecognizer(pinch)
        // Double-tap = play/pause (the iOS stand-in for the Space key).
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        mtkView.addGestureRecognizer(doubleTap)
    }

    @objc private func handleDoubleTap() { game.togglePause() }

    private func point(_ g: UIGestureRecognizer) -> simd_float2 {
        let loc = g.location(in: mtkView)
        let h = Float(mtkView.bounds.height)
        game.setViewport(simd_float2(Float(mtkView.bounds.width), h))
        // UIKit is top-left (y-down); flip to bottom-left (y-up) for the engine's picker.
        return simd_float2(Float(loc.x), h - Float(loc.y))
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began: game.dragBegan(at: point(g))
        case .changed: game.dragMoved(to: point(g))
        case .ended, .cancelled, .failed: game.dragEnded()
        default: break
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        if g.state == .changed {
            game.zoom(by: Float(1.0 - Double(g.scale)) * 3.0)
            g.scale = 1.0
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer.mtkView(view, drawableSizeWillChange: size)
    }

    func draw(in view: MTKView) {
        renderer.draw(in: view)
    }
}
