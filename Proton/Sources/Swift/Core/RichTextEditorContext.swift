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

        if shouldChangeText(richTextView, range: range, replacementText: text) == false {
            return false
        }

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
        
        updateTypingAttributes(editor: editor, editedRange: range)

        for processor in richTextView.textProcessor?.sortedProcessors ?? [] {
            let shouldProcess = processor.shouldProcess(editor, shouldProcessTextIn: range, replacementText: replacementText)
            if shouldProcess == false {
                return false
            }
        }
        return true
    }

    private func updateTypingAttributes(editor: EditorView, editedRange: NSRange) {
        guard editedRange.location > 0,
              editedRange.location <= editor.contentLength
        else { return }

        // custom attributes to carry over
        let attributes = editor.attributedText.attributes(at: editedRange.location - 1, effectiveRange: nil)
        if editor.typingAttributes[.backgroundStyle] == nil {
            let customAttributesToApply: [NSAttributedString.Key] = [.backgroundStyle]

            let filteredAttributes = attributes.filter { customAttributesToApply.contains($0.key) }
            for attribute in filteredAttributes {
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

        applyFontFixForEmojiIfRequired(in: richTextView, at: textView.selectedRange)
        processList(textView)
        invokeDidProcessIfRequired(richTextView)

        richTextView.richTextViewDelegate?.richTextView(richTextView, didChangeTextAtRange: richTextView.selectedRange)
    }

    private func processList(_ textView: UITextView) {
        guard let editor = textView.superview as? EditorView else { return }
        let currentRange = editor.selectedRange
        let rangeToCheck = max(0, min(currentRange.endLocation, editor.contentLength) - 2)
        if rangeToCheck >= 2,
           editor.contentLength > 0,
           let value = editor.attributedText.attribute(.listItem, at: rangeToCheck, effectiveRange: nil),
           (editor.attributedText.attribute(.paragraphStyle, at: rangeToCheck, effectiveRange: nil) as? NSParagraphStyle)?.firstLineHeadIndent ?? 0 > 0 {
            editor.typingAttributes[.listItem] = value
            if !((value as? String)?.isChecklist ?? false) {
                editor.typingAttributes[.listItemValue] = editor.attributedText.attribute(.listItemValue, at: rangeToCheck, effectiveRange: nil)
            }
            editor.addAttribute(.listItem, value: value, at: NSRange(location: rangeToCheck, length: 2))
            editor.addAttribute(.listItemValue, value: editor.attributedText.attribute(.listItemValue, at: rangeToCheck, effectiveRange: nil), at: NSRange(location: rangeToCheck, length: 2))
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
