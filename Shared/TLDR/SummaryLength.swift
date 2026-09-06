//
//  SummaryLength.swift
//  NetNewsWire
//
//  Created by Balázs on 9/7/26.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation

/// How long a TL;DR should be.
///
/// Raw values are stored in user defaults and in the summary cache, and travel to
/// the article web view as JSON — don’t rename them.
enum SummaryLength: String, CaseIterable, Codable, Sendable {

	case short
	case medium
	case detailed

	static let `default` = SummaryLength.short

	var displayName: String {
		switch self {
		case .short:
			return NSLocalizedString("Short", comment: "TL;DR summary length")
		case .medium:
			return NSLocalizedString("Medium", comment: "TL;DR summary length")
		case .detailed:
			return NSLocalizedString("Detailed", comment: "TL;DR summary length")
		}
	}

	/// Sentence budget. The extractive summarizer picks exactly this many sentences;
	/// the language model is told to stay at or under it.
	var sentenceCount: Int {
		switch self {
		case .short:
			return 2
		case .medium:
			return 4
		case .detailed:
			return 7
		}
	}

	/// Cap on the language model’s answer. Generous enough that a sentence isn’t cut mid-way.
	var maximumResponseTokens: Int {
		switch self {
		case .short:
			return 120
		case .medium:
			return 220
		case .detailed:
			return 400
		}
	}

	/// Length guidance in the prompt. Kept separate from `sentenceCount` so the wording can be tuned
	/// without touching the extractive path.
	var languageModelGuidance: String {
		switch self {
		case .short:
			return "Write one or two sentences. Lead with the single most important point."
		case .medium:
			return "Write three or four sentences covering the main argument and the key supporting facts."
		case .detailed:
			return "Write a paragraph of five to seven sentences: the main argument, the key evidence or examples, and the conclusion or call to action."
		}
	}
}
