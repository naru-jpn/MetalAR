//
//  Shutter.swift
//  MetalAR
//
//  Created by naru on 2018/02/05.
//  Copyright © 2018年 naru. All rights reserved.
//

import UIKit

/// Flushing view.
class Shutter: UIView {
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        alpha = 0.0
        backgroundColor = .white
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        alpha = 0.0
        backgroundColor = .white
    }
    
    /// Execute flush animation
    func flash() {
        alpha = 1.0
        UIView.animate(withDuration: 0.2, delay: 0.0, options: [.curveEaseInOut], animations: {
            self.alpha = 0.0
        }, completion: nil)
    }
}
