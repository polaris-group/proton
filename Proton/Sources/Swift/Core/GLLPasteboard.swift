//
//  File.swift
//  
//
//  Created by polaris dev on 2023/6/25.
//

import UIKit

public struct PasteModel {
    public let attr: NSAttributedString
    public let sourceFrom: GLLPasteboardSourceFrom
}

public enum GLLPasteboardSourceFrom {
    case `internal`
    case outer
}

public struct GLLPasteboard {
    
    private let limit = 10
    
    public static var general = GLLPasteboard()
    
    private var stack: [NSAttributedString] = []
    
    mutating public func last() -> NSAttributedString? {
        guard !stack.isEmpty else { return nil }
        return stack.last
    }
    
    mutating public func push(_ attributeString: NSAttributedString) {
        if stack.count >= limit {
            stack.removeFirst()
        }
        stack.append(attributeString)
    }
        
    func contains(_ content: String) -> Bool {
        for s in stack {
            if s.string == content {
                return true
            }
        }
        return false
    }
    
}
