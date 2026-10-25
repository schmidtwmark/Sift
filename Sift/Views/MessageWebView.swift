import SiftKit
import SwiftUI
import WebKit

/// Builds the document a message is rendered from: trackers removed, active
/// content stripped, wide layouts scaled to fit.
enum MessageHTML {
    /// How a message's colors are handled.
    nonisolated enum Style: Sendable, Equatable {
        /// Plain text or simple HTML: system text colors, light or dark.
        case system
        /// Designed HTML with its own dark-mode styles: left alone.
        case selfStyled
        /// Designed HTML built for white: recolored in dark mode, Mail-style.
        case recolored
    }

    struct Prepared: Sendable {
        var sanitized: SanitizedMessage
        var style: Style
    }

    nonisolated static func prepare(_ body: BodyRecord) -> Prepared {
        if let html = body.html {
            var sanitized = TrackerDetector.sanitize(html)
            let style: Style = isSimple(sanitized.html) ? .system : hasOwnDarkMode(sanitized.html) ? .selfStyled : .recolored
            sanitized.html = document(sanitized.html, style: style)
            return Prepared(sanitized: sanitized, style: style)
        }
        let sanitized = SanitizedMessage(html: document(plainTextHTML(body.text ?? ""), style: .system),
                                         trackers: [], remoteImageCount: 0)
        return Prepared(sanitized: sanitized, style: .system)
    }

    /// No layout tables, colors or embedded styles: the kind of HTML a person's
    /// mail client sends, as opposed to a designed newsletter.
    nonisolated static func isSimple(_ html: String) -> Bool {
        let lower = html.lowercased()
        return !["<table", "background", "bgcolor", "color:", "color=", "<style", "<img"].contains { lower.contains($0) }
    }

    /// Senders that ship dark-mode CSS know their design better than a recolor does.
    nonisolated static func hasOwnDarkMode(_ html: String) -> Bool {
        let compact = html.lowercased().replacingOccurrences(of: " ", with: "")
        return compact.contains("prefers-color-scheme:dark") || compact.contains("supported-color-schemes")
            || compact.range(of: #"name="color-scheme"content="[^"]*dark"#, options: .regularExpression) != nil
    }

    nonisolated static func plainTextHTML(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let escaped = linkify(HTMLText.escape(line))
            return line.hasPrefix(">") ? "<span class=\"quote\">\(escaped)</span>" : escaped
        }
        return "<div class=\"plain\">\(lines.joined(separator: "\n"))</div>"
    }

    nonisolated private static func linkify(_ escaped: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return escaped }
        var result = escaped
        let matches = detector.matches(in: escaped, range: NSRange(escaped.startIndex..., in: escaped))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result), let url = match.url else { continue }
            result.replaceSubrange(range, with: "<a href=\"\(HTMLText.escape(url.absoluteString))\">\(result[range])</a>")
        }
        return result
    }

    nonisolated static func document(_ body: String, style: Style) -> String {
        let scheme = style == .recolored ? "light" : "light dark"
        return """
        <!doctype html><html\(style == .recolored ? " data-sift-recolor" : "")><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="\(scheme)">
        <style>
        html, body { margin: 0; padding: 0; background: transparent; }
        /* Keep children's margins inside the body so its height can be measured. */
        body { display: flow-root; }
        body { font-family: -apple-system, system-ui, sans-serif; font-size: 16px; line-height: 1.45;
               overflow-wrap: anywhere; -webkit-text-size-adjust: 100%; }
        body > p:first-child { margin-top: 0; }
        body > p:last-child { margin-bottom: 0; }
        img { max-width: 100%; height: auto; }
        table { max-width: 100%; }
        blockquote { margin: 0 0 0 .4em; padding-left: .8em; border-left: 3px solid #c7c7cc; color: #6e6e73; }
        .plain { white-space: pre-wrap; }
        .quote { color: #8e8e93; }
        a { color: #1f6f7a; }
        \(style == .system ? "@media (prefers-color-scheme: dark) { body { color: #f2f2f7; } a { color: #6ac4cf; } blockquote { color: #aeaeb2; border-color: #48484a; } }" : "")
        </style></head><body>\(body)</body></html>
        """
    }
}

/// Compiles the content-blocker rule lists once per launch.
@MainActor
final class ContentRules {
    static let shared = ContentRules()
    private var trackers: WKContentRuleList?
    private var blockRemote: WKContentRuleList?

    func lists() async -> (trackers: WKContentRuleList?, blockRemote: WKContentRuleList?) {
        if trackers == nil {
            trackers = try? await WKContentRuleListStore.default()
                .compileContentRuleList(forIdentifier: "sift.trackers", encodedContentRuleList: ContentBlockerRules.trackersJSON())
        }
        if blockRemote == nil {
            blockRemote = try? await WKContentRuleListStore.default()
                .compileContentRuleList(forIdentifier: "sift.block-remote", encodedContentRuleList: ContentBlockerRules.blockRemoteJSON())
        }
        return (trackers, blockRemote)
    }
}

struct MessageWebView: View {
    @Environment(AppModel.self) private var model
    let html: String
    let allowRemote: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var height: CGFloat = 24
    @State private var rules: (trackers: WKContentRuleList?, blockRemote: WKContentRuleList?)?

    var body: some View {
        Group {
            if let rules, let engine = model.engine {
                // Keyed on the appearance so switching light/dark re-renders the colors.
                WebViewRepresentable(html: html, allowRemote: allowRemote, rules: rules, engine: engine, height: $height)
                    .frame(height: height)
                    .id(colorScheme)
            } else {
                Color.clear.frame(height: height)
            }
        }
        .task { rules = await ContentRules.shared.lists() }
    }
}

#if os(iOS)
typealias PlatformViewRepresentable = UIViewRepresentable
#else
typealias PlatformViewRepresentable = NSViewRepresentable
#endif

/// A message body sized to its content, so it never scrolls by itself: on the
/// Mac, trackpad and wheel scrolling go to the reader around it. (A plain
/// WKWebView swallows them, which leaves the reader stuck under the pointer.)
final class MessageBodyWebView: WKWebView {
    #if os(macOS)
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
    #endif
}

struct WebViewRepresentable: PlatformViewRepresentable {
    let html: String
    let allowRemote: Bool
    let rules: (trackers: WKContentRuleList?, blockRemote: WKContentRuleList?)
    let engine: SyncEngine
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    private func makeWebView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(BlobSchemeHandler(engine: engine), forURLScheme: BodyAssembler.blobScheme)
        let controller = configuration.userContentController
        controller.add(context.coordinator, contentWorld: .defaultClient, name: "size")
        controller.addUserScript(WKUserScript(source: Coordinator.measureScript, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: .defaultClient))
        let webView = MessageBodyWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        #else
        webView.setValue(false, forKey: "drawsBackground")
        #endif
        load(into: webView, coordinator: context.coordinator)
        return webView
    }

    private func load(into webView: WKWebView, coordinator: Coordinator) {
        let key = "\(allowRemote)|\(html.hashValue)"
        guard coordinator.loadedKey != key else { return }
        coordinator.loadedKey = key
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        if let trackers = rules.trackers { controller.add(trackers) }
        if !allowRemote, let blockRemote = rules.blockRemote { controller.add(blockRemote) }
        webView.loadHTMLString(html, baseURL: nil)
    }

    #if os(iOS)
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ webView: WKWebView, context: Context) { load(into: webView, coordinator: context.coordinator) }
    #else
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateNSView(_ webView: WKWebView, context: Context) { load(into: webView, coordinator: context.coordinator) }
    #endif

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        @Binding var height: CGFloat
        var loadedKey: String?

        init(height: Binding<CGFloat>) { _height = height }

        /// Runs in Sift's own script world (page scripts are disabled). In dark
        /// mode it recolors designed mail the way Mail does: light backgrounds
        /// go dark, dark text goes light, images stay as they are. Then it scales
        /// wide newsletters to fit and reports the content height.
        static let measureScript = """
            (function () {
              function rgba(value) {
                var m = /rgba?\\(([^)]+)\\)/.exec(value || '');
                if (!m) return null;
                var p = m[1].split(',').map(parseFloat);
                return { r: p[0] / 255, g: p[1] / 255, b: p[2] / 255, a: p.length > 3 ? p[3] : 1 };
              }
              function hsl(c) {
                var max = Math.max(c.r, c.g, c.b), min = Math.min(c.r, c.g, c.b), l = (max + min) / 2, h = 0, s = 0;
                if (max !== min) {
                  var d = max - min;
                  s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
                  h = max === c.r ? (c.g - c.b) / d + (c.g < c.b ? 6 : 0) : max === c.g ? (c.b - c.r) / d + 2 : (c.r - c.g) / d + 4;
                  h /= 6;
                }
                return { h: h, s: s, l: l, a: c.a };
              }
              function css(x) {
                return 'hsla(' + Math.round(x.h * 360) + ',' + Math.round(x.s * 100) + '%,' + Math.round(x.l * 100) + '%,' + x.a + ')';
              }
              function recolor() {
                var root = document.documentElement;
                if (!root.hasAttribute('data-sift-recolor') || !window.matchMedia('(prefers-color-scheme: dark)').matches) return;
                var elements = [root, document.body].concat(Array.prototype.slice.call(document.body.querySelectorAll('*')));
                // Read everything first, then write, so the page lays out once.
                var plan = elements.map(function (el) {
                  var cs = getComputedStyle(el);
                  return { el: el, bg: cs.backgroundImage === 'none' ? rgba(cs.backgroundColor) : null,
                           fg: rgba(cs.color), border: cs.borderTopStyle === 'none' ? null : rgba(cs.borderTopColor) };
                });
                plan.forEach(function (p) {
                  if (p.bg && p.bg.a > 0) {
                    var b = hsl(p.bg);
                    if (b.l > 0.5) { b.l = 0.11 + (1 - b.l) * 0.5; b.s *= 0.6; p.el.style.setProperty('background-color', css(b), 'important'); }
                  }
                  if (p.fg) {
                    var f = hsl(p.fg);
                    if (f.l < 0.55) { f.l = 0.93 - f.l * 0.45; p.el.style.setProperty('color', css(f), 'important'); }
                  }
                  if (p.border && p.border.a > 0) {
                    var o = hsl(p.border);
                    if (o.l > 0.6) { o.l = 0.18 + (1 - o.l) * 0.4; p.el.style.setProperty('border-color', css(o), 'important'); }
                  }
                });
                root.style.setProperty('background-color', 'transparent', 'important');
                document.body.style.setProperty('background-color', 'transparent', 'important');
              }
              recolor();
              // Safety net, for every message in dark mode: text that ends up too close
              // to what's behind it (a sender's dark-mode styles that miss a heading,
              // or a color the recolor couldn't see) is lightened until it reads.
              function luminance(c) {
                function ch(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }
                return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
              }
              function contrast(a, b) {
                var x = luminance(a), y = luminance(b);
                return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
              }
              function fixContrast() {
                if (!window.matchMedia('(prefers-color-scheme: dark)').matches) return;
                // The reader panel behind the transparent page.
                var panel = { r: 0.11, g: 0.11, b: 0.12, a: 1 };
                var cache = new Map();
                function backdrop(el) {
                  if (!el || el.nodeType !== 1) return panel;
                  if (cache.has(el)) return cache.get(el);
                  var cs = getComputedStyle(el), result;
                  if (cs.backgroundImage !== 'none') result = null;  // over an image: can't tell
                  else {
                    var c = rgba(cs.backgroundColor);
                    result = c && c.a > 0.5 ? c : backdrop(el.parentElement);
                  }
                  cache.set(el, result);
                  return result;
                }
                var fixes = [];
                document.body.querySelectorAll('*').forEach(function (el) {
                  var hasText = false;
                  for (var n = el.firstChild; n; n = n.nextSibling) {
                    if (n.nodeType === 3 && n.nodeValue.trim()) { hasText = true; break; }
                  }
                  if (!hasText) return;
                  var fg = rgba(getComputedStyle(el).color), bg = backdrop(el);
                  if (!fg || !bg || fg.a < 0.3 || contrast(fg, bg) >= 3) return;
                  var f = hsl(fg);
                  f.l = luminance(bg) < 0.2 ? Math.max(0.82, 1 - f.l * 0.3) : Math.min(0.25, f.l * 0.4);
                  fixes.push([el, css(f)]);
                });
                fixes.forEach(function (fix) { fix[0].style.setProperty('color', fix[1], 'important'); });
              }
              fixContrast();
              function fit() {
                var body = document.body; if (!body) return;
                body.style.zoom = 1;
                var width = document.documentElement.scrollWidth, viewport = window.innerWidth;
                if (width > viewport + 4) body.style.zoom = viewport / width;
                // The body's own box, not scrollHeight, which never drops below the viewport.
                var style = getComputedStyle(body);
                var height = body.getBoundingClientRect().height + parseFloat(style.marginTop) + parseFloat(style.marginBottom);
                window.webkit.messageHandlers.size.postMessage(Math.ceil(height) + 2);
              }
              fit();
              window.addEventListener('load', fit);
              document.addEventListener('load', function (e) { if (e.target.tagName === 'IMG') fit(); }, true);
              setTimeout(fit, 400);
            })();
            """

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let value = message.body as? Double, value > 0, abs(value - height) > 1 {
                height = value
            } else if let value = message.body as? Int, value > 0, abs(CGFloat(value) - height) > 1 {
                height = CGFloat(value)
            }
        }

        /// The message itself is the only page this view ever shows; links open
        /// in the browser, and nothing (forms, redirects) navigates in place.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            if url.scheme == "about" { return .allow }
            if action.navigationType == .linkActivated, ["http", "https", "mailto", "tel"].contains(url.scheme?.lowercased()) {
                #if os(iOS)
                await UIApplication.shared.open(url)
                #else
                NSWorkspace.shared.open(url)
                #endif
            }
            return .cancel
        }
    }
}

/// Serves inline (`cid:`) images from Fastmail blobs.
final class BlobSchemeHandler: NSObject, WKURLSchemeHandler {
    private let engine: SyncEngine
    private var stopped: Set<ObjectIdentifier> = []

    init(engine: SyncEngine) { self.engine = engine }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let blobId = String(url.path().dropFirst())
        let type = components?.queryItems?.first { $0.name == "type" }?.value ?? "application/octet-stream"
        let name = components?.queryItems?.first { $0.name == "name" }?.value ?? "inline"
        let id = ObjectIdentifier(task)
        Task {
            do {
                let data = try await engine.download(blobId: blobId, name: name, type: type)
                guard !stopped.contains(id) else { return }
                task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
                task.didReceive(data)
                task.didFinish()
            } catch {
                guard !stopped.contains(id) else { return }
                task.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }
}
