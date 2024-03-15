//
//  RichTextViewContext.swift
//  Proton
//
//  Created by Rajdeep Kwatra on 7/1/20.
//  Copyright © 2020 Rajdeep Kwatra. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Foundation
import UIKit
import CoreServices

class RichTextEditorContext: RichTextViewContext {
    static let `default` = RichTextEditorContext()
    
    private var lastRange: NSRange?
    
    private var currentLength = 0
    private var isEnter = false
    private var enter = false
    private var replacementText: String = ""
    private var lastBackgroundStyle: BackgroundStyle? = nil

    func textViewDidBeginEditing(_ textView: UITextView) {
        guard textView.delegate === self else { return }

        activeTextView = textView as? RichTextView
        guard let richTextView = activeTextView else { return }
        
        let range = richTextView.selectedRange
        richTextView.richTextViewDelegate?.richTextView(richTextView, didReceiveFocusAt: range)
        var attributes = [NSAttributedString.Key:Any]()
        if richTextView.selectedRange.endLocation < richTextView.contentLength {
            attributes = richTextView.attributedText.attributes(at: range.endLocation, effectiveRange: nil)
        } else {
            attributes = richTextView.defaultTypingAttributes
        }


        let contentType = attributes[.blockContentType] as? EditorContent.Name ?? .unknown
        attributes[.blockContentType] = nil
        richTextView.richTextViewDelegate?.richTextView(richTextView, didChangeSelection: range, attributes: attributes, contentType: contentType)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        guard textView.delegate === self else { return }

        defer {
            activeTextView = nil
        }
        guard let richTextView = activeTextView else { return }
        richTextView.richTextViewDelegate?.richTextView(richTextView, didLoseFocusFrom: textView.selectedRange)
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard textView.delegate === self,
              let richTextView = activeTextView
        else { return true }

        self.replacementText = text
        self.currentLength = textView.attributedText.length
        if shouldChangeText(richTextView, range: range, replacementText: text) == false {
            return false
        }
        
        self.lastRange = NSRange(location: range.location, length: text.count)

        // if backspace
        var handled = false
        if text.isEmpty {
            richTextView.richTextViewDelegate?.richTextView(richTextView, shouldHandle: .backspace, modifierFlags: [], at: range, handled: &handled)

            guard handled == false else {
                return false
            }

            // User tapped backspace with nothing selected, selected or remove Attachment
            let attributedText: NSAttributedString = textView.attributedText // single allocation
            if
                range.length == 1, // Hit backspace with nothing selected
                range.location <= attributedText.length, // ... within bounds
                let attachment = attributedText.attribute(.attachment, at: range.location, effectiveRange: nil) as? Attachment,
                attachment.selectBeforeDelete, // ...should be selected
                !attachment.isSelected // ... but isn't.
            {
                attachment.isSelected = true // Select it
                return false // don't delete anything
            }

            // Else, handle backspace normally
            return true
        }

        if text == "\n" {
            richTextView.richTextViewDelegate?.richTextView(richTextView, shouldHandle: .enter, modifierFlags: [], at: range, handled: &handled)
            guard handled == false else {
                return false
            }
            richTextView.richTextViewDelegate?.richTextView(richTextView, didReceive: .enter, modifierFlags: [], at: range)
            isEnter = true
            
            enter = true
        }

        if text == "\t" {
            richTextView.richTextViewDelegate?.richTextView(richTextView, shouldHandle: .tab, modifierFlags: [], at: range, handled: &handled)

            guard handled == false else {
                return false
            }
        }

        applyFontFixForEmojiIfRequired(in: richTextView, at: range)
        return true
    }

    private func shouldChangeText(_ richTextView: RichTextView, range: NSRange, replacementText: String) -> Bool {
        guard let editor = richTextView.superview as? EditorView else { return true }
        
        updateTypingAttributes(editor: editor, editedRange: range, replacementText: replacementText)

        for processor in richTextView.textProcessor?.sortedProcessors ?? [] {
            let shouldProcess = processor.shouldProcess(editor, shouldProcessTextIn: range, replacementText: replacementText)
            if shouldProcess == false {
                return false
            }
        }
        return true
    }

    private func updateTypingAttributes(editor: EditorView, editedRange: NSRange, replacementText text: String) {
        guard editedRange.location > 0,
              editedRange.location <= editor.contentLength
        else { return }

        var attributes = editor.attributedText.attributes(at: editedRange.location - 1, effectiveRange: nil)
        if editor.typingAttributes[.backgroundStyle] == nil {
            let customAttributesToApply: [NSAttributedString.Key] = [.backgroundStyle]
            
            let marker = editor.attributedText.substring(from: NSRange(location: editedRange.location - 1, length: 1))
            if marker == ListTextProcessor.blankLineFiller, attributes[.backgroundStyle] == nil, editedRange.location > 1 {
                attributes = editor.attributedText.attributes(at: editedRange.location - 2, effectiveRange: nil)
            }
            let filteredAttributes = attributes.filter { customAttributesToApply.contains($0.key) }
            for attribute in filteredAttributes {
                if attribute.key == .backgroundStyle {
                    lastBackgroundStyle = attribute.value as? BackgroundStyle
                }
                editor.typingAttributes[attribute.key] = attribute.value
            }
        }

        // Drop locked attributes
        if let lockedAttributes = attributes.first(where: { $0.key == .lockedAttributes })?.value as? [NSAttributedString.Key] {
            for attribute in lockedAttributes {
                editor.typingAttributes[attribute] = nil
            }
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        guard textView.delegate === self,
              let richTextView = activeTextView
        else { return }
        
        updateReplaceTextAttributes(in: richTextView)
        applyFontFixForEmojiIfRequired(in: richTextView, at: textView.selectedRange)
        if textView.attributedText.length >= currentLength {
            processList(textView)
        }
        invokeDidProcessIfRequired(richTextView)
        
        if let lastRange, let editor = textView.superview as? EditorView, editor.isRoot {
            if lastRange.endLocation < editor.contentLength {
                let nextCh = richTextView.attributedText.substring(from: NSRange(location: lastRange.endLocation, length: 1))
                if nextCh == ListTextProcessor.blankLineFiller, let line = editor.currentLayoutLine {
                    let replaceRange = NSRange(location: lastRange.location, length: lastRange.length + 1)
                    let attrs = editor.attributedText.attributes(at: min(lastRange.endLocation + 1, editor.contentLength - 1), effectiveRange: nil)
                    let attr = NSMutableAttributedString(string: ListTextProcessor.blankLineFiller)
                    attr.append(editor.attributedText.attributedSubstring(from: lastRange))
                    attr.addAttributes(attrs, range: attr.fullRange)
                    editor.replaceCharacters(in: replaceRange, with: attr)
                }
            }
            let paragraphStyle = richTextView.paragraphStyle
            if (paragraphStyle?.lineSpacing ?? 0) == 11 {
                applyChineseFixFontIfRequired(in: richTextView, range: lastRange)
            }
        }
        
        if isEnter,
           let editor = textView.superview as? EditorView,
           editor.isRoot {
            fixList(in: textView)
            changeParagraph(on: editor)
            isEnter = false
        }
        
        richTextView.richTextViewDelegate?.richTextView(richTextView, didChangeTextAtRange: richTextView.selectedRange)
        self.lastBackgroundStyle = nil
        self.replacementText = ""
    }
    
    private func updateReplaceTextAttributes(in textView: RichTextView) {
        guard !replacementText.isEmpty, 
            let editor = textView.superview as? EditorView,
              editor.selectedRange.location > replacementText.count else { return }
        let attributes = editor.attributedText.attributes(at: editor.selectedRange.location - replacementText.count, effectiveRange: nil)
        if let backgroundStyle = self.lastBackgroundStyle {
            editor.addAttribute(.backgroundStyle, value: backgroundStyle, at: NSRange(location: editor.selectedRange.location - replacementText.count, length: replacementText.count))
        }
    }
    
    private func applyChineseFixFontIfRequired(in textView: RichTextView, range: NSRange) {
        guard let font = textView.typingAttributes[.font] as? UIFont else { return }
        guard range.endLocation <= textView.contentLength else { return }
        let attr = textView.attributedText.attributedSubstring(from: range)
    }
    
    private func fixList(in textView: UITextView) {
        guard let editor = textView.superview as? EditorView else { return }
        
        if let line = editor.currentLayoutLine,
           editor.attributedText.substring(from: NSRange(location: line.range.location - 1, length: 1)) == ListTextProcessor.blankLineFiller {
            return
        }
        
        var selectedRange = editor.selectedRange
        if let line = editor.currentLayoutLine,
           let currentLine = editor.contentLinesInRange(NSRange(location: line.range.location, length: 0)).first,
           currentLine.range.length > 0 {
            var location = line.range.location
            var length = max(currentLine.range.length, selectedRange.length + (selectedRange.location - line.range.location))
            let range = NSRange(location: location, length: length)
            if editor.contentLength > range.endLocation,
               editor.attributedText.substring(from: NSRange(location: range.endLocation, length: 1)) == "\n" {
                length += 1
            }
            selectedRange = NSRange(location: location, length: length)
        }
        
        if let line = editor.currentLayoutLine,
           var value = line.text.attribute(.listItem, at: 0, effectiveRange: nil) as? String,
           let previousLine = editor.previousContentLine(from: line.range.location) {
            var range = NSRange(location: previousLine.range.location, length: 1)
            if (range.endLocation + 1) < editor.contentLength,
               editor.attributedText.substring(from: NSRange(location: range.endLocation, length: 1)) == "\n" {
                range = NSRange(location: range.location, length: 2)
            }
            if range.endLocation < editor.contentLength {
                let attr = editor.attributedText.attributedSubstring(from: range)
                if let p = attr.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
                   p.headIndent > 0 {
                    let str = editor.attributedText.substring(from: range)
                    if !str.contains(ListTextProcessor.blankLineFiller) {
                        let attrs = editor.attributedText.attributes(at: range.location, effectiveRange: nil)
                        let marker = NSAttributedString(string: "\(ListTextProcessor.blankLineFiller)", attributes: attrs)
                        editor.replaceCharacters(in: NSRange(location: range.location, length: 0), with: marker)
                        editor.selectedRange = NSRange(location: editor.selectedRange.location + marker.length, length: 0)
                    }
                }
            }
        }
    }
    
    private func containsChinese(str: String) -> Bool{
        let match: String = "(^[\\u4e00-\\u9fa5]+$)"
        let predicate = NSPredicate(format: "SELF matches %@", match)
        return predicate.evaluate(with: str)
    }

    private func processList(_ textView: UITextView) {
        guard let editor = textView.superview as? EditorView else { return }
        let currentRange = editor.selectedRange
        var len = replacementText.count
        
        if let currentLine = editor.contentLinesInRange(currentRange).first,
           currentLine.text.length > 0,
           let previousLine = editor.previousContentLine(from: currentLine.range.location) {
            let range = NSRange(location: previousLine.range.endLocation, length: 1)
            if let para = currentLine.text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
               currentLine.text.attribute(.listItem, at: 0, effectiveRange: nil) == nil,
               let newLineListItem = editor.attributedText.attribute(.listItem, at: range.location, effectiveRange: nil) as? String {
                editor.addAttribute(.listItem, value: newLineListItem, at: currentLine.range)
                editor.addAttribute(.listItemValue, value: editor.attributedText.attribute(.listItemValue, at: range.location, effectiveRange: nil), at: currentLine.range)
                if newLineListItem != "listItemSelectedChecklist" {
                    editor.removeAttribute(.strikethroughStyle, at: currentLine.range)
                    editor.removeAttribute(.strokeColor, at: currentLine.range)
                }
                let attr = editor.attributedText
                editor.attributedText.enumerateAttributes(in: currentLine.range) { attrs, range, stop in
                    let subAttr = attr.attributedSubstring(from: range)
                    var color = editor.defaultColor
                    if let c = subAttr.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor {
                        color = c
                    }
                    if newLineListItem == "listItemSelectedChecklist" {
                        color = color?.withAlphaComponent(0.32)
                    } else {
                        color = color?.withAlphaComponent(1)
                    }

                    editor.addAttribute(.foregroundColor, value: color, at: range)
                    editor.addAttribute(.strikethroughColor, value: color, at: range)
                    editor.typingAttributes[.foregroundColor] = color
                    editor.typingAttributes[.strikethroughColor] = color
                }
                
            }
            
            if let value = currentLine.text.attribute(.listItem, at: 0, effectiveRange: nil) as? String {
                if value != "listItemSelectedChecklist" {
                    editor.removeAttribute(.strikethroughStyle, at: currentLine.range)
                    editor.removeAttribute(.strikethroughColor, at: currentLine.range)
                }
                let attr = editor.attributedText
                editor.attributedText.enumerateAttributes(in: currentLine.range) { attrs, range, stop in
                    let subAttr = attr.attributedSubstring(from: range)
                    var color = editor.defaultColor
                    if let c = subAttr.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor {
                        color = c
                    }
                    if value == "listItemSelectedChecklist" {
                        color = color?.withAlphaComponent(0.32)
                    } else {
                        color = color?.withAlphaComponent(1)
                    }

                    editor.addAttribute(.foregroundColor, value: color, at: range)
                    editor.addAttribute(.strikethroughColor, value: color, at: range)
                    editor.typingAttributes[.foregroundColor] = color
                    editor.typingAttributes[.strikethroughColor] = color
                }
            }
            
            len = editor.selectedRange.location - currentLine.range.location
        }
        
        if len == 0 {
            if let currentLine = editor.contentLinesInRange(currentRange).first {
                len = editor.selectedRange.location - currentLine.range.location
            } else {
                return
            }
        }
        guard len > 0 else { return }
        let rangeToCheck = max(0, min(currentRange.endLocation, editor.contentLength) - len)
        
        if rangeToCheck >= 2,
           editor.contentLength > 0,
           let value = editor.attributedText.attribute(.listItem, at: rangeToCheck, effectiveRange: nil),
           (editor.attributedText.attribute(.paragraphStyle, at: rangeToCheck, effectiveRange: nil) as? NSParagraphStyle)?.firstLineHeadIndent ?? 0 > 0 {
            let v: Any
            
            let text = editor.attributedText.substring(from: NSRange(location: currentRange.endLocation - 1, length: 1))
            v = value
            editor.addAttribute(.listItem, value: v, at: NSRange(location: rangeToCheck, length: len))
            editor.addAttribute(.listItemValue, value: editor.attributedText.attribute(.listItemValue, at: rangeToCheck, effectiveRange: nil), at: NSRange(location: rangeToCheck, length: len))
            
            editor.typingAttributes[.listItem] = v
            if !((value as? String)?.isChecklist ?? false) {
                editor.typingAttributes[.listItemValue] = editor.attributedText.attribute(.listItemValue, at: rangeToCheck, effectiveRange: nil)
            }
        }
    }
    
    private func invokeDidProcessIfRequired(_ richTextView: RichTextView) {
        guard let editor = richTextView.superview as? EditorView else { return }

        for processor in richTextView.textProcessor?.sortedProcessors ?? [] {
            processor.didProcess(editor: editor)
        }
    }

    // This func is required to handle a bug in NSTextStorage/UITextView where after inserting an emoji character, the
    // typing attributes are set to default Menlo font. This causes the editor to lose the applied font that exists before the emoji
    // character. The code looks for existing font information before emoji char and resets that in the typing attributes.
    private func applyFontFixForEmojiIfRequired(in textView: RichTextView, at range: NSRange) {
        guard let font = textView.typingAttributes[.font] as? UIFont,
              font.isAppleEmoji
        else { return }
        
        textView.typingAttributes[.font] = getDefaultFont(textView: textView, before: range)
    }

    private func getDefaultFont(textView: RichTextView, before range: NSRange) -> UIFont {
        var fontToApply: UIFont?
        let traversalRange = NSRange(location: 0, length: range.location)
        textView.enumerateAttribute(.font, in: traversalRange, options: [.longestEffectiveRangeNotRequired, .reverse]) { font, fontRange, stop in
            if let font = font as? UIFont,
               font.isAppleEmoji == false {
                fontToApply = font
                stop.pointee = true
            }
        }
        return fontToApply ?? textView.defaultFont
    }
}

extension String {
    var containsEmoji: Bool {
        for scalar in unicodeScalars {
            switch scalar.value {
            case 0x1F600...0x1F64F, // Emoticons
                 0x1F300...0x1F5FF, // Misc Symbols and Pictographs
                 0x1F680...0x1F6FF, // Transport and Map
                 0x2600...0x26FF,   // Misc symbols
                 0x2700...0x27BF,   // Dingbats
                 0xFE00...0xFE0F,   // Variation Selectors
                 0x1F900...0x1F9FF, // Supplemental Symbols and Pictographs
                 0x1F1E6...0x1F1FF: // Flags
                return true
            default:
                continue
            }
        }
        return false
    }
}
