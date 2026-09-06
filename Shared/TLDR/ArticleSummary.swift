//
//  ArticleSummary.swift
//  NetNewsWire
//
//  Created by Balázs on 9/7/26.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation

/// Which engine produced a summary. Shown in the card’s footer so the reader
/// knows how much to trust it.
enum SummaryEngine: String, Codable, Sendable {

	/// Apple’s on-device language model (Apple Intelligence, macOS 26 and later).
	case languageModel

	/// Sentences pulled straight from the article by frequency scoring. No model involved.
	case extractive
}

/// A generated TL;DR for one article at one length. Immutable; regenerate by replacing it.
struct ArticleSummary: Codable, Equatable, Sendable {

	let articleID: String
	let length: SummaryLength
	let text: String
	let engine: SummaryEngine
	let dateGenerated: Date
}
