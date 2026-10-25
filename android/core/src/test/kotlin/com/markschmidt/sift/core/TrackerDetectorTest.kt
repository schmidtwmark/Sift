package com.markschmidt.sift.core

import com.markschmidt.sift.core.privacy.DetectedTracker.Reason
import com.markschmidt.sift.core.privacy.HtmlText
import com.markschmidt.sift.core.privacy.TrackerDetector
import com.markschmidt.sift.core.privacy.TrackerList
import com.markschmidt.sift.core.privacy.UrlParts
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class TrackerDetectorTest {
    @Test fun removesKnownServicesAndNamesThem() {
        val html = """<p>Hi</p><img src="https://acme.us1.list-manage.com/track/open.php?u=1" width="1" height="1"><img src="https://cdn.acme.com/logo.png" width="200" height="50">"""
        val result = TrackerDetector.sanitize(html)
        assertEquals(listOf("Mailchimp"), result.trackers.map { it.name })
        assertEquals(Reason.KNOWN_SERVICE, result.trackers.first().reason)
        assertFalse(result.html.contains("list-manage"))
        assertTrue(result.html.contains("logo.png"))
        assertEquals(1, result.remoteImageCount)
        assertEquals("Mailchimp", result.trackerSummary)
    }

    @Test fun catchesTinyHiddenAndBeaconImages() {
        val tiny = """<img src="https://news.example.co.uk/x/abc" style="width: 1px; height: 1px">"""
        val hidden = """<img src='https://t.example.com/p' style="display:none">"""
        val beacon = """<img src=https://mail.example.org/open?id=42>"""
        val result = TrackerDetector.sanitize(tiny + hidden + beacon)
        assertEquals(listOf(Reason.TINY_IMAGE, Reason.HIDDEN_IMAGE, Reason.BEACON_PATH), result.trackers.map { it.reason })
        assertEquals("example.co.uk", result.trackers.first().name)
        assertFalse(result.html.contains("<img"))
    }

    @Test fun leavesLocalAndOrdinaryImagesAlone() {
        val html = """<img src="cid:logo"><img src="data:image/png;base64,AA" width="1" height="1"><img src="https://x.com/hero.jpg" width="1" height="400">"""
        val result = TrackerDetector.sanitize(html)
        assertTrue(result.trackers.isEmpty())
        assertEquals(1, result.remoteImageCount)
    }

    @Test fun detectsMailgunOpenPixels() {
        assertEquals("Substack", TrackerDetector.sanitize("""<img src="https://email.mg.substack.com/o/eJwlj">""").trackers.first().name)
        assertEquals("Mailgun", TrackerDetector.sanitize("""<img src="https://email.coastaldental.example/o/eJxV" alt="">""").trackers.first().name)
    }

    @Test fun namesSeveralTrackersOnce() {
        val html = """<img src="https://track.hubspot.com/a" ><img src="https://emltrk.com/b"><img src="https://track.hubspot.com/c">"""
        assertEquals("HubSpot and Litmus", TrackerDetector.sanitize(html).trackerSummary)
    }

    @Test fun stripsScriptsFramesAndRemoteStylesheets() {
        val html = """<script>alert(1)</script><iframe src="https://x.com"></iframe><link rel="stylesheet" href="https://x.com/a.css"><b>ok</b>"""
        assertEquals("<b>ok</b>", TrackerDetector.sanitize(html).html)
        assertEquals("<p>x</p>", TrackerDetector.sanitize("""<meta http-equiv="refresh" content="0;url=https://x.com"><p>x</p>""").html)
    }

    @Test fun blocksTrackersAtTheNetworkLayer() {
        // Known services are refused even with remote images on (CSS backgrounds, anything the HTML pass missed).
        assertTrue(TrackerDetector.shouldBlock("https://u1.ct.sendgrid.net/wf/open?upn=1", allowRemote = true))
        assertFalse(TrackerDetector.shouldBlock("https://cdn.example.com/hero.jpg", allowRemote = true))
        // Remote images off: every remote load is refused, local ones still work.
        assertTrue(TrackerDetector.shouldBlock("https://cdn.example.com/hero.jpg", allowRemote = false))
        assertFalse(TrackerDetector.shouldBlock("sift-blob://blob/G1?type=image/png", allowRemote = false))
        assertFalse(TrackerDetector.shouldBlock("data:image/png;base64,AA", allowRemote = false))
    }

    @Test fun parsesUrlsLikeTheRules() {
        assertEquals(UrlParts("mjt.lu", "/oo/AB", "x=1"), UrlParts.parse("https://user@MJT.lu:443/oo/AB?x=1#frag"))
        assertEquals(UrlParts("cdn.x.com", "/a", null), UrlParts.parse("//cdn.x.com/a"))
        assertEquals("Mailjet", TrackerList.match(UrlParts.parse("https://abc.mjt.lu/oo/xyz")!!)?.name)
        assertEquals(64, TrackerList.rules.size)
    }

    @Test fun plainTextFromHtml() {
        assertEquals("One & two\nThree —", HtmlText.plainText("<style>p{}</style><p>One &amp; two</p><p>Three&nbsp;&#8212;</p>"))
        assertEquals("Café ✓", HtmlText.decodeEntities("Caf&#xe9; &#10003;"))
        assertEquals("&lt;b&gt; &amp; &quot;", HtmlText.escape("<b> & \""))
    }
}
