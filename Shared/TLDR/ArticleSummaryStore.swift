//
//  ArticleSummaryStore.swift
//  NetNewsWire
//
//  Created by Balázs on 9/7/26.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation
import os
import RSCore

extension Notification.Name {
	/// userInfo: `ArticleSummaryStore.UserInfoKey.articleIDs` → `Set<String>`
	static let articleSummariesDidChange = Notification.Name("ArticleSummariesDidChange")
}

/// Keeps generated TL;DRs so an article is summarized once, the card comes back when the
/// reader returns to the article, and the timeline can badge articles that have one.
///
/// In memory keyed by article ID, mirrored to a small JSON file in Application Support.
/// Bounded — oldest summaries drop off — because summaries are cheap to regenerate.
@MainActor final class ArticleSummaryStore {

	static let shared = ArticleSummaryStore()

	struct UserInfoKey {
		static let articleIDs = "articleIDs"
	}

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "ArticleSummaryStore")
	private static let maximumSummaryCount = 500
	private static let saveDelay: Duration = .seconds(1)

	private var summaries = [String: [SummaryLength: ArticleSummary]]()
	private let fileURL: URL?
	private var saveTask: Task<Void, Never>?

	init() {
		if let folder = Platform.dataSubfolder(forApplication: nil, folderName: "TLDR") {
			fileURL = URL(fileURLWithPath: folder).appendingPathComponent("Summaries.json")
		} else {
			fileURL = nil
		}
		load()
	}

	// MARK: - API

	func summary(for articleID: String, length: SummaryLength) -> ArticleSummary? {
		summaries[articleID]?[length]
	}

	/// True when any length has been generated. Drives the TL;DR badge in the timeline.
	func hasSummary(for articleID: String) -> Bool {
		guard let byLength = summaries[articleID] else {
			return false
		}
		return !byLength.isEmpty
	}

	func add(_ summary: ArticleSummary) {
		summaries[summary.articleID, default: [:]][summary.length] = summary
		prune()
		didChange(articleIDs: [summary.articleID])
	}

	func removeSummary(for articleID: String, length: SummaryLength) {
		guard summaries[articleID]?.removeValue(forKey: length) != nil else {
			return
		}
		if summaries[articleID]?.isEmpty == true {
			summaries.removeValue(forKey: articleID)
		}
		didChange(articleIDs: [articleID])
	}

	func removeSummaries(for articleID: String) {
		guard summaries.removeValue(forKey: articleID) != nil else {
			return
		}
		didChange(articleIDs: [articleID])
	}
}

// MARK: - Private

private extension ArticleSummaryStore {

	func didChange(articleIDs: Set<String>) {
		NotificationCenter.default.post(name: .articleSummariesDidChange, object: self, userInfo: [UserInfoKey.articleIDs: articleIDs])
		scheduleSave()
	}

	/// Drop the oldest summaries once over the cap. Runs on every add, but the cap is small
	/// and adds are user-paced, so the sort is not a cost that shows.
	func prune() {
		let all = summaries.values.flatMap { $0.values }
		guard all.count > Self.maximumSummaryCount else {
			return
		}
		let toRemove = all.sorted { $0.dateGenerated < $1.dateGenerated }.prefix(all.count - Self.maximumSummaryCount)
		for summary in toRemove {
			summaries[summary.articleID]?.removeValue(forKey: summary.length)
			if summaries[summary.articleID]?.isEmpty == true {
				summaries.removeValue(forKey: summary.articleID)
			}
		}
	}

	// MARK: Persistence

	func scheduleSave() {
		saveTask?.cancel()
		saveTask = Task { @MainActor [weak self] in
			try? await Task.sleep(for: Self.saveDelay)
			guard !Task.isCancelled else {
				return
			}
			self?.save()
		}
	}

	func save() {
		guard let fileURL else {
			return
		}
		let all = summaries.values.flatMap { $0.values }
		do {
			let encoder = JSONEncoder()
			encoder.dateEncodingStrategy = .iso8601
			let data = try encoder.encode(all)
			let logger = Self.logger
			Task.detached(priority: .utility) {
				do {
					try data.write(to: fileURL, options: .atomic)
				} catch {
					logger.error("ArticleSummaryStore: could not write summaries: \(error.localizedDescription)")
				}
			}
		} catch {
			Self.logger.error("ArticleSummaryStore: could not encode summaries: \(error.localizedDescription)")
		}
	}

	func load() {
		guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
			return
		}
		do {
			let data = try Data(contentsOf: fileURL)
			let decoder = JSONDecoder()
			decoder.dateDecodingStrategy = .iso8601
			let all = try decoder.decode([ArticleSummary].self, from: data)
			for summary in all {
				summaries[summary.articleID, default: [:]][summary.length] = summary
			}
		} catch {
			// A damaged cache is not worth a crash or an alert — start fresh.
			Self.logger.error("ArticleSummaryStore: could not read summaries, starting empty: \(error.localizedDescription)")
			summaries = [:]
		}
	}
}
