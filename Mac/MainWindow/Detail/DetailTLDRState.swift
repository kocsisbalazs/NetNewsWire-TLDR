//
//  DetailTLDRState.swift
//  NetNewsWire
//
//  Created by Balázs on 9/7/26.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation

/// Where the TL;DR card is for the current article. Raw values are what tldr.js switches on.
enum TLDRStatus: String, Sendable {

	/// No article, or an article with no text. Nothing is shown.
	case unavailable

	/// Article has text and no summary yet — the “summarize with TL;DR” bar is showing.
	case idle

	/// Summary is being generated — the card shows progress.
	case generating

	/// Summary is showing in the card.
	case ready

	/// Generation failed — the card shows the error and a retry.
	case failed

	/// A summary exists but the reader closed the card — the bar offers to show it again.
	case hidden
}

struct TLDRState: Equatable {

	var status: TLDRStatus
	var length: SummaryLength
	var summary: ArticleSummary?
	var errorMessage: String?

	init(status: TLDRStatus, length: SummaryLength, summary: ArticleSummary? = nil, errorMessage: String? = nil) {
		self.status = status
		self.length = length
		self.summary = summary
		self.errorMessage = errorMessage
	}

	var isShowingSummary: Bool {
		status == .ready
	}

	/// The payload for `nnwTLDR.render(...)`.
	func jsonString() -> String? {
		var dictionary: [String: Any] = [
			"status": status.rawValue,
			"length": length.rawValue
		]
		if let summary {
			dictionary["summary"] = summary.text
			dictionary["engine"] = summary.engine.rawValue
		}
		if let errorMessage {
			dictionary["error"] = errorMessage
		}
		guard let data = try? JSONSerialization.data(withJSONObject: dictionary) else {
			return nil
		}
		return String(data: data, encoding: .utf8)
	}
}

/// Labels for the card. tldr.js is a static file and can’t call NSLocalizedString,
/// so WebViewConfiguration injects these as `nnwTLDRStrings` at document start.
enum TLDRStrings {

	static let dictionary: [String: String] = [
		"title": NSLocalizedString("TL;DR", comment: "TL;DR card title"),
		"summarize": NSLocalizedString("summarize with TL;DR", comment: "TL;DR bar action"),
		"show": NSLocalizedString("show TL;DR", comment: "TL;DR bar action"),
		"wordCount": NSLocalizedString("%@ words", comment: "TL;DR bar — %@ is a formatted number"),
		"readingTime": NSLocalizedString("~%@ min", comment: "TL;DR bar — %@ is a number of minutes"),
		"regenerate": NSLocalizedString("Regenerate", comment: "TL;DR card button"),
		"hide": NSLocalizedString("Hide", comment: "TL;DR card button"),
		"tryAgain": NSLocalizedString("Try again", comment: "TL;DR card button"),
		"cancel": NSLocalizedString("Cancel", comment: "TL;DR card button"),
		"generating": NSLocalizedString("Summarizing on device", comment: "TL;DR card progress"),
		"footerLanguageModel": NSLocalizedString("Generated on device · may be inaccurate", comment: "TL;DR card footer"),
		"footerExtractive": NSLocalizedString("Key sentences from the article · generated on device", comment: "TL;DR card footer"),
		"short": SummaryLength.short.displayName,
		"medium": SummaryLength.medium.displayName,
		"detailed": SummaryLength.detailed.displayName,
		"shortcut": "⌘⇧S"
	]
}
