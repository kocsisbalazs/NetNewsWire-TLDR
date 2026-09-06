//
//  TimelineBadgeView.swift
//  NetNewsWire
//
//  Created by Balázs on 9/7/26.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import AppKit

/// A tiny capsule with text — the “TL;DR” marker next to the date in the timeline.
/// Drawn directly, like `UnreadIndicatorView`, because table cells don’t use Auto Layout.
final class TimelineBadgeView: NSView {

	static let horizontalPadding: CGFloat = 5.0
	static let verticalPadding: CGFloat = 1.0
	static let cornerRadius: CGFloat = 4.0

	var text = "" {
		didSet {
			if text != oldValue {
				needsDisplay = true
			}
		}
	}

	var font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold) {
		didSet {
			if font != oldValue {
				needsDisplay = true
			}
		}
	}

	var isEmphasized = false {
		didSet {
			if isEmphasized != oldValue {
				needsDisplay = true
			}
		}
	}

	var isSelected = false {
		didSet {
			if isSelected != oldValue {
				needsDisplay = true
			}
		}
	}

	nonisolated override var isFlipped: Bool {
		return true
	}

	/// Badge size for the layout pass, so the cell can reserve room before the view exists.
	static func size(for text: String, font: NSFont) -> NSSize {
		let textSize = (text as NSString).size(withAttributes: [.font: font])
		return NSSize(width: ceil(textSize.width) + horizontalPadding * 2, height: ceil(textSize.height) + verticalPadding * 2)
	}

	override func draw(_ dirtyRect: NSRect) {
		let onSelectedRow = isSelected && isEmphasized

		let backgroundColor = onSelectedRow ? NSColor.white.withAlphaComponent(0.25) : NSColor.controlAccentColor.withAlphaComponent(0.18)
		let textColor = onSelectedRow ? NSColor.white : NSColor.controlAccentColor

		backgroundColor.setFill()
		NSBezierPath(roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()

		let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
		let textSize = (text as NSString).size(withAttributes: attributes)
		let textRect = NSRect(x: floor((bounds.width - textSize.width) / 2.0), y: floor((bounds.height - textSize.height) / 2.0), width: ceil(textSize.width), height: ceil(textSize.height))
		(text as NSString).draw(in: textRect, withAttributes: attributes)
	}
}
