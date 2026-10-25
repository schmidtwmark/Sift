import Foundation

/// A known email-tracking service, matched by host and/or path substrings
/// (lowercased). Rules are deliberately simple so the same list can compile to a
/// WebKit content-blocker, which only supports a small regex dialect.
public struct TrackerRule: Sendable, Hashable {
    public var name: String
    public var host: String?
    public var path: String?

    init(_ name: String, host: String? = nil, path: String? = nil) {
        self.name = name
        self.host = host
        self.path = path
    }

    func matches(host urlHost: String, pathAndQuery: String) -> Bool {
        if let host, !urlHost.contains(host) { return false }
        if let path, !pathAndQuery.contains(path) { return false }
        return host != nil || path != nil
    }
}

/// Curated from public descriptions of how each service tracks opens. Anything
/// not listed is still caught by `TrackerDetector`'s pixel heuristics.
public enum TrackerList {
    public static let rules: [TrackerRule] = [
        .init("Mailchimp", host: "list-manage.com", path: "/track/open"),
        .init("Mailchimp", host: "mailchimp.com", path: "/track/open"),
        .init("Mandrill", host: "mandrillapp.com", path: "/track/open"),
        .init("SendGrid", path: "/wf/open?"),
        .init("SendGrid", host: "sendgrid.net", path: "/mpss/o"),
        .init("SendGrid", host: "sendgrid.net", path: "/trk"),
        .init("HubSpot", host: "track.hubspot.com"),
        .init("HubSpot", host: "t.hubspotemail.net"),
        .init("HubSpot", host: "t.hubspotfree.net"),
        .init("HubSpot", host: "t.hubspotstarter.net"),
        .init("HubSpot", host: "sidekickopen"),
        .init("HubSpot", host: "t.signaux"),
        .init("HubSpot", host: "t.senal"),
        .init("HubSpot", host: "t.strk"),
        .init("Salesforce Marketing Cloud", host: "exct.net", path: "/open.aspx"),
        .init("Salesforce Marketing Cloud", path: "/open.aspx?"),
        .init("Pardot", host: "pi.pardot.com"),
        .init("Marketo", path: "/trk?t="),
        .init("Oracle Eloqua", path: "/e/footerimages/footerimage"),
        .init("Oracle Eloqua", host: "en25.com", path: "/e/"),
        .init("Oracle Responsys", path: "/pub/as?_ri_="),
        .init("Campaign Monitor", host: "createsend", path: "/t/"),
        .init("Campaign Monitor", host: "cmail19.com", path: "/t/"),
        .init("Campaign Monitor", host: "cmail20.com", path: "/t/"),
        .init("Constant Contact", host: "rs6.net", path: "/on.jsp"),
        .init("Postmark", host: "pstmrk.it", path: "/open"),
        .init("Amazon SES", host: "awstrack.me", path: "/i0/"),
        .init("SparkPost", host: "spgo.io", path: "/q/"),
        .init("SparkPost", host: "sparkpostmail.com", path: "/q/"),
        .init("Klaviyo", host: "trk.klaviyomail.com"),
        .init("Klaviyo", host: "trk.klaviyo.com"),
        .init("Iterable", path: "/e/eo?"),
        .init("Customer.io", path: "/e/o/"),
        .init("Intercom", host: "via.intercom.io", path: "/o"),
        .init("Intercom", host: "intercom-mail.com", path: "/via/o"),
        .init("beehiiv", path: "/ss/o/"),
        .init("Substack", host: "substack.com", path: "/o/"),
        .init("Kit", host: "open.convertkit-mail"),
        .init("Kit", host: "open.kit-mail"),
        .init("Brevo", path: "/tr/op/"),
        .init("MailerLite", host: "mlsend.com"),
        .init("ActiveCampaign", path: "/lt.php?"),
        .init("Mailjet", host: "mjt.lu", path: "/oo/"),
        .init("AWeber", host: "openrate.aweber.com"),
        .init("Benchmark", host: "bmetrack.com"),
        .init("Sailthru", host: "sailthru.com", path: "/trk"),
        .init("Mailtrack", host: "mailtrack.io", path: "/trace"),
        .init("Yesware", host: "t.yesware.com"),
        .init("Yesware", host: "app.yesware.com", path: "/t/"),
        .init("Streak", host: "mailfoogae.appspot.com"),
        .init("Superhuman", host: "r.superhuman.com"),
        .init("Mixmax", host: "track.mixmax.com"),
        .init("Bananatag", host: "bl-1.com"),
        .init("Bananatag", host: "bananatag.com"),
        .init("ContactMonkey", host: "contactmonkey.com", path: "/tracker"),
        .init("Cirrus Insight", host: "tracking.cirrusinsight.com"),
        .init("Boomerang", host: "mailstat.us", path: "/tr"),
        .init("Litmus", host: "emltrk.com"),
        .init("Google Analytics", host: "google-analytics.com", path: "/collect"),
        .init("LinkedIn", host: "linkedin.com", path: "/emimp/"),
        .init("X (Twitter)", path: "/scribe/ibis"),
        .init("Facebook", host: "facebook.com", path: "email_open_log_pic"),
        .init("Medium", host: "medium.com", path: "/_/stat"),
        .init("Quora", host: "quora.com", path: "/qemail/mark_read"),
    ]

    /// Paths that strongly suggest a tracking beacon when the image is also tiny
    /// or has no declared size.
    public static let suspiciousPaths = [
        "/open?", "/open.gif", "/open.php", "/track/open", "/tracking/open", "/opened",
        "/pixel.gif", "/pixel.png", "/pixel?", "/beacon", "/1x1.gif", "/1x1.png", "/t.gif", "/o.gif",
    ]

    public static func match(_ url: URL) -> TrackerRule? {
        guard let host = url.host()?.lowercased() else { return nil }
        let pathAndQuery = (url.path(percentEncoded: true) + (url.query(percentEncoded: true).map { "?" + $0 } ?? "")).lowercased()
        if let rule = rules.first(where: { $0.matches(host: host, pathAndQuery: pathAndQuery) }) {
            return rule
        }
        // Mailgun's open tracking lives on the sender's own `email.` subdomain.
        if host.hasPrefix("email."), pathAndQuery.hasPrefix("/o/") {
            return TrackerRule("Mailgun", host: host, path: "/o/")
        }
        return nil
    }
}
