import AppKit
import Foundation
import WebKit

/// One interactive element on the agent's browser page, with a stable id ("e12") within that page.
struct BrowserElement: Codable, Equatable {
    var id: String
    var tag: String
    var type: String = ""
    var label: String = ""
    var href: String = ""
    /// For buttons and inputs inside a form: where the form submits.
    var formAction: String = ""
    var isSubmit = false
    var isPassword = false
    var isPayment = false
    /// The element's form also contains a password or payment field.
    var formHasSensitiveField = false
}

struct BrowserSnapshot: Codable, Equatable {
    var url: String
    var title: String
    var text: String
    var elements: [BrowserElement]
}

/// The agent's own browser (mocked in tests).
@MainActor
protocol BrowserDriving: AnyObject {
    var currentURL: URL? { get }
    func open(_ url: URL) async throws
    func read() async throws -> BrowserSnapshot
    func element(_ id: String) async throws -> BrowserElement?
    func click(_ id: String) async throws
    func type(_ id: String, text: String) async throws
    func select(_ id: String, value: String) async throws
    func scroll(_ direction: String) async throws
    func waitFor(selector: String, timeout: TimeInterval) async throws -> Bool
    func screenshot() async throws -> Data
}

enum BrowserError: LocalizedError, Equatable {
    case notOpen, noElement(String), loadFailed(String), timeout

    var errorDescription: String? {
        switch self {
        case .notOpen: return "Open a page first (browser action \"open\")."
        case .noElement(let id): return "No element \(id) on this page. Use \"read\" to list the elements."
        case .loadFailed(let reason): return "The page didn't load: \(reason)"
        case .timeout: return "Timed out waiting for the page."
        }
    }
}

/// Browser rules, decided outside the model.
enum BrowserPolicy {
    static let readOnlyActions: Set<String> = ["open", "read", "scroll", "wait_for", "screenshot"]
    static let allActions: Set<String> = readOnlyActions.union(["click", "type", "select"])

    /// "example.com" allows example.com and its subdomains.
    static func isAllowed(host: String?, allowlist: [String]) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return allowlist.map { $0.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "*.", with: "") }
            .filter { !$0.isEmpty }
            .contains { host == $0 || host.hasSuffix("." + $0) }
    }

    struct Assessment: Equatable {
        var risk: AgentRisk
        var reason: String
        var denied: String?
    }

    /// Risk for one browser action. Unknown domains, external form submits and anything touching
    /// a password or payment field always need an exact approval.
    static func assess(action: String, target: URL?, element: BrowserElement?, pageURL: URL?, allowlist: [String], readOnly: Bool) -> Assessment {
        guard allActions.contains(action) else { return Assessment(risk: .high, reason: "", denied: "Unknown browser action “\(action)”.") }
        if readOnly, !readOnlyActions.contains(action) {
            return Assessment(risk: .high, reason: "", denied: "Scheduled jobs use the browser read-only: \(action) isn't allowed.")
        }
        if action == "open" {
            guard let target, ["http", "https"].contains(target.scheme?.lowercased() ?? "") else {
                return Assessment(risk: .high, reason: "", denied: "Only http(s) pages can be opened.")
            }
            if readOnly, !isAllowed(host: target.host, allowlist: allowlist) {
                return Assessment(risk: .high, reason: "", denied: "\(target.host ?? "") isn't on the browser allowlist, and scheduled jobs can't ask for approval.")
            }
            return isAllowed(host: target.host, allowlist: allowlist)
                ? Assessment(risk: .low, reason: "Open \(target.absoluteString)")
                : Assessment(risk: .high, reason: "Open \(target.absoluteString) — \(target.host ?? "") isn't on the browser allowlist")
        }
        let pageHost = pageURL?.host?.lowercased()
        let onAllowed = isAllowed(host: pageHost, allowlist: allowlist)
        switch action {
        case "click", "type", "select":
            guard let element else { return Assessment(risk: .medium, reason: "\(action) on a missing element") }
            if element.isPassword || element.isPayment {
                return Assessment(risk: .high, reason: "\(action.capitalized) \(element.isPassword ? "a password" : "a payment") field (“\(element.label)”) on \(pageHost ?? "")")
            }
            if action == "click" {
                if element.isSubmit {
                    let formHost = URL(string: element.formAction)?.host?.lowercased() ?? pageHost
                    if element.formHasSensitiveField {
                        return Assessment(risk: .high, reason: "Submit a form with a password or payment field (“\(element.label)”) on \(pageHost ?? "")")
                    }
                    if formHost != pageHost || !onAllowed || !isAllowed(host: formHost, allowlist: allowlist) {
                        return Assessment(risk: .high, reason: "Submit a form (“\(element.label)”) to \(formHost ?? "another site")")
                    }
                    return Assessment(risk: .high, reason: "Submit a form (“\(element.label)”) on \(pageHost ?? "")")
                }
                if !element.href.isEmpty, let link = URL(string: element.href, relativeTo: pageURL)?.absoluteURL,
                   !isAllowed(host: link.host, allowlist: allowlist) {
                    return Assessment(risk: .high, reason: "Follow a link to \(link.host ?? "another site") (not on the allowlist)")
                }
            }
            return onAllowed ? Assessment(risk: .medium, reason: "\(action.capitalized) “\(element.label.isEmpty ? element.id : element.label)” on \(pageHost ?? "")")
                             : Assessment(risk: .high, reason: "\(action.capitalized) on \(pageHost ?? "a page") (not on the allowlist)")
        default:
            return Assessment(risk: .low, reason: "\(action.capitalized) the page")
        }
    }
}

/// WKWebView in its own non-persistent data store: no cookies, logins or history from Safari or Chrome,
/// and nothing kept after MacPilot quits. Never autofills credentials.
@MainActor
final class AgentBrowser: NSObject, BrowserDriving, WKNavigationDelegate {
    static let shared = AgentBrowser()

    private var webView: WKWebView?
    private var window: NSWindow?
    private var loadContinuation: CheckedContinuation<Void, Error>?
    var currentURL: URL? { webView?.url }

    private func view() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.applicationNameForUserAgent = "MacPilot/0.25"
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: configuration)
        webView.navigationDelegate = self
        // Off-screen window so layout, timers and snapshots work like a real tab.
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 1280, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.sharingType = .none
        window.orderBack(nil)
        self.window = window
        self.webView = webView
        return webView
    }

    func open(_ url: URL) async throws {
        let webView = view()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadContinuation?.resume(throwing: CancellationError())
            loadContinuation = continuation
            webView.load(URLRequest(url: url, timeoutInterval: 30))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: BrowserError.loadFailed(error.localizedDescription))
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: BrowserError.loadFailed(error.localizedDescription))
        loadContinuation = nil
    }

    private func js(_ source: String) async throws -> Any? {
        guard let webView else { throw BrowserError.notOpen }
        return try await webView.evaluateJavaScript(source)
    }

    /// Tags interactive elements with data-macpilot-id (kept across reads of the same page).
    static let indexScript = """
    (function(){
      var n = window.__mpNext || 1; var out = [];
      var nodes = document.querySelectorAll('a[href],button,input,select,textarea,[role=button],[onclick],summary');
      function label(e){ return (e.getAttribute('aria-label')||e.innerText||e.value||e.placeholder||e.name||e.title||'').trim().slice(0,80); }
      function payment(e){ var s=((e.autocomplete||'')+' '+(e.name||'')+' '+(e.id||'')).toLowerCase(); return /cc-|card|cvv|cvc|iban|expir|security.?code/.test(s); }
      for (var i=0;i<nodes.length && out.length<300;i++){
        var e=nodes[i]; var r=e.getBoundingClientRect(); if (r.width===0 && r.height===0) continue;
        if (!e.dataset.macpilotId) { e.dataset.macpilotId='e'+(n++); }
        var f=e.form||e.closest('form'); var sensitive=false;
        if (f){ var inputs=f.querySelectorAll('input'); for (var j=0;j<inputs.length;j++){ if (inputs[j].type==='password'||payment(inputs[j])) sensitive=true; } }
        var tag=e.tagName.toLowerCase(); var type=(e.type||'').toLowerCase();
        out.push({id:e.dataset.macpilotId, tag:tag, type:type, label:label(e), href:e.href||'',
          formAction: f ? (f.action||location.href) : '', isSubmit: (tag==='button' && (type===''||type==='submit') && !!f) || (tag==='input' && (type==='submit'||type==='image')),
          isPassword: type==='password', isPayment: (tag==='input'||tag==='select') && payment(e), formHasSensitiveField: sensitive});
      }
      window.__mpNext=n; return JSON.stringify(out);
    })()
    """

    func read() async throws -> BrowserSnapshot {
        guard let webView else { throw BrowserError.notOpen }
        let json = try await js(Self.indexScript) as? String ?? "[]"
        let elements = (try? JSONDecoder().decode([BrowserElement].self, from: Data(json.utf8))) ?? []
        let text = try await js("document.body ? document.body.innerText.slice(0, 30000) : ''") as? String ?? ""
        return BrowserSnapshot(url: webView.url?.absoluteString ?? "", title: webView.title ?? "", text: text, elements: elements)
    }

    func element(_ id: String) async throws -> BrowserElement? {
        let json = try await js(Self.indexScript) as? String ?? "[]"
        return ((try? JSONDecoder().decode([BrowserElement].self, from: Data(json.utf8))) ?? []).first { $0.id == id }
    }

    private func quoted(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    private func onElement(_ id: String, _ body: String) async throws {
        let ok = try await js("(function(){var e=document.querySelector('[data-macpilot-id=' + \(quoted(id)) + ']'); if(!e) return false; \(body); return true;})()") as? Bool ?? false
        if !ok { throw BrowserError.noElement(id) }
    }

    func click(_ id: String) async throws {
        try await onElement(id, "e.scrollIntoView({block:'center'}); e.click()")
        try? await Task.sleep(for: .milliseconds(600))
    }

    func type(_ id: String, text: String) async throws {
        try await onElement(id, "e.focus(); e.value = \(quoted(text)); e.dispatchEvent(new Event('input',{bubbles:true})); e.dispatchEvent(new Event('change',{bubbles:true}))")
    }

    func select(_ id: String, value: String) async throws {
        try await onElement(id, "e.value = \(quoted(value)); e.dispatchEvent(new Event('change',{bubbles:true}))")
    }

    func scroll(_ direction: String) async throws {
        let amount = direction == "up" ? "-window.innerHeight*0.9" : direction == "top" ? "-1e9" : direction == "bottom" ? "1e9" : "window.innerHeight*0.9"
        _ = try await js("window.scrollBy(0, \(amount)); true")
    }

    func waitFor(selector: String, timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(min(30, max(0.5, timeout)))
        while Date() < deadline {
            if try await js("!!document.querySelector(\(quoted(selector)))") as? Bool == true { return true }
            try await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    func screenshot() async throws -> Data {
        guard let webView else { throw BrowserError.notOpen }
        let image = try await webView.takeSnapshot(configuration: nil)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { throw ScreenshotError.encodeFailed }
        return jpeg
    }
}
