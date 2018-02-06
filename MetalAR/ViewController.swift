//
//  ViewController.swift
//  MetalAR
//
//  Created by naru on 2018/01/31.
//  Copyright © 2018年 naru. All rights reserved.
//

import UIKit
import Metal
import MetalKit
import ARKit

class ViewController: UIViewController, ARSessionDelegate, RenderDelegate, ShutterButtonDelegate, UIGestureRecognizerDelegate {
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.addSubview(display)
        view.addSubview(shutterButton)
        view.addSubview(shutter)
        
        // create session
        session = ARSession()
        session.delegate = self
        
        // configure renderer
        renderer = Renderer(session: session, metalDevice: context.device)
        renderer.drawRectResized(size: view.bounds.size)
        renderer.delegate = self
        
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(ViewController.handleTap(gestureRecognizer:)))
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = self
        view.addGestureRecognizer(tapGesture)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = .horizontal
        session.run(configuration)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        session.pause()
    }
    
    // MARK: - Elements
    
    var session: ARSession!
    
    let context: Context = Context()
    
    lazy var display: Display = {
        let display: Display = Display(frame: view.bounds, context: context)
        display.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return display
    }()
    
    var shutterButtonRect: CGRect {
        let radius: CGFloat = ShutterButton.Constants.DefaultRadius
        let size: CGSize = CGSize(width: radius*2, height: radius*2)
        let origin: CGPoint = CGPoint(x: (view.bounds.width - size.width)/2.0, y: view.bounds.height - size.height - 24.0)
        return CGRect(origin: origin, size: size)
    }
    
    lazy var shutterButton: ShutterButton = {
        let button = ShutterButton(frame: self.shutterButtonRect)
        button.delegate = self
        return button
    }()
    
    lazy var shutter: Shutter = {
        return Shutter(frame: view.bounds)
    }()
    
    var renderer: Renderer!
    
    // MARK: - Gesture
    
    @objc func handleTap(gestureRecognizer: UITapGestureRecognizer) {
        
        if let currentFrame = session.currentFrame {
            
            // Create a transform with a translation of 0.2 meters in front of the camera
            var translation = matrix_identity_float4x4
            translation.columns.3.z = -0.2
            let transform = simd_mul(currentFrame.camera.transform, translation)
            
            let anchor = ARAnchor(transform: transform)
            session.add(anchor: anchor)
        }
    }
    
    // MARK: - RenderDelegate
    
    func renderer(_ renderer: Renderer, didFinishProcess texture: MTLTexture) {
        display.texture = texture
    }
    
    // MARK: - ARSessionDelegate
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        renderer.update()
    }
    
    func session(_ session: ARSession, didFailWithError error: Error) {
        // Present an error message to the user
    }
    
    func sessionWasInterrupted(_ session: ARSession) {
        // Inform the user that the session has been interrupted, for example, by presenting an overlay
    }
    
    func sessionInterruptionEnded(_ session: ARSession) {
        // Reset tracking and/or remove existing anchors if consistent tracking is required
    }
    
    // MARK: - UIGestureRecognizerDelegate
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let isDescendant: Bool = touch.view?.isDescendant(of: shutterButton) ?? false
        return !isDescendant
    }
    
    // MARK: - ShutterButtonDelegate
    
    func shutterButton(_ button: ShutterButton, didTapWith event: UIEvent) {
        takePicture()
    }
    
    func shutterButtonDidDetectLongPress(_ button: ShutterButton) {
        // do nothing
    }
    
    func shutterButtonDidFinishLongPress(_ button: ShutterButton) {
        takePicture()
    }
    
    private func takePicture() {
        shutter.flash()
        DispatchQueue.global().async {
            guard let image: CGImage = self.display.currentCGImage(viewportSize: self.renderer.viewportSize) else {
                return
            }
            UIImageWriteToSavedPhotosAlbum(UIImage(cgImage: image), nil, nil, nil)
        }
    }
}
