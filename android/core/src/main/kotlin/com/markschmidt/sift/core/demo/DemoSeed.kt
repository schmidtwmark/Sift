package com.markschmidt.sift.core.demo

import java.time.Duration
import java.time.Instant

/**
 * Sample mail for demo mode: a few weeks of history (grandfathered past the
 * Screener) plus recent arrivals from new senders that land in the Screener.
 * The same mailbox the iPhone and Mac apps show with `-demo`.
 */
object DemoSeed {
    /** Demo mode turns the Screener on this long ago, so recent mail gets screened. */
    val activationAge: Duration = Duration.ofDays(3)

    fun populate(server: DemoServer) {
        val mailboxes = listOf(
            Triple("inbox", "Inbox", "inbox") to 1, Triple("archive", "Archive", "archive") to 2,
            Triple("drafts", "Drafts", "drafts") to 3, Triple("sent", "Sent", "sent") to 4,
            Triple("junk", "Spam", "junk") to 6, Triple("trash", "Trash", "trash") to 7,
            Triple("receipts", "Receipts", null) to 10, Triple("newsletters", "Newsletters", null) to 11,
            Triple("travel", "Travel", null) to 12, Triple("family", "Family", null) to 13,
            Triple("hey-import", "Hey Import", null) to 14,
        )
        for ((box, order) in mailboxes) server.addMailbox(box.first, box.second, box.third, order)
        server.addContact("Alex Rivera", "alex@rivera.example")
        server.addContact("Mom", "mom@family.example")

        val now = Instant.now()
        fun ago(days: Double, hours: Double = 0.0): Instant = now.minusMillis(((days * 86_400 + hours * 3600) * 1000).toLong())

        // History (before the Screener was switched on).
        server.deliver("Alex Rivera" to "alex@rivera.example", "Climbing on Saturday?",
            "Gym opens at 9. I can bring the spare harness if you want to try lead.",
            receivedAt = ago(12.0), keywords = listOf("\$seen"), threadId = "T-climb")
        server.deliver("You" to "you@fastmail.com", "Re: Climbing on Saturday?",
            "Yes! 9:30 works. Bring the harness.", mailbox = "sent",
            receivedAt = ago(11.8), keywords = listOf("\$seen"), threadId = "T-climb", to = "alex@rivera.example")
        server.deliver("Mom" to "mom@family.example", "Thanksgiving plans",
            "Are you all coming Wednesday night or Thursday morning? Let me know about the kids' beds.",
            mailbox = "family", receivedAt = ago(9.0), keywords = listOf("\$seen"), threadId = "T-thanks")
        server.deliver("Brightside Bank" to "alerts@brightside.example", "Your statement is ready",
            "Your October statement for the account ending 4410 is ready to view.",
            mailbox = "receipts", receivedAt = ago(8.0), keywords = listOf("\$seen"))
        server.deliver("Northwind Outfitters" to "orders@northwind.example", "Order NW-20931 confirmed",
            "Thanks for your order! Trail runner shoes (men's 10.5), qty 1 — \$129.00.",
            html = receiptHtml("NW-20931", "Trail runner shoes", "\$129.00"),
            mailbox = "receipts", receivedAt = ago(6.0), keywords = listOf("\$seen"))
        server.deliver("Field Notes Digest" to "digest@fieldnotes.example", "Issue 88: The quiet internet",
            "This week: small web, slow software, and why your inbox should be boring.",
            html = newsletterHtml("The quiet internet", null),
            mailbox = "newsletters", receivedAt = ago(5.0), keywords = listOf("\$seen"))
        server.deliver("Alex Rivera" to "alex@rivera.example", "Photos from the crag",
            "Dumped everything into the shared album. The one of you on the arete is great.",
            mailbox = "archive", receivedAt = ago(4.0), keywords = listOf("\$seen"))

        // An unsorted import from HEY: years of mail in one folder.
        val imported = listOf(
            listOf("Field Notes Digest", "digest@fieldnotes.example", "Issue 41: Paper over pixels", "420"),
            listOf("Field Notes Digest", "digest@fieldnotes.example", "Issue 52: The long now", "340"),
            listOf("Field Notes Digest", "digest@fieldnotes.example", "Issue 60: Slow mornings", "280"),
            listOf("Brightside Bank", "alerts@brightside.example", "Your 2024 tax documents", "600"),
            listOf("Brightside Bank", "alerts@brightside.example", "Your statement is ready", "390"),
            listOf("Alex Rivera", "alex@rivera.example", "Moving day help?", "700"),
            listOf("Harbor Yoga", "studio@harboryoga.example", "Your class pass expires soon", "500"),
            listOf("Old Landlord", "rentals@oaktree.example", "Lease renewal", "800"),
        )
        for ((name, email, subject, daysAgo) in imported) {
            server.deliver(name to email, subject, "Imported from HEY.", mailbox = "hey-import",
                receivedAt = ago(daysAgo.toDouble()), keywords = listOf("\$seen"), to = "you@hey.example")
        }
        for ((subject, daysAgo) in listOf("Re: Moving day help?" to 699.0, "Lease question" to 805.0)) {
            server.deliver("You" to "you@hey.example", subject, "Sent from HEY.", mailbox = "hey-import",
                receivedAt = ago(daysAgo), keywords = listOf("\$seen"), to = "alex@rivera.example")
        }

        // Arrivals after the Screener was switched on.
        server.deliver("Paperline Weekly" to "hello@paperline.example", "Five tools we can't stop using",
            "Plus: the notebook that changed how we plan our week.",
            html = newsletterHtml("Five tools we can't stop using", "https://paperline.us5.list-manage.com/track/open.php?u=8f2a&id=91c"),
            receivedAt = ago(2.0, hours = 3.0))
        server.deliver("Kai at Lumen Labs" to "kai@lumenlabs.example", "Quick question about your team",
            "Hi there — I noticed your team is growing and wondered if you'd have 15 minutes this week to chat about Lumen.",
            html = """
                <p>Hi there,</p><p>I noticed your team is growing and wondered if you'd have 15 minutes this week to chat about how Lumen helps teams ship faster.</p><p>Best,<br>Kai</p>
                <img src="https://t.sidekickopen87.com/Ctc/5D+113/c3Lh-04/open" width="1" height="1" style="display:block">
            """.trimIndent(),
            receivedAt = ago(1.0, hours = 20.0))
        server.deliver("Fjord Air" to "bookings@fjordair.example", "Your trip to Bergen: booking FJ7Q2K",
            "Booking FJ7Q2K is confirmed. Departs Thursday 07:40, seat 14A. Check in opens 24 hours before departure.",
            html = TRIP_HTML, receivedAt = ago(1.0, hours = 6.0))
        server.deliver("Alex Rivera" to "alex@rivera.example", "Re: Climbing on Saturday?",
            "Same time this week? Bring chalk, mine's out.", receivedAt = ago(0.0, hours = 9.0), threadId = "T-climb")
        server.deliver("Coastal Dental" to "reminders@coastaldental.example", "Appointment reminder: Tue 3:30 PM",
            "This is a reminder of your cleaning appointment on Tuesday at 3:30 PM. Reply C to confirm.",
            html = """
                <p>This is a reminder of your cleaning appointment on <b>Tuesday at 3:30 PM</b>.</p>
                <p>Reply C to confirm.</p><img src="https://email.coastaldental.example/o/eJxVjcEOgiAQRP-Gq0EQwYOH" alt="">
            """.trimIndent(),
            receivedAt = ago(0.0, hours = 4.0))
        server.deliver("Northwind Outfitters" to "orders@northwind.example", "Your order has shipped",
            "Order NW-20931 is on its way. Tracking: 1Z 999 AA1 01 2345 6784.",
            html = receiptHtml("NW-20931", "Trail runner shoes — shipped", "\$129.00"),
            receivedAt = ago(0.0, hours = 2.0))
        server.deliver("Mom" to "mom@family.example", "Re: Thanksgiving plans",
            "Great, Wednesday it is. I'll make up the bunk beds.", receivedAt = ago(0.0, hours = 1.0), threadId = "T-thanks")
    }

    fun newsletterHtml(title: String, pixel: String?): String = """
        <div style="font-family: Georgia, serif; max-width: 560px; margin: 0 auto;">
          <h1 style="font-size: 26px; margin-bottom: 4px;">$title</h1>
          <p style="color: #666; margin-top: 0;">A weekly letter about tools, craft, and calm.</p>
          <hr style="border: none; border-top: 1px solid #ddd;">
          <h2 style="font-size: 18px;">1. A notebook that stays open</h2>
          <p>Lay-flat binding sounds like a small thing until you've fought a spiral for a year.</p>
          <h2 style="font-size: 18px;">2. The two-list method</h2>
          <p>One list for today, one for someday. Nothing else gets a list.</p>
          <p><a href="https://example.com/read">Read the full issue</a></p>
          ${pixel?.let { "<img src=\"$it\" width=\"1\" height=\"1\" alt=\"\">" } ?: ""}
        </div>
    """.trimIndent()

    fun receiptHtml(order: String, item: String, price: String): String = """
        <table style="font-family: -apple-system, sans-serif; width: 100%; max-width: 520px; border-collapse: collapse;">
          <tr><td style="font-size: 20px; font-weight: 600; padding-bottom: 12px;">Order $order</td></tr>
          <tr><td style="padding: 8px 0; border-top: 1px solid #eee;">$item</td><td style="text-align: right;">$price</td></tr>
          <tr><td style="padding: 8px 0; border-top: 1px solid #eee; font-weight: 600;">Total</td><td style="text-align: right; font-weight: 600;">$price</td></tr>
        </table>
        <img src="https://u1234.ct.sendgrid.net/wf/open?upn=abc123" alt="" width="1" height="1" border="0">
    """.trimIndent()

    const val TRIP_HTML = """
        <div style="font-family: -apple-system, sans-serif;">
          <p style="font-size: 13px; color: #888; text-transform: uppercase; letter-spacing: .08em;">Booking FJ7Q2K</p>
          <h1 style="font-size: 24px;">Oslo → Bergen</h1>
          <p><b>Thursday</b> · Departs 07:40 · Arrives 08:35 · Seat 14A</p>
          <p>Check-in opens 24 hours before departure.</p>
        </div>
    """
}
