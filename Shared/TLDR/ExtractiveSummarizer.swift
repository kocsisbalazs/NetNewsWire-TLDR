//
//  ExtractiveSummarizer.swift
//  NetNewsWire
//
//  Created by Balázs on 9/7/26.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation
import NaturalLanguage

/// Picks the most representative sentences of an article and returns them in reading order.
///
/// This is the fallback when the on-device language model isn’t available (macOS 15, Apple
/// Intelligence turned off, unsupported hardware) or declines an article (guardrails, context
/// window, unsupported language). It is pure computation — no network, no model, no failure
/// modes beyond “the article had no sentences” — which is what lets the TL;DR button work
/// for every article.
///
/// Scoring: each content word gets its frequency in the article; a sentence scores the sum of
/// its words’ frequencies, normalized by √(word count) so long sentences don’t win by default.
/// The lead sentence gets a bonus because that is where news writing puts the point.
struct ExtractiveSummarizer: Sendable {

	private static let minimumWordsPerSentence = 5
	private static let leadSentenceBonus = 1.4

	func summarize(_ text: String, sentenceCount: Int) -> String {
		let sentences = Self.sentences(in: text)
		if sentences.count <= sentenceCount {
			return sentences.joined(separator: " ")
		}

		let frequency = Self.wordFrequencies(in: text)

		var scored = [(index: Int, score: Double)]()
		scored.reserveCapacity(sentences.count)

		for (index, sentence) in sentences.enumerated() {
			let words = Self.contentWords(in: sentence)
			// Captions, bylines, “Read more” — not summary material.
			guard words.count >= Self.minimumWordsPerSentence else {
				continue
			}
			var score = words.reduce(0.0) { $0 + Double(frequency[$1] ?? 0) }
			score /= Double(words.count).squareRoot()
			if index == 0 {
				score *= Self.leadSentenceBonus
			}
			scored.append((index, score))
		}

		let chosen = scored
			.sorted { $0.score > $1.score }
			.prefix(sentenceCount)
			.map { $0.index }
			.sorted()

		if chosen.isEmpty {
			return sentences.prefix(sentenceCount).joined(separator: " ")
		}
		return chosen.map { sentences[$0] }.joined(separator: " ")
	}
}

// MARK: - Private

private extension ExtractiveSummarizer {

	static func sentences(in text: String) -> [String] {
		let tokenizer = NLTokenizer(unit: .sentence)
		tokenizer.string = text

		var sentences = [String]()
		tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
			let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
			if !sentence.isEmpty {
				sentences.append(sentence)
			}
			return true
		}
		return sentences
	}

	static func wordFrequencies(in text: String) -> [String: Int] {
		var frequency = [String: Int]()
		for word in contentWords(in: text) {
			frequency[word, default: 0] += 1
		}
		return frequency
	}

	/// Lowercased words worth counting: three or more characters and not a stop word.
	static func contentWords(in text: String) -> [String] {
		let tokenizer = NLTokenizer(unit: .word)
		tokenizer.string = text

		var words = [String]()
		tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
			let word = text[range].lowercased()
			if word.count > 2 && !stopWords.contains(word) {
				words.append(word)
			}
			return true
		}
		return words
	}

	/// English function words. Other languages still work — frequency scoring is language-agnostic —
	/// their function words just count a little, which slightly favors longer sentences.
	static let stopWords: Set<String> = [
		"the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was", "one", "our",
		"out", "day", "get", "has", "him", "his", "how", "man", "new", "now", "old", "see", "two", "way", "who",
		"did", "its", "let", "put", "say", "she", "too", "use", "that", "with", "have", "this", "will", "your", "from",
		"they", "know", "want", "been", "good", "much", "some", "time", "very", "when", "come", "here", "just", "like", "long",
		"make", "many", "more", "most", "only", "over", "such", "take", "than", "them", "then", "these", "those", "through", "were",
		"what", "where", "which", "while", "would", "about", "after", "again", "also", "because", "before", "being", "between", "both", "could",
		"does", "doing", "down", "during", "each", "even", "every", "into", "itself", "other", "should", "since", "still", "there", "their",
		"under", "until", "upon", "well", "went", "whether", "without", "onto", "said", "says", "yet"
	]
}
