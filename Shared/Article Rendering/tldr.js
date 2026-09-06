// TL;DR bar and card, inserted above the article body.
//
// Swift owns the state. DetailWebViewController calls nnwTLDR.render(state) whenever it
// changes, and every control here just posts an action back on the "tldr" message handler.
// Labels come from nnwTLDRStrings, injected by WebViewConfiguration at document start.
//
// state: { status: "unavailable" | "idle" | "generating" | "ready" | "failed" | "hidden",
//          length: "short" | "medium" | "detailed", summary?, engine?, error? }

var nnwTLDR = (function () {

	var wordsPerMinute = 230;
	var container = null;
	var lastState = null;

	var icon = '<svg class="nnw-tldr-icon" viewBox="0 0 16 16" aria-hidden="true">' +
		'<path d="M1.5 3.5h9M1.5 8h6M1.5 12.5h8" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" fill="none"/>' +
		'<path d="M12.6 7.2l.85 2.05 2.05.85-2.05.85-.85 2.05-.85-2.05-2.05-.85 2.05-.85z" fill="currentColor"/>' +
		'</svg>';

	function text(key, fallback) {
		if (typeof nnwTLDRStrings !== "undefined" && nnwTLDRStrings[key]) {
			return nnwTLDRStrings[key];
		}
		return fallback;
	}

	function post(action, length) {
		if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.tldr) {
			return;
		}
		var message = { action: action };
		if (length) {
			message.length = length;
		}
		window.webkit.messageHandlers.tldr.postMessage(message);
	}

	// .article-body is the Biblioteca theme's name for .articleBody.
	function bodyContainer() {
		return document.querySelector("#bodyContainer, .articleBody, .article-body");
	}

	function wordCount(element) {
		var s = element.innerText || element.textContent || "";
		var words = s.trim().split(/\s+/).filter(function (w) { return w.length > 0; });
		return words.length;
	}

	function element(tag, className, content) {
		var el = document.createElement(tag);
		if (className) {
			el.className = className;
		}
		if (content !== undefined) {
			el.textContent = content;
		}
		return el;
	}

	function button(label, className, onClick) {
		var el = element("button", className, label);
		el.type = "button";
		el.addEventListener("click", function (event) {
			event.preventDefault();
			event.stopPropagation();
			onClick();
		});
		return el;
	}

	// Called from postRenderProcessing() once the article DOM exists.
	function install() {
		if (container) {
			return;
		}
		var body = bodyContainer();
		if (!body) {
			return;
		}
		container = element("div", "nnw-tldr");
		container.id = "nnwTLDR";
		container.setAttribute("data-words", String(wordCount(body)));
		body.parentNode.insertBefore(container, body);
		if (lastState) {
			render(lastState);
		}
	}

	// Called from Swift. Safe to call before install(); the state is applied when the DOM is ready.
	function render(state) {
		lastState = state;
		if (!container) {
			return;
		}
		while (container.firstChild) {
			container.removeChild(container.firstChild);
		}
		if (!state || state.status === "unavailable") {
			container.hidden = true;
			return;
		}
		container.hidden = false;
		if (state.status === "idle" || state.status === "hidden") {
			container.appendChild(bar(state));
		} else {
			container.appendChild(card(state));
		}
	}

	// "1,420 words · ~7 min — summarize with TL;DR   ⌘⇧S"
	function bar(state) {
		var words = parseInt(container.getAttribute("data-words"), 10) || 0;
		var minutes = Math.max(1, Math.round(words / wordsPerMinute));
		var action = state.status === "hidden" ? text("show", "show TL;DR") : text("summarize", "summarize with TL;DR");

		var el = element("div", "nnw-tldr-bar");
		el.setAttribute("role", "button");
		el.setAttribute("tabindex", "0");
		el.setAttribute("aria-label", action);

		var iconWrap = element("span", "nnw-tldr-iconwrap");
		iconWrap.innerHTML = icon;
		el.appendChild(iconWrap);

		var label = text("wordCount", "%@ words").replace("%@", words.toLocaleString()) +
			" · " + text("readingTime", "~%@ min").replace("%@", String(minutes)) +
			" — " + action;
		el.appendChild(element("span", "nnw-tldr-bar-label", label));

		var shortcut = text("shortcut", "");
		if (shortcut) {
			el.appendChild(element("kbd", "nnw-tldr-kbd", shortcut));
		}

		var activate = function () {
			post(state.status === "hidden" ? "show" : "summarize", state.length);
		};
		el.addEventListener("click", activate);
		el.addEventListener("keydown", function (event) {
			if (event.key === "Enter" || event.key === " ") {
				event.preventDefault();
				activate();
			}
		});
		return el;
	}

	function card(state) {
		var el = element("section", "nnw-tldr-card nnw-tldr-" + state.status);
		el.setAttribute("aria-label", text("title", "TL;DR"));

		// Header: icon, title, Regenerate / Hide.
		var header = element("header", "nnw-tldr-header");
		var titleWrap = element("div", "nnw-tldr-title");
		var iconWrap = element("span", "nnw-tldr-iconwrap");
		iconWrap.innerHTML = icon;
		titleWrap.appendChild(iconWrap);
		titleWrap.appendChild(element("span", null, text("title", "TL;DR")));
		header.appendChild(titleWrap);

		var actions = element("div", "nnw-tldr-actions");
		if (state.status === "ready") {
			actions.appendChild(button(text("regenerate", "Regenerate"), "nnw-tldr-button", function () {
				post("regenerate", state.length);
			}));
		}
		if (state.status === "generating") {
			actions.appendChild(button(text("cancel", "Cancel"), "nnw-tldr-button", function () {
				post("cancel");
			}));
		}
		actions.appendChild(button(text("hide", "Hide"), "nnw-tldr-button", function () {
			post("hide");
		}));
		header.appendChild(actions);
		el.appendChild(header);

		// Body.
		var body = element("div", "nnw-tldr-body");
		if (state.status === "generating") {
			var progress = element("p", "nnw-tldr-generating", text("generating", "Summarizing on device"));
			progress.appendChild(element("span", "nnw-tldr-dots", "…"));
			body.appendChild(progress);
		} else if (state.status === "failed") {
			body.appendChild(element("p", "nnw-tldr-error", state.error || ""));
			body.appendChild(button(text("tryAgain", "Try again"), "nnw-tldr-button nnw-tldr-retry", function () {
				post("regenerate", state.length);
			}));
		} else {
			body.appendChild(element("p", "nnw-tldr-summary", state.summary || ""));
		}
		el.appendChild(body);

		// Footer: Short / Medium / Detailed, and the honesty note.
		var footer = element("footer", "nnw-tldr-footer");
		var segments = element("div", "nnw-tldr-segments");
		segments.setAttribute("role", "radiogroup");
		["short", "medium", "detailed"].forEach(function (length) {
			var segment = button(text(length, length), "nnw-tldr-segment", function () {
				if (length !== state.length || state.status === "failed") {
					post("summarize", length);
				}
			});
			segment.setAttribute("role", "radio");
			segment.setAttribute("aria-checked", String(length === state.length));
			if (length === state.length) {
				segment.classList.add("nnw-tldr-segment-selected");
			}
			if (state.status === "generating") {
				segment.disabled = true;
			}
			segments.appendChild(segment);
		});
		footer.appendChild(segments);

		var note = state.engine === "extractive" ?
			text("footerExtractive", "Key sentences from the article · generated on device") :
			text("footerLanguageModel", "Generated on device · may be inaccurate");
		footer.appendChild(element("span", "nnw-tldr-note", state.status === "ready" ? note : ""));
		el.appendChild(footer);

		return el;
	}

	return {
		install: install,
		render: render
	};
})();
