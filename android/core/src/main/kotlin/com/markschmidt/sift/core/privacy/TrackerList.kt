package com.markschmidt.sift.core.privacy

/**
 * A known email-tracking service, matched by host and/or path substrings
 * (lowercased). Same list as SiftKit's `TrackerList.swift`.
 */
data class TrackerRule(val name: String, val host: String? = null, val path: String? = null) {
    fun matches(urlHost: String, pathAndQuery: String): Boolean {
        if (host != null && !urlHost.contains(host)) return false
        if (path != null && !pathAndQuery.contains(path)) return false
        return host != null || path != null
    }
}

/**
 * Curated from public descriptions of how each service tracks opens. Anything
 * not listed is still caught by [TrackerDetector]'s pixel heuristics.
 */
object TrackerList {
    val rules: List<TrackerRule> = listOf(
        TrackerRule("Mailchimp", host = "list-manage.com", path = "/track/open"),
        TrackerRule("Mailchimp", host = "mailchimp.com", path = "/track/open"),
        TrackerRule("Mandrill", host = "mandrillapp.com", path = "/track/open"),
        TrackerRule("SendGrid", path = "/wf/open?"),
        TrackerRule("SendGrid", host = "sendgrid.net", path = "/mpss/o"),
        TrackerRule("SendGrid", host = "sendgrid.net", path = "/trk"),
        TrackerRule("HubSpot", host = "track.hubspot.com"),
        TrackerRule("HubSpot", host = "t.hubspotemail.net"),
        TrackerRule("HubSpot", host = "t.hubspotfree.net"),
        TrackerRule("HubSpot", host = "t.hubspotstarter.net"),
        TrackerRule("HubSpot", host = "sidekickopen"),
        TrackerRule("HubSpot", host = "t.signaux"),
        TrackerRule("HubSpot", host = "t.senal"),
        TrackerRule("HubSpot", host = "t.strk"),
        TrackerRule("Salesforce Marketing Cloud", host = "exct.net", path = "/open.aspx"),
        TrackerRule("Salesforce Marketing Cloud", path = "/open.aspx?"),
        TrackerRule("Pardot", host = "pi.pardot.com"),
        TrackerRule("Marketo", path = "/trk?t="),
        TrackerRule("Oracle Eloqua", path = "/e/footerimages/footerimage"),
        TrackerRule("Oracle Eloqua", host = "en25.com", path = "/e/"),
        TrackerRule("Oracle Responsys", path = "/pub/as?_ri_="),
        TrackerRule("Campaign Monitor", host = "createsend", path = "/t/"),
        TrackerRule("Campaign Monitor", host = "cmail19.com", path = "/t/"),
        TrackerRule("Campaign Monitor", host = "cmail20.com", path = "/t/"),
        TrackerRule("Constant Contact", host = "rs6.net", path = "/on.jsp"),
        TrackerRule("Postmark", host = "pstmrk.it", path = "/open"),
        TrackerRule("Amazon SES", host = "awstrack.me", path = "/i0/"),
        TrackerRule("SparkPost", host = "spgo.io", path = "/q/"),
        TrackerRule("SparkPost", host = "sparkpostmail.com", path = "/q/"),
        TrackerRule("Klaviyo", host = "trk.klaviyomail.com"),
        TrackerRule("Klaviyo", host = "trk.klaviyo.com"),
        TrackerRule("Iterable", path = "/e/eo?"),
        TrackerRule("Customer.io", path = "/e/o/"),
        TrackerRule("Intercom", host = "via.intercom.io", path = "/o"),
        TrackerRule("Intercom", host = "intercom-mail.com", path = "/via/o"),
        TrackerRule("beehiiv", path = "/ss/o/"),
        TrackerRule("Substack", host = "substack.com", path = "/o/"),
        TrackerRule("Kit", host = "open.convertkit-mail"),
        TrackerRule("Kit", host = "open.kit-mail"),
        TrackerRule("Brevo", path = "/tr/op/"),
        TrackerRule("MailerLite", host = "mlsend.com"),
        TrackerRule("ActiveCampaign", path = "/lt.php?"),
        TrackerRule("Mailjet", host = "mjt.lu", path = "/oo/"),
        TrackerRule("AWeber", host = "openrate.aweber.com"),
        TrackerRule("Benchmark", host = "bmetrack.com"),
        TrackerRule("Sailthru", host = "sailthru.com", path = "/trk"),
        TrackerRule("Mailtrack", host = "mailtrack.io", path = "/trace"),
        TrackerRule("Yesware", host = "t.yesware.com"),
        TrackerRule("Yesware", host = "app.yesware.com", path = "/t/"),
        TrackerRule("Streak", host = "mailfoogae.appspot.com"),
        TrackerRule("Superhuman", host = "r.superhuman.com"),
        TrackerRule("Mixmax", host = "track.mixmax.com"),
        TrackerRule("Bananatag", host = "bl-1.com"),
        TrackerRule("Bananatag", host = "bananatag.com"),
        TrackerRule("ContactMonkey", host = "contactmonkey.com", path = "/tracker"),
        TrackerRule("Cirrus Insight", host = "tracking.cirrusinsight.com"),
        TrackerRule("Boomerang", host = "mailstat.us", path = "/tr"),
        TrackerRule("Litmus", host = "emltrk.com"),
        TrackerRule("Google Analytics", host = "google-analytics.com", path = "/collect"),
        TrackerRule("LinkedIn", host = "linkedin.com", path = "/emimp/"),
        TrackerRule("X (Twitter)", path = "/scribe/ibis"),
        TrackerRule("Facebook", host = "facebook.com", path = "email_open_log_pic"),
        TrackerRule("Medium", host = "medium.com", path = "/_/stat"),
        TrackerRule("Quora", host = "quora.com", path = "/qemail/mark_read"),
    )

    /** Paths that strongly suggest a tracking beacon when the image has no declared size. */
    val suspiciousPaths = listOf(
        "/open?", "/open.gif", "/open.php", "/track/open", "/tracking/open", "/opened", "/pixel.gif", "/pixel.png", "/pixel?", "/beacon", "/1x1.gif", "/1x1.png", "/t.gif", "/o.gif",
    )

    fun match(url: UrlParts): TrackerRule? {
        val host = url.host.lowercase()
        val pathAndQuery = url.pathAndQuery.lowercase()
        rules.firstOrNull { it.matches(host, pathAndQuery) }?.let { return it }
        // Mailgun's open tracking lives on the sender's own `email.` subdomain.
        if (host.startsWith("email.") && pathAndQuery.startsWith("/o/")) return TrackerRule("Mailgun", host, "/o/")
        return null
    }
}
