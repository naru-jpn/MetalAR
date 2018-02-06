//
//  ShutterButton.swift
//  MetalAR
//
//  Created by naru on 2018/02/05.
//  Copyright © 2018年 naru. All rights reserved.
//

import UIKit

protocol ShutterButtonDelegate {
    
    func shutterButton(_ button: ShutterButton, didTapWith event: UIEvent)
    
    func shutterButtonDidDetectLongPress(_ button: ShutterButton)
    
    func shutterButtonDidFinishLongPress(_ button: ShutterButton)
}

/// Button to control shot.
class ShutterButton: UIView {
    
    struct Constants {
        static let DefaultRadius: CGFloat = 36.0
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
        addSubview(self.button)
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: Elements
    
    private var timer: Timer?
    
    private var isLongPressDetected: Bool = false
    
    var delegate: ShutterButtonDelegate?
    
    private var buttonRect: CGRect {
        let size: CGSize = CGSize(width: Constants.DefaultRadius*2, height: Constants.DefaultRadius*2)
        let origin: CGPoint = CGPoint(x: (self.bounds.width - size.width)/2.0, y: (self.bounds.height - size.height)/2.0)
        return CGRect(origin: origin, size: size)
    }
    
    lazy var button: UIView = {
        let effect: UIVisualEffect = UIBlurEffect(style: .light)
        let view: UIView = UIVisualEffectView(effect: effect)
        view.frame = self.buttonRect
        view.clipsToBounds = true
        view.layer.cornerRadius = Constants.DefaultRadius
        return view
    }()
    
    // MARK: Touch
    
    private func executeReduceAnimation() {
        let options: UIViewAnimationOptions = [.curveEaseInOut, .allowUserInteraction]
        UIView.animate(withDuration: 0.2, delay: 0.0, usingSpringWithDamping: 0.75, initialSpringVelocity: 0.0, options: options, animations: {
            self.button.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        }, completion: nil)
    }
    
    private func executeExpandAnimation() {
        let options: UIViewAnimationOptions = [.curveEaseInOut, .allowUserInteraction]
        UIView.animate(withDuration: 0.5, delay: 0.0, usingSpringWithDamping: 0.25, initialSpringVelocity: 0.0, options: options, animations: {
            self.button.transform = .identity
        }, completion: nil)
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        executeReduceAnimation()
        
        isLongPressDetected = false
        timer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(detectLongPress), userInfo: nil, repeats: false)
    }
    
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        executeExpandAnimation()
        timer?.invalidate()
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        executeExpandAnimation()
        timer?.invalidate()
        
        if isLongPressDetected {
            button.backgroundColor = UIColor.clear
            delegate?.shutterButtonDidFinishLongPress(self)
        } else {
            if let event: UIEvent = event {
                delegate?.shutterButton(self, didTapWith: event)
            }
        }
    }
    
    // MARK: Long press
    
    @objc func detectLongPress() {
        isLongPressDetected = true
        button.backgroundColor = UIColor(red: 0.0, green: 0.0, blue: 1.0, alpha: 1.0)
        delegate?.shutterButtonDidDetectLongPress(self)
    }
}
