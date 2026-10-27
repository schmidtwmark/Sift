import Foundation

/// Sample mail for demo mode: a few weeks of history (grandfathered past the
/// Screener) plus recent arrivals from new senders that land in the Screener.
public enum DemoSeed {
    /// Demo mode turns the Screener on this long ago, so recent mail gets screened.
    public static let activationAge: TimeInterval = 3 * 86_400

    static func populate(_ server: DemoServer) {
        let mailboxes: [(String, String, String?, Int)] = [
            ("inbox", "Inbox", "inbox", 1), ("archive", "Archive", "archive", 2), ("drafts", "Drafts", "drafts", 3),
            ("sent", "Sent", "sent", 4), ("junk", "Spam", "junk", 6), ("trash", "Trash", "trash", 7),
            ("receipts", "Receipts", nil, 10), ("newsletters", "Newsletters", nil, 11),
            ("travel", "Travel", nil, 12), ("family", "Family", nil, 13), ("hey-import", "Hey Import", nil, 14),
        ]
        for (id, name, role, order) in mailboxes {
            server.addMailbox(id: id, name: name, role: role, sortOrder: order)
        }
        server.addContact(name: "Alex Rivera", email: "alex@rivera.example")
        server.addContact(name: "Mom", email: "mom@family.example")

        let day: TimeInterval = 86_400
        func ago(_ days: Double, hours: Double = 0) -> Date { .now.addingTimeInterval(-(days * day + hours * 3600)) }

        // History (before the Screener was switched on).
        server.deliver(from: ("Alex Rivera", "alex@rivera.example"), subject: "Climbing on Saturday?",
                       text: "Gym opens at 9. I can bring the spare harness if you want to try lead.",
                       receivedAt: ago(12), keywords: ["$seen"], threadId: "T-climb")
        server.deliver(from: ("You", "you@fastmail.com"), subject: "Re: Climbing on Saturday?",
                       text: "Yes! 9:30 works. Bring the harness.", mailbox: "sent",
                       receivedAt: ago(11.8), keywords: ["$seen"], threadId: "T-climb", to: "alex@rivera.example")
        server.deliver(from: ("Mom", "mom@family.example"), subject: "Thanksgiving plans",
                       text: "Are you all coming Wednesday night or Thursday morning? Let me know about the kids' beds.",
                       mailbox: "family", receivedAt: ago(9), keywords: ["$seen"], threadId: "T-thanks")
        server.deliver(from: ("Brightside Bank", "alerts@brightside.example"), subject: "Your statement is ready",
                       text: "Your October statement for the account ending 4410 is ready to view.",
                       mailbox: "receipts", receivedAt: ago(8), keywords: ["$seen"])
        server.deliver(from: ("Northwind Outfitters", "orders@northwind.example"), subject: "Order NW-20931 confirmed",
                       text: "Thanks for your order! Trail runner shoes (men's 10.5), qty 1 — $129.00.",
                       html: receiptHTML(order: "NW-20931", item: "Trail runner shoes", price: "$129.00"),
                       mailbox: "receipts", receivedAt: ago(6), keywords: ["$seen"])
        server.deliver(from: ("Field Notes Digest", "digest@fieldnotes.example"), subject: "Issue 88: The quiet internet",
                       text: "This week: small web, slow software, and why your inbox should be boring.",
                       html: newsletterHTML(title: "The quiet internet", pixel: nil),
                       mailbox: "newsletters", receivedAt: ago(5), keywords: ["$seen"])
        server.deliver(from: ("Alex Rivera", "alex@rivera.example"), subject: "Photos from the crag",
                       text: "Dumped everything into the shared album. The one of you on the arete is great.",
                       mailbox: "archive", receivedAt: ago(4), keywords: ["$seen"])

        // An unsorted import from HEY: years of mail in one folder.
        let imported: [(name: String, email: String, subject: String, daysAgo: Double)] = [
            ("Field Notes Digest", "digest@fieldnotes.example", "Issue 41: Paper over pixels", 420),
            ("Field Notes Digest", "digest@fieldnotes.example", "Issue 52: The long now", 340),
            ("Field Notes Digest", "digest@fieldnotes.example", "Issue 60: Slow mornings", 280),
            ("Brightside Bank", "alerts@brightside.example", "Your 2024 tax documents", 600),
            ("Brightside Bank", "alerts@brightside.example", "Your statement is ready", 390),
            ("Alex Rivera", "alex@rivera.example", "Moving day help?", 700),
            ("Harbor Yoga", "studio@harboryoga.example", "Your class pass expires soon", 500),
            ("Old Landlord", "rentals@oaktree.example", "Lease renewal", 800),
        ]
        for entry in imported {
            server.deliver(from: (entry.name, entry.email), subject: entry.subject, text: "Imported from HEY.",
                           mailbox: "hey-import", receivedAt: ago(entry.daysAgo), keywords: ["$seen"], to: "you@hey.example")
        }
        for (subject, daysAgo) in [("Re: Moving day help?", 699.0), ("Lease question", 805.0)] {
            server.deliver(from: ("You", "you@hey.example"), subject: subject, text: "Sent from HEY.",
                           mailbox: "hey-import", receivedAt: ago(daysAgo), keywords: ["$seen"], to: "alex@rivera.example")
        }

        // Arrivals after the Screener was switched on.
        server.deliver(from: ("Paperline Weekly", "hello@paperline.example"), subject: "Five tools we can't stop using",
                       text: "Plus: the notebook that changed how we plan our week.",
                       html: newsletterHTML(title: "Five tools we can't stop using",
                                            pixel: "https://paperline.us5.list-manage.com/track/open.php?u=8f2a&id=91c"),
                       receivedAt: ago(2, hours: 3))
        server.deliver(from: ("Kai at Lumen Labs", "kai@lumenlabs.example"), subject: "Quick question about your team",
                       text: "Hi there — I noticed your team is growing and wondered if you'd have 15 minutes this week to chat about Lumen.",
                       html: """
                       <p>Hi there,</p><p>I noticed your team is growing and wondered if you'd have 15 minutes this week to chat about how Lumen helps teams ship faster.</p><p>Best,<br>Kai</p>
                       <img src="https://t.sidekickopen87.com/Ctc/5D+113/c3Lh-04/open" width="1" height="1" style="display:block">
                       """,
                       receivedAt: ago(1, hours: 20))
        // Fastmail's filter caught this one; Sift's "Not Spam" brings it back.
        server.deliver(from: ("Basecamp Climbing", "news@basecampclimbing.example"), subject: "New routes in the cave",
                       text: "Twelve new problems went up this week, from V0 to V7. Members' night is Thursday.",
                       mailbox: "junk", receivedAt: ago(1, hours: 10))
        server.deliver(from: ("Fjord Air", "bookings@fjordair.example"), subject: "Your trip to Bergen: booking FJ7Q2K",
                       text: "Booking FJ7Q2K is confirmed. Departs Thursday 07:40, seat 14A. Check in opens 24 hours before departure.",
                       html: tripHTML, receivedAt: ago(1, hours: 6))
        server.deliver(from: ("Alex Rivera", "alex@rivera.example"), subject: "Re: Climbing on Saturday?",
                       text: "Same time this week? Bring chalk, mine's out.", receivedAt: ago(0, hours: 9), threadId: "T-climb")
        server.deliver(from: ("Coastal Dental", "reminders@coastaldental.example"), subject: "Appointment reminder: Tue 3:30 PM",
                       text: "This is a reminder of your cleaning appointment on Tuesday at 3:30 PM. Reply C to confirm.",
                       html: """
                       <p>This is a reminder of your cleaning appointment on <b>Tuesday at 3:30 PM</b>.</p>
                       <p>Reply C to confirm.</p><img src="https://email.coastaldental.example/o/eJxVjcEOgiAQRP-Gq0EQwYOH" alt="">
                       """,
                       receivedAt: ago(0, hours: 4))
        server.deliver(from: ("Northwind Outfitters", "orders@northwind.example"), subject: "Your order has shipped",
                       text: "Order NW-20931 is on its way. Tracking: 1Z 999 AA1 01 2345 6784.",
                       html: receiptHTML(order: "NW-20931", item: "Trail runner shoes — shipped", price: "$129.00"),
                       receivedAt: ago(0, hours: 2))
        server.deliver(from: ("Mom", "mom@family.example"), subject: "Re: Thanksgiving plans",
                       text: "Great, Wednesday it is. I'll make up the bunk beds.", receivedAt: ago(0, hours: 1),
                       threadId: "T-thanks")
    }

    static func newsletterHTML(title: String, pixel: String?) -> String {
        """
        <div style="font-family: Georgia, serif; max-width: 560px; margin: 0 auto;">
          <h1 style="font-size: 26px; margin-bottom: 4px;">\(title)</h1>
          <p style="color: #666; margin-top: 0;">A weekly letter about tools, craft, and calm.</p>
          <hr style="border: none; border-top: 1px solid #ddd;">
          <h2 style="font-size: 18px;">1. A notebook that stays open</h2>
          <p>Lay-flat binding sounds like a small thing until you've fought a spiral for a year.</p>
          <h2 style="font-size: 18px;">2. The two-list method</h2>
          <p>One list for today, one for someday. Nothing else gets a list.</p>
          <p><a href="https://example.com/read">Read the full issue</a></p>
          \(pixel.map { "<img src=\"\($0)\" width=\"1\" height=\"1\" alt=\"\">" } ?? "")
        </div>
        """
    }

    static func receiptHTML(order: String, item: String, price: String) -> String {
        """
        <table style="font-family: -apple-system, sans-serif; width: 100%; max-width: 520px; border-collapse: collapse;">
          <tr><td style="font-size: 20px; font-weight: 600; padding-bottom: 12px;">Order \(order)</td></tr>
          <tr><td style="padding: 8px 0; border-top: 1px solid #eee;">\(item)</td><td style="text-align: right;">\(price)</td></tr>
          <tr><td style="padding: 8px 0; border-top: 1px solid #eee; font-weight: 600;">Total</td><td style="text-align: right; font-weight: 600;">\(price)</td></tr>
        </table>
        <img src="https://u1234.ct.sendgrid.net/wf/open?upn=abc123" alt="" width="1" height="1" border="0">
        """
    }

    static let tripHTML = """
        <div style="font-family: -apple-system, sans-serif;">
          <p style="font-size: 13px; color: #888; text-transform: uppercase; letter-spacing: .08em;">Booking FJ7Q2K</p>
          <h1 style="font-size: 24px;">Oslo → Bergen</h1>
          <p><b>Thursday</b> · Departs 07:40 · Arrives 08:35 · Seat 14A</p>
          <p>Check-in opens 24 hours before departure.</p>
        </div>
        """
}
