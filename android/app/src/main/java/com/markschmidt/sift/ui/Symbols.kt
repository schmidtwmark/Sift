package com.markschmidt.sift.ui

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.DirectionsRun
import androidx.compose.material.icons.automirrored.outlined.MenuBook
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material.icons.automirrored.outlined.TrendingUp
import androidx.compose.material.icons.outlined.AccountBalance
import androidx.compose.material.icons.outlined.AllInbox
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.BackHand
import androidx.compose.material.icons.outlined.BarChart
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material.icons.outlined.BookmarkBorder
import androidx.compose.material.icons.outlined.Build
import androidx.compose.material.icons.outlined.Business
import androidx.compose.material.icons.outlined.Cake
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.Campaign
import androidx.compose.material.icons.outlined.CardGiftcard
import androidx.compose.material.icons.outlined.ChildCare
import androidx.compose.material.icons.outlined.Cloud
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.ConfirmationNumber
import androidx.compose.material.icons.outlined.Construction
import androidx.compose.material.icons.outlined.CreditCard
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.DirectionsBike
import androidx.compose.material.icons.outlined.DirectionsBoat
import androidx.compose.material.icons.outlined.DirectionsBus
import androidx.compose.material.icons.outlined.DirectionsCar
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material.icons.outlined.Drafts
import androidx.compose.material.icons.outlined.Eco
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Email
import androidx.compose.material.icons.outlined.EmojiEvents
import androidx.compose.material.icons.outlined.FamilyRestroom
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material.icons.outlined.Festival
import androidx.compose.material.icons.outlined.FitnessCenter
import androidx.compose.material.icons.outlined.Flag
import androidx.compose.material.icons.outlined.Flight
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Forum
import androidx.compose.material.icons.outlined.HealthAndSafety
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.Hotel
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material.icons.outlined.Inventory2
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.Laptop
import androidx.compose.material.icons.outlined.Layers
import androidx.compose.material.icons.outlined.Lightbulb
import androidx.compose.material.icons.outlined.LocalCafe
import androidx.compose.material.icons.outlined.LocalFireDepartment
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Luggage
import androidx.compose.material.icons.outlined.Map
import androidx.compose.material.icons.outlined.MedicalServices
import androidx.compose.material.icons.outlined.Medication
import androidx.compose.material.icons.outlined.MonetizationOn
import androidx.compose.material.icons.outlined.MonitorHeart
import androidx.compose.material.icons.outlined.Movie
import androidx.compose.material.icons.outlined.MusicNote
import androidx.compose.material.icons.outlined.Newspaper
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.Payments
import androidx.compose.material.icons.outlined.People
import androidx.compose.material.icons.outlined.Percent
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material.icons.outlined.PersonSearch
import androidx.compose.material.icons.outlined.Pets
import androidx.compose.material.icons.outlined.Phone
import androidx.compose.material.icons.outlined.PhotoCamera
import androidx.compose.material.icons.outlined.Place
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material.icons.outlined.ReceiptLong
import androidx.compose.material.icons.outlined.Redeem
import androidx.compose.material.icons.outlined.Report
import androidx.compose.material.icons.outlined.Restaurant
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.School
import androidx.compose.material.icons.outlined.Sell
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Shield
import androidx.compose.material.icons.outlined.ShoppingBag
import androidx.compose.material.icons.outlined.ShoppingCart
import androidx.compose.material.icons.outlined.SportsBasketball
import androidx.compose.material.icons.outlined.SportsEsports
import androidx.compose.material.icons.outlined.StarOutline
import androidx.compose.material.icons.outlined.Storefront
import androidx.compose.material.icons.outlined.TheaterComedy
import androidx.compose.material.icons.outlined.Tram
import androidx.compose.material.icons.outlined.Tv
import androidx.compose.material.icons.outlined.Verified
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material.icons.outlined.WaterDrop
import androidx.compose.material.icons.outlined.Wifi
import androidx.compose.material.icons.outlined.WineBar
import androidx.compose.material.icons.outlined.Work
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * Material stand-ins for the SF Symbol names Sift stores in Fastmail. The
 * names are what syncs, so an icon picked on the Mac shows here and the
 * other way round.
 */
object Symbols {
    private val map: Map<String, ImageVector> = mapOf(
        // General
        "tag" to Icons.Outlined.Sell, "folder" to Icons.Outlined.Folder, "tray.full" to Icons.Outlined.AllInbox,
        "archivebox" to Icons.Outlined.Archive, "star" to Icons.Outlined.StarOutline, "heart" to Icons.Outlined.FavoriteBorder,
        "bookmark" to Icons.Outlined.BookmarkBorder, "flag" to Icons.Outlined.Flag, "pin" to Icons.Outlined.PushPin,
        "bell" to Icons.Outlined.Notifications, "lightbulb" to Icons.Outlined.Lightbulb, "sparkles" to Icons.Outlined.AutoAwesome,
        "bolt" to Icons.Outlined.Bolt, "flame" to Icons.Outlined.LocalFireDepartment, "leaf" to Icons.Outlined.Eco,
        "drop" to Icons.Outlined.WaterDrop,
        // Money & Shopping
        "receipt" to Icons.Outlined.ReceiptLong, "cart" to Icons.Outlined.ShoppingCart, "bag" to Icons.Outlined.ShoppingBag,
        "creditcard" to Icons.Outlined.CreditCard, "banknote" to Icons.Outlined.Payments,
        "dollarsign.circle" to Icons.Outlined.MonetizationOn, "building.columns" to Icons.Outlined.AccountBalance,
        "chart.line.uptrend.xyaxis" to Icons.AutoMirrored.Outlined.TrendingUp, "percent" to Icons.Outlined.Percent,
        "giftcard" to Icons.Outlined.CardGiftcard, "gift" to Icons.Outlined.Redeem, "storefront" to Icons.Outlined.Storefront,
        "shippingbox" to Icons.Outlined.Inventory2,
        // Work & School
        "briefcase" to Icons.Outlined.Work, "building.2" to Icons.Outlined.Business, "doc.text" to Icons.Outlined.Description,
        "newspaper" to Icons.Outlined.Newspaper, "book" to Icons.AutoMirrored.Outlined.MenuBook, "graduationcap" to Icons.Outlined.School,
        "pencil" to Icons.Outlined.Edit, "hammer" to Icons.Outlined.Construction, "wrench.and.screwdriver" to Icons.Outlined.Build,
        "laptopcomputer" to Icons.Outlined.Laptop, "chart.bar" to Icons.Outlined.BarChart, "calendar" to Icons.Outlined.CalendarMonth,
        "clock" to Icons.Outlined.Schedule, "server.rack" to Icons.Outlined.Dns, "megaphone" to Icons.Outlined.Campaign,
        "chevron.left.forwardslash.chevron.right" to Icons.Outlined.Code,
        // Travel & Places
        "airplane" to Icons.Outlined.Flight, "car" to Icons.Outlined.DirectionsCar, "tram" to Icons.Outlined.Tram,
        "bus" to Icons.Outlined.DirectionsBus, "ferry" to Icons.Outlined.DirectionsBoat, "bicycle" to Icons.Outlined.DirectionsBike,
        "suitcase" to Icons.Outlined.Luggage, "map" to Icons.Outlined.Map, "mappin.and.ellipse" to Icons.Outlined.Place,
        "globe.americas" to Icons.Outlined.Public, "house" to Icons.Outlined.Home, "bed.double" to Icons.Outlined.Hotel,
        "tent" to Icons.Outlined.Festival,
        // People & Fun
        "person" to Icons.Outlined.Person, "person.2" to Icons.Outlined.People,
        "figure.2.and.child.holdinghands" to Icons.Outlined.FamilyRestroom, "figure.and.child.holdinghands" to Icons.Outlined.ChildCare,
        "bubble.left.and.bubble.right" to Icons.Outlined.Forum, "pawprint" to Icons.Outlined.Pets,
        "gamecontroller" to Icons.Outlined.SportsEsports, "music.note" to Icons.Outlined.MusicNote, "film" to Icons.Outlined.Movie,
        "tv" to Icons.Outlined.Tv, "camera" to Icons.Outlined.PhotoCamera, "photo" to Icons.Outlined.Image,
        "ticket" to Icons.Outlined.ConfirmationNumber, "theatermasks" to Icons.Outlined.TheaterComedy,
        "trophy" to Icons.Outlined.EmojiEvents, "sportscourt" to Icons.Outlined.SportsBasketball,
        "figure.run" to Icons.AutoMirrored.Outlined.DirectionsRun, "dumbbell" to Icons.Outlined.FitnessCenter,
        // Health & Home
        "cross.case" to Icons.Outlined.MedicalServices, "pills" to Icons.Outlined.Medication,
        "stethoscope" to Icons.Outlined.HealthAndSafety, "heart.text.square" to Icons.Outlined.MonitorHeart,
        "fork.knife" to Icons.Outlined.Restaurant, "cup.and.saucer" to Icons.Outlined.LocalCafe, "wineglass" to Icons.Outlined.WineBar,
        "birthday.cake" to Icons.Outlined.Cake, "wifi" to Icons.Outlined.Wifi, "phone" to Icons.Outlined.Phone,
        "envelope" to Icons.Outlined.Email, "paperplane" to Icons.AutoMirrored.Outlined.Send, "lock" to Icons.Outlined.Lock,
        "key" to Icons.Outlined.Key, "shield" to Icons.Outlined.Shield, "checkmark.seal" to Icons.Outlined.Verified,
        "exclamationmark.triangle" to Icons.Outlined.Warning, "gearshape" to Icons.Outlined.Settings, "cloud" to Icons.Outlined.Cloud,
        // System mailboxes and views
        "tray" to Icons.Outlined.Inbox, "person.crop.circle.badge.questionmark" to Icons.Outlined.PersonSearch,
        "hand.raised" to Icons.Outlined.BackHand, "doc" to Icons.Outlined.Drafts, "xmark.bin" to Icons.Outlined.Report,
        "trash" to Icons.Outlined.Delete, "square.stack.3d.up" to Icons.Outlined.Layers,
    )

    fun icon(symbol: String): ImageVector = map[symbol] ?: Icons.Outlined.Sell

    fun has(symbol: String) = symbol in map
}
