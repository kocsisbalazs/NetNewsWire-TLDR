//
//  SummarySourceText.swift
//  NetNewsWire
//
//  Created by Balázs on 9/7/26.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation
import RSCore
import RSParser

/// Turns article HTML into the plain text a summarizer can work with.
enum SummarySourceText {

	/// Strip tags, decode entities, collapse whitespace.
	///
	/// Strip first, then decode — same reasoning as `ArticleStringFormatter.truncatedSummary`:
	/// entity-encoded tags like `&lt;i&gt;` are author intent and must not be treated as markup.
	static func plainText(fromHTML html: String) -> String {
		if html.isEmpty {
			return ""
		}
		let stripped = html.strippingHTML().decodingHTMLEntities()
		return collapsingWhitespace(stripped)
	}

	/// Roughly what a reader would count. Used only for messages, never for layout.
	static func wordCount(_ text: String) -> Int {
		text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
	}

	private static func collapsingWhitespace(_ s: String) -> String {
		var result = ""
		result.reserveCapacity(s.count)
		var previousWasSpace = true // also drops leading whitespace
		for character in s {
			if character.isWhitespace || character.isNewline {
				if !previousWasSpace {
					result.append(" ")
					previousWasSpace = true
				}
			} else {
				result.append(character)
				previousWasSpace = false
			}
		}
		if result.hasSuffix(" ") {
			result.removeLast()
		}
		return result
	}
}
