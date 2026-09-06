//
//  TLDRButton.swift
//  NetNewsWire
//
//  Created by Balázs on 9/7/26.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import AppKit

enum TLDRButtonState {
	case off
	case animated
	case on
}

/// The TL;DR toolbar button. Same shape as `ArticleExtractorButton`: an image button
/// that swaps its symbol for a spinner while the summary is being generated.
final class TLDRButton: NSButton {

	private let progressIndicator: NSProgressIndicator = {
		let indicator = NSProgressIndicator()
		indicator.style = .spinning
		indicator.controlSize = .small
		indicator.isDisplayedWhenStopped = false
		indicator.translatesAutoresizingMaskIntoConstraints = false
		return indicator
	}()

	var buttonState: TLDRButtonState = .off {
		didSet {
			if buttonState != oldValue {
				switch buttonState {
				case .animated:
					image = nil
					progressIndicator.startAnimation(nil)
					isEnabled = false
				case .on:
					progressIndicator.stopAnimation(nil)
					isEnabled = true
					image = Assets.Images.tldrOn
				case .off:
					progressIndicator.stopAnimation(nil)
					isEnabled = true
					image = Assets.Images.tldrOff
				}
			}
		}
	}

	override func accessibilityLabel() -> String? {
		switch buttonState {
		case .animated:
			return NSLocalizedString("Summarizing - TL;DR", comment: "Summarizing - TL;DR")
		case .on:
			return NSLocalizedString("Selected - TL;DR", comment: "Selected - TL;DR")
		case .off:
			return NSLocalizedString("TL;DR", comment: "TL;DR")
		}
	}

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		commonInit()
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
		commonInit()
	}

	private func commonInit() {
		wantsLayer = true
		bezelStyle = .texturedRounded
		image = Assets.Images.tldrOff
		imageScaling = .scaleProportionallyDown
		widthAnchor.constraint(equalTo: heightAnchor).isActive = true

		addSubview(progressIndicator)
		NSLayoutConstraint.activate([
			progressIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
			progressIndicator.centerYAnchor.constraint(equalTo: centerYAnchor)
		])
	}
}
