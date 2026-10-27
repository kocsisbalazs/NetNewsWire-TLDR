//
//  DetailWebViewController.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 2/11/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import AppKit
@preconcurrency import WebKit
import os
import RSCore
import Articles
import Images

@MainActor protocol DetailWebViewControllerDelegate: AnyObject {
	func mouseDidEnter(_: DetailWebViewController, link: String)
	func mouseDidExit(_: DetailWebViewController)
	func tldrStateDidChange(_: DetailWebViewController)
}

final class DetailWebViewController: NSViewController {

	static private let logger = Logger(subsystem: Logger.nnwSubsystem, category: "DetailWebViewController")

	weak var delegate: DetailWebViewControllerDelegate?
	var webView: DetailWebView!
	var state: DetailState = .noSelection {
		didSet {
			if state != oldValue {
				switch state {
				case .article(_, let scrollY), .extracted(_, _, let scrollY):
					windowScrollY = scrollY
					pendingScrollRestorationY = scrollY
				default:
					break
				}
				resetTLDRState()
				reloadHTML()
			}
		}
	}

	/// The TL;DR card's state for the current article. Pushed to the page on every change.
	private(set) var tldrState = TLDRState(status: .unavailable, length: AppDefaults.shared.tldrSummaryLength) {
		didSet {
			if tldrState != oldValue {
				pushTLDRStateToWebView()
				delegate?.tldrStateDidChange(self)
			}
		}
	}

	var windowState: DetailWindowState {
		DetailWindowState(isShowingExtractedArticle: isShowingExtractedArticle, windowScrollY: windowScrollY ?? 0)
	}

	var article: Article? {
		switch state {
		case .article(let article, _):
			return article
		case .extracted(let article, _, _):
			return article
		default:
			return nil
		}
	}

	private var articleTextSize = AppDefaults.shared.articleTextSize

	private var summaryTask: Task<Void, Never>?
	// Bumped on every summarize/cancel. A finishing task compares against it so a stale result
	// (say, a slow first attempt landing after Regenerate) can't overwrite the current one.
	private var summaryGeneration = 0

	// Articles whose card the reader closed. Session-only, and shared across the regular and
	// search web views so hiding in one doesn't reopen in the other.
	private static var hiddenSummaryArticleIDs = Set<String>()

	private var webInspectorEnabled: Bool {
		get {
			return webView.configuration.preferences._developerExtrasEnabled
		}
		set {
			webView.configuration.preferences._developerExtrasEnabled = newValue
		}
	}

	private let detailIconSchemeHandler = DetailIconSchemeHandler()
	private var waitingForFirstReload = false
	private var isReloadingHTML = false
	private let keyboardDelegate = DetailKeyboardDelegate()
	private var windowScrollY: CGFloat?

	// The scroll offset to apply to the next-loaded article. Kept separate from windowScrollY,
	// which windowDidScroll messages still arriving from the previous article can overwrite.
	private var pendingScrollRestorationY: CGFloat?

	// The page posts windowDidScroll continuously while scrolling, including during momentum.
	private var lastWindowDidScrollMessageDate: Date?
	private static let recentScrollInterval: TimeInterval = 0.2

	private var webViewMayStillBeScrolling: Bool {
		guard let lastWindowDidScrollMessageDate else {
			return false
		}
		return Date().timeIntervalSince(lastWindowDidScrollMessageDate) < Self.recentScrollInterval
	}

	private var isShowingExtractedArticle: Bool {
		switch state {
		case .extracted:
			return true
		default:
			return false
		}
	}

	private struct MessageName {
		static let mouseDidEnter = "mouseDidEnter"
		static let mouseDidExit = "mouseDidExit"
		static let windowDidScroll = "windowDidScroll"
		static let tldr = "tldr"
	}

	override func loadView() {

		view = NSView()

		webView = createWebView()
		view.addSubview(webView)

		// Hide the web view until the first reload (navigation) is committed (plus some delay) to avoid the white flash that happens on initial display in dark mode.
		// See bug #901.
		webView.isHidden = true
		waitingForFirstReload = true

		NotificationCenter.default.addObserver(self, selector: #selector(webInspectorEnabledDidChange(_:)), name: .WebInspectorEnabledDidChange, object: nil)

		NotificationCenter.default.addObserver(self, selector: #selector(feedIconDidBecomeAvailable(_:)), name: .feedIconDidBecomeAvailable, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(avatarDidBecomeAvailable(_:)), name: .AvatarDidBecomeAvailable, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(faviconDidBecomeAvailable(_:)), name: .FaviconDidBecomeAvailable, object: nil)
		NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
			Task { @MainActor in
				self?.userDefaultsDidChange()
			}
		}
		NotificationCenter.default.addObserver(self, selector: #selector(currentArticleThemeDidChangeNotification(_:)), name: .CurrentArticleThemeDidChangeNotification, object: nil)

		webView.loadFileURL(ArticleRenderer.blank.url, allowingReadAccessTo: ArticleRenderer.blank.baseURL)
	}

	// MARK: Notifications

	@objc func feedIconDidBecomeAvailable(_ note: Notification) {
		reloadArticleImage()
	}

	@objc func avatarDidBecomeAvailable(_ note: Notification) {
		reloadArticleImage()
	}

	@objc func faviconDidBecomeAvailable(_ note: Notification) {
		reloadArticleImage()
	}

	func userDefaultsDidChange() {
		if articleTextSize != AppDefaults.shared.articleTextSize {
			articleTextSize = AppDefaults.shared.articleTextSize
			reloadHTMLMaintainingScrollPosition()
		}
	}

	@objc func currentArticleThemeDidChangeNotification(_ note: Notification) {
		reloadHTMLMaintainingScrollPosition()
	}

	// MARK: Media Functions

	func stopMediaPlayback() {
		webView.evaluateJavaScript("stopMediaPlayback();")
	}

	// MARK: Selection

	func fetchSelectedHTML(_ completion: @escaping (String?) -> Void) {
		webView.evaluateJavaScript("selectedHTML()") { result, _ in
			guard let selectedHTML = (result as? String)?.trimmingWhitespace, !selectedHTML.isEmpty else {
				completion(nil)
				return
			}
			completion(selectedHTML)
		}
	}

	// MARK: TL;DR

	/// Toolbar button, menu item, and ⌘⇧S all land here.
	func toggleTLDR() {
		switch tldrState.status {
		case .unavailable:
			break
		case .generating:
			cancelSummarization()
		case .ready:
			hideSummary()
		case .hidden:
			showSummary()
		case .idle, .failed:
			summarize(length: tldrState.length, regenerate: false)
		}
	}

	// MARK: Scrolling

	func canScrollDown() async -> Bool {
		let scrollInfo = await fetchScrollInfo()
		return scrollInfo?.canScrollDown ?? false
	}

	func canScrollUp() async -> Bool {
		let scrollInfo = await fetchScrollInfo()
		return scrollInfo?.canScrollUp ?? false
	}

	override func scrollPageDown(_ sender: Any?) {
		webView.scrollPageDown(sender)
	}

	override func scrollPageUp(_ sender: Any?) {
		webView.scrollPageUp(sender)
	}
}

// MARK: - WKScriptMessageHandler

extension DetailWebViewController: WKScriptMessageHandler {

	func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
		if message.name == MessageName.windowDidScroll {
			windowScrollY = message.body as? CGFloat
			lastWindowDidScrollMessageDate = Date()
		} else if message.name == MessageName.mouseDidEnter, let link = message.body as? String {
			delegate?.mouseDidEnter(self, link: link)
		} else if message.name == MessageName.mouseDidExit {
			delegate?.mouseDidExit(self)
		} else if message.name == MessageName.tldr, message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let action = body["action"] as? String {
			handleTLDRMessage(action: action, lengthRawValue: body["length"] as? String)
		}
	}
}

// MARK: - WKNavigationDelegate & WKUIDelegate

extension DetailWebViewController: WKNavigationDelegate, WKUIDelegate {

	// Bottleneck through which WebView-based URL opens go
	func openInBrowser(_ url: URL, flags: NSEvent.ModifierFlags) {
		let invert = flags.contains(.shift) || flags.contains(.command)
		Browser.open(url.absoluteString, invertPreference: invert)
	}

	// WKNavigationDelegate

	func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
		if navigationAction.navigationType == .linkActivated {
			if let url = navigationAction.request.url {
				self.openInBrowser(url, flags: navigationAction.modifierFlags)
			}
			decisionHandler(.cancel)
			return
		}

		// <https://github.com/Ranchero-Software/NetNewsWire/issues/5381>
		if navigationAction.navigationType == .backForward {
			decisionHandler(.cancel)
			return
		}

		decisionHandler(.allow)
	}

	public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
		// See note in loadView()
		guard waitingForFirstReload else {
			return
		}

		assert(webView.isHidden)
		waitingForFirstReload = false
		reloadHTML()

		// Waiting for the first navigation to commit isn't enough to avoid the flash of white.
		// Delaying an additional half a second seems to be enough.
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
			webView.isHidden = false
		}
	}

	public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
		guard webView === self.webView else {
			return
		}

		removeOldWebViews()

		if let pendingScrollRestorationY {
			webView.evaluateJavaScript("window.scrollTo(0, \(pendingScrollRestorationY));")
			self.pendingScrollRestorationY = nil
		}

		// The page starts from scratch on every load; tell it where the TL;DR is.
		pushTLDRStateToWebView()
	}

	func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
		// Content process died — swap in a fresh web view and re-render.
		guard webView === self.webView else {
			return
		}
		Self.logger.error("Article web content process terminated — rebuilding the web view.")
		let newWebView = createWebView()
		view.addSubview(newWebView, positioned: .below, relativeTo: self.webView)
		self.webView = newWebView
		reloadHTML()
	}

	// WKUIDelegate

	func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
		// This method is reached when WebKit handles a JavaScript based window.open() invocation, for example. One
		// example where this is used is in YouTube's embedded video player when a user clicks on the video's title
		// or on the "Watch in YouTube" button. For our purposes we'll handle such window.open calls the same way we
		// handle clicks on a URL.
		if let url = navigationAction.request.url {
			self.openInBrowser(url, flags: navigationAction.modifierFlags)
		}

		return nil
	}
}

// MARK: - Private

private extension DetailWebViewController {

	func reloadArticleImage() {
		guard let article = article else { return }

		var components = URLComponents()
		components.scheme = ArticleRenderer.imageIconScheme
		components.path = article.articleID

		if let imageSrc = components.string {
			webView?.evaluateJavaScript("reloadArticleImage(\"\(imageSrc)\")")
		}
	}

	func createWebView() -> DetailWebView {
		let configuration = WebViewConfiguration.configuration(with: detailIconSchemeHandler)

		configuration.userContentController.add(self, name: MessageName.windowDidScroll)
		configuration.userContentController.add(self, name: MessageName.mouseDidEnter)
		configuration.userContentController.add(self, name: MessageName.mouseDidExit)
		configuration.userContentController.add(self, name: MessageName.tldr)

		let webView = DetailWebView(frame: view.bounds, configuration: configuration)
		webView.uiDelegate = self
		webView.navigationDelegate = self
		webView.keyboardDelegate = keyboardDelegate
		webView.autoresizingMask = [.width, .height]
		webView.configuration.preferences._developerExtrasEnabled = AppDefaults.shared.webInspectorEnabled

		return webView
	}

	// Old web views stay on top until the new one finishes loading — see reloadHTML().
	func removeOldWebViews() {
		for subview in view.subviews {
			guard let oldWebView = subview as? DetailWebView, oldWebView !== webView else {
				continue
			}
			if let window = view.window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: oldWebView) {
				window.makeFirstResponder(webView)
			}
			oldWebView.removeFromSuperview()
		}
	}

	func reloadHTMLMaintainingScrollPosition() {
		fetchScrollInfo { scrollInfo in
			self.pendingScrollRestorationY = scrollInfo?.offsetY
			self.reloadHTML()
		}
	}

	func reloadHTML() {
		// Guard against a re-entrancy crash.
		if isReloadingHTML {
			return
		}
		isReloadingHTML = true
		defer {
			isReloadingHTML = false
		}

		delegate?.mouseDidExit(self)

		let theme = ArticleThemesManager.shared.currentTheme
		let rendering: ArticleRenderer.Rendering

		switch state {
		case .noSelection:
			rendering = ArticleRenderer.noSelectionHTML(theme: theme)
		case .multipleSelection:
			rendering = ArticleRenderer.multipleSelectionHTML(theme: theme)
		case .loading:
			rendering = ArticleRenderer.loadingHTML(theme: theme)
		case .article(let article, _):
			detailIconSchemeHandler.currentArticle = article
			rendering = ArticleRenderer.articleHTML(article: article, theme: theme)
		case .extracted(let article, let extractedArticle, _):
			detailIconSchemeHandler.currentArticle = article
			rendering = ArticleRenderer.articleHTML(article: article, extractedArticle: extractedArticle, theme: theme)
		}

		let substitutions = [
			"title": rendering.title,
			"baseURL": rendering.baseURL,
			"style": rendering.style,
			"body": rendering.html
		]

		var html = try! MacroProcessor.renderedText(withTemplate: ArticleRenderer.page.html, substitutions: substitutions)
		html = ArticleRenderingSpecialCases.filterHTMLIfNeeded(baseURL: rendering.baseURL, html: html)
		// When the old article may still be scrolling, swap in a fresh web view for the
		// new content. Scrolling momentum lives in the web content process and survives
		// loading new HTML — replacing the web view is what keeps a flick on the old
		// article from scrolling the new one.
		// The old web view stays on top until the new one finishes loading, which also
		// covers the new web view's first paint.
		// <https://github.com/Ranchero-Software/NetNewsWire/issues/901>
		if !webView.isHidden && webViewMayStillBeScrolling {
			Self.logger.debug("DetailWebViewController: swapping in a fresh web view because the old one may still be scrolling")
			let newWebView = createWebView()
			view.addSubview(newWebView, positioned: .below, relativeTo: webView)
			webView = newWebView
		}

		WebViewConfiguration.addContentBlockingRules(to: webView)
		webView.loadHTMLString(html, baseURL: URL(string: rendering.baseURL))
	}

	func fetchScrollInfo() async -> ScrollInfo? {
		await withCheckedContinuation { continuation in
			self.fetchScrollInfo { scrollInfo in
				continuation.resume(returning: scrollInfo)
			}
		}
	}

	private func fetchScrollInfo(_ completion: @escaping (ScrollInfo?) -> Void) {
		let javascriptString = "var x = {contentHeight: document.body.scrollHeight, offsetY: document.body.scrollTop}; x"

		webView.evaluateJavaScript(javascriptString) { (info, _) in
			guard let info = info as? [String: Any] else {
				completion(nil)
				return
			}
			guard let contentHeight = info["contentHeight"] as? CGFloat, let offsetY = info["offsetY"] as? CGFloat else {
				completion(nil)
				return
			}

			let scrollInfo = ScrollInfo(contentHeight: contentHeight, viewHeight: self.webView.frame.height, offsetY: offsetY)
			completion(scrollInfo)
		}
	}

	@objc func webInspectorEnabledDidChange(_ notification: Notification) {
		self.webInspectorEnabled = notification.object! as! Bool
	}
}

// MARK: - TL;DR

private extension DetailWebViewController {

	/// Plain text of what the reader is looking at — the extracted article when Reader View is on.
	var summarySourceHTML: String? {
		switch state {
		case .article(let article, _):
			return article.body
		case .extracted(let article, let extractedArticle, _):
			return extractedArticle.content ?? article.body
		default:
			return nil
		}
	}

	func resetTLDRState() {
		summaryTask?.cancel()
		summaryTask = nil
		summaryGeneration += 1
		tldrState = initialTLDRState()
	}

	func initialTLDRState() -> TLDRState {
		let length = AppDefaults.shared.tldrSummaryLength
		guard let article, let html = summarySourceHTML, !html.isEmpty else {
			return TLDRState(status: .unavailable, length: length)
		}
		if let summary = ArticleSummaryStore.shared.summary(for: article.articleID, length: length) {
			let isHidden = Self.hiddenSummaryArticleIDs.contains(article.articleID)
			return TLDRState(status: isHidden ? .hidden : .ready, length: length, summary: summary)
		}
		return TLDRState(status: .idle, length: length)
	}

	func handleTLDRMessage(action: String, lengthRawValue: String?) {
		let length = lengthRawValue.flatMap(SummaryLength.init(rawValue:)) ?? tldrState.length
		switch action {
		case "summarize":
			summarize(length: length, regenerate: false)
		case "regenerate":
			summarize(length: length, regenerate: true)
		case "hide":
			hideSummary()
		case "show":
			showSummary()
		case "cancel":
			cancelSummarization()
		default:
			Self.logger.debug("DetailWebViewController: unknown tldr action \(action)")
		}
	}

	func summarize(length: SummaryLength, regenerate: Bool) {
		guard let article, let html = summarySourceHTML else {
			return
		}
		let articleID = article.articleID

		summaryTask?.cancel()
		AppDefaults.shared.tldrSummaryLength = length
		Self.hiddenSummaryArticleIDs.remove(articleID)

		if !regenerate, let cached = ArticleSummaryStore.shared.summary(for: articleID, length: length) {
			tldrState = TLDRState(status: .ready, length: length, summary: cached)
			return
		}

		let title = ArticleStringFormatter.sanitizedTitle(article.title, forHTML: false) ?? ""
		summaryGeneration += 1
		let generation = summaryGeneration
		tldrState = TLDRState(status: .generating, length: length)

		summaryTask = Task { @MainActor [weak self] in
			// Stripping HTML is proportional to article size; keep it off the main actor.
			let text = await Task.detached(priority: .userInitiated) {
				SummarySourceText.plainText(fromHTML: html)
			}.value

			do {
				let summary = try await ArticleSummarizer.shared.summarize(articleID: articleID, title: title, text: text, length: length)
				guard let self, self.summaryGeneration == generation, self.article?.articleID == articleID else {
					return
				}
				ArticleSummaryStore.shared.add(summary)
				self.tldrState = TLDRState(status: .ready, length: length, summary: summary)
			} catch is CancellationError {
				// Selection changed or the reader cancelled — whoever did that already set the state.
			} catch {
				guard let self, self.summaryGeneration == generation, self.article?.articleID == articleID else {
					return
				}
				DetailWebViewController.logger.error("DetailWebViewController: TL;DR failed: \(error.localizedDescription)")
				self.tldrState = TLDRState(status: .failed, length: length, errorMessage: error.localizedDescription)
			}
		}
	}

	func hideSummary() {
		guard let article else {
			return
		}
		// Hiding mid-generation is a cancel too — otherwise the card would pop back when the task finishes.
		summaryTask?.cancel()
		summaryTask = nil
		summaryGeneration += 1

		Self.hiddenSummaryArticleIDs.insert(article.articleID)
		if let summary = ArticleSummaryStore.shared.summary(for: article.articleID, length: tldrState.length) {
			tldrState = TLDRState(status: .hidden, length: tldrState.length, summary: summary)
		} else {
			tldrState = TLDRState(status: .idle, length: tldrState.length)
		}
	}

	func showSummary() {
		guard let article else {
			return
		}
		Self.hiddenSummaryArticleIDs.remove(article.articleID)
		if let summary = ArticleSummaryStore.shared.summary(for: article.articleID, length: tldrState.length) {
			tldrState = TLDRState(status: .ready, length: tldrState.length, summary: summary)
		} else {
			summarize(length: tldrState.length, regenerate: false)
		}
	}

	func cancelSummarization() {
		summaryTask?.cancel()
		summaryTask = nil
		summaryGeneration += 1
		tldrState = initialTLDRState()
	}

	func pushTLDRStateToWebView() {
		guard let webView, let json = tldrState.jsonString() else {
			return
		}
		webView.evaluateJavaScript("if (window.nnwTLDR) { nnwTLDR.render(\(json)); }")
	}
}

// MARK: - ScrollInfo

private struct ScrollInfo {

	let contentHeight: CGFloat
	let viewHeight: CGFloat
	let offsetY: CGFloat
	let canScrollDown: Bool
	let canScrollUp: Bool

	init(contentHeight: CGFloat, viewHeight: CGFloat, offsetY: CGFloat) {
		self.contentHeight = contentHeight
		self.viewHeight = viewHeight
		self.offsetY = offsetY

		self.canScrollDown = viewHeight + offsetY < contentHeight
		self.canScrollUp = offsetY > 0.1
	}
}
