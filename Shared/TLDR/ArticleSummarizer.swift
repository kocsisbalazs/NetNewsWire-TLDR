//
//  ArticleSummarizer.swift
//  NetNewsWire
//
//  Created by Balázs on 9/7/26.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation
import os
import RSCore
#if canImport(FoundationModels)
import FoundationModels
#endif

enum ArticleSummarizerError: LocalizedError {

	case nothingToSummarize

	var errorDescription: String? {
		switch self {
		case .nothingToSummarize:
			return NSLocalizedString("This article has no text to summarize.", comment: "TL;DR error")
		}
	}
}

/// Produces a TL;DR for an article, entirely on device.
///
/// Two engines, tried in order:
/// 1. Apple’s on-device language model via FoundationModels — macOS 26 / iOS 26 with Apple
///    Intelligence on. Long articles are condensed chunk by chunk first, because the model’s
///    context window is small.
/// 2. `ExtractiveSummarizer` — always available, never fails on text that has sentences.
///
/// The fallback is what makes the feature dependable: guardrails reject some news, the model
/// declines some languages, and a lot of Macs won’t have it at all.
@MainActor final class ArticleSummarizer {

	static let shared = ArticleSummarizer()

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "ArticleSummarizer")

	// ~1,500–2,000 tokens for most languages, leaving room for instructions and the answer in a 4k window.
	private static let languageModelChunkCharacters = 6_000
	// Bounds latency on very long articles. Beyond this we summarize the beginning, which is
	// where the argument lives in most writing.
	private static let maximumLanguageModelChunks = 8

	private let extractiveSummarizer = ExtractiveSummarizer()

	/// The engine the next request will use. Cheap to call; drives the card’s footer before generation.
	var engine: SummaryEngine {
		Self.languageModelIsAvailable ? .languageModel : .extractive
	}

	/// - Parameters:
	///   - text: Plain text (see `SummarySourceText.plainText(fromHTML:)`), not HTML.
	///   - title: Plain-text title, used only to orient the model.
	/// - Throws: `CancellationError` if the task is cancelled; `ArticleSummarizerError.nothingToSummarize` for empty input.
	func summarize(articleID: String, title: String, text: String, length: SummaryLength) async throws -> ArticleSummary {
		let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else {
			throw ArticleSummarizerError.nothingToSummarize
		}
		try Task.checkCancellation()

#if canImport(FoundationModels)
		if #available(macOS 26.0, iOS 26.0, *), Self.languageModelIsAvailable {
			do {
				let summaryText = try await summarizeWithLanguageModel(title: title, text: text, length: length)
				if !summaryText.isEmpty {
					return ArticleSummary(articleID: articleID, length: length, text: summaryText, engine: .languageModel, dateGenerated: Date())
				}
			} catch is CancellationError {
				throw CancellationError()
			} catch {
				// Guardrail, context window, or language refusal — the extractive path still gives the reader something.
				Self.logger.info("Language model summary failed, falling back to extractive: \(error.localizedDescription)")
			}
		}
#endif

		let summarizer = extractiveSummarizer
		let sentenceCount = length.sentenceCount
		let summaryText = await Task.detached(priority: .userInitiated) {
			summarizer.summarize(text, sentenceCount: sentenceCount)
		}.value
		try Task.checkCancellation()

		guard !summaryText.isEmpty else {
			throw ArticleSummarizerError.nothingToSummarize
		}
		return ArticleSummary(articleID: articleID, length: length, text: summaryText, engine: .extractive, dateGenerated: Date())
	}
}

// MARK: - Private

private extension ArticleSummarizer {

	static var languageModelIsAvailable: Bool {
#if canImport(FoundationModels)
		if #available(macOS 26.0, iOS 26.0, *) {
			if case .available = SystemLanguageModel.default.availability {
				return true
			}
		}
#endif
		return false
	}

	/// Whitespace-boundary chunks of at most `maximumCharacters`. Words are never split.
	static func chunks(of text: String, maximumCharacters: Int) -> [String] {
		if text.count <= maximumCharacters {
			return [text]
		}

		var chunks = [String]()
		var current = ""
		current.reserveCapacity(maximumCharacters)

		for word in text.split(separator: " ", omittingEmptySubsequences: true) {
			if !current.isEmpty && current.count + word.count + 1 > maximumCharacters {
				chunks.append(current)
				current = ""
			}
			if !current.isEmpty {
				current.append(" ")
			}
			current.append(contentsOf: word)
		}
		if !current.isEmpty {
			chunks.append(current)
		}
		return chunks
	}
}

// MARK: - FoundationModels

#if canImport(FoundationModels)

@available(macOS 26.0, iOS 26.0, *)
private extension ArticleSummarizer {

	static let instructions = """
	You write TL;DR summaries of articles for the reader of an RSS app. \
	Write in the same language as the article. Be concrete: keep the names, numbers, and the author's actual claims. \
	Report what the article says; do not add your own opinions or outside facts. \
	Do not mention that this is a summary, do not address the reader, and do not use bullet points, headings, or quotation marks. \
	Plain prose only.
	"""

	func summarizeWithLanguageModel(title: String, text: String, length: SummaryLength) async throws -> String {
		let chunks = Array(Self.chunks(of: text, maximumCharacters: Self.languageModelChunkCharacters).prefix(Self.maximumLanguageModelChunks))

		var source = text
		if chunks.count > 1 {
			// Two passes: condense every chunk, then summarize the condensed whole.
			var partials = [String]()
			for (index, chunk) in chunks.enumerated() {
				try Task.checkCancellation()
				let session = LanguageModelSession(instructions: Self.instructions)
				let prompt = """
				This is part \(index + 1) of \(chunks.count) of the article "\(title)". \
				Condense this part into at most four sentences, keeping every fact a summary of the whole article would need.

				\(chunk)
				"""
				let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.3, maximumResponseTokens: 260))
				partials.append(response.content.trimmingCharacters(in: .whitespacesAndNewlines))
			}
			source = partials.joined(separator: "\n\n")
		}

		try Task.checkCancellation()
		let session = LanguageModelSession(instructions: Self.instructions)
		let prompt = """
		Summarize the article "\(title)". \(length.languageModelGuidance)

		\(source)
		"""
		let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.3, maximumResponseTokens: length.maximumResponseTokens))
		return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
	}
}

#endif
