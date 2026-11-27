import Foundation
import AlarmKit
import AppIntents
import SwiftUI
import UserNotifications

struct PrayerAlarmData: AlarmMetadata {
    var prayer: String
}

enum Store {
    static let d = UserDefaults.standard
    static var latitude: Double? {
        get { d.object(forKey: "lat") as? Double }
        set { d.set(newValue, forKey: "lat") }
    }
    static var longitude: Double? {
        get { d.object(forKey: "lng") as? Double }
        set { d.set(newValue, forKey: "lng") }
    }
    static func isEnabled(_ p: Prayer) -> Bool { d.object(forKey: "on_\(p.rawValue)") as? Bool ?? true }
    static func setEnabled(_ p: Prayer, _ v: Bool) { d.set(v, forKey: "on_\(p.rawValue)") }
    /// آخر مرة الفجر اتقفل بصورة صحيحة
    static var fajrVerifiedAt: Date? {
        get { d.object(forKey: "fajrVerifiedAt") as? Date }
        set { d.set(newValue, forKey: "fajrVerifiedAt") }
    }
    /// ميعاد الفجر الحالي اللي لسه شغال (عشان نعرف هل اتقفل ولا لأ)
    static var activeFajrStart: Date? {
        get { d.object(forKey: "activeFajrStart") as? Date }
        set { d.set(newValue, forKey: "activeFajrStart") }
    }
    static var openCamera: Bool {
        get { d.bool(forKey: "openCamera") }
        set { d.set(newValue, forKey: "openCamera") }
    }
    static var fajrScheduled: [String: Double] {
        get { d.dictionary(forKey: "fajrScheduled") as? [String: Double] ?? [:] }
        set { d.set(newValue, forKey: "fajrScheduled") }
    }
}

@MainActor
final class AlarmService {
    static let shared = AlarmService()
    let manager = AlarmManager.shared
    let daysAhead = 7

    func requestAuthorization() async -> Bool {
        do {
            switch manager.authorizationState {
            case .authorized: return true
            case .denied: return false
            default: return try await manager.requestAuthorization() == .authorized
            }
        } catch { return false }
    }

    func cancelAll() {
        for a in (try? manager.alarms) ?? [] { try? manager.cancel(id: a.id) }
    }

    /// يمسح كل المنبهات ويجدول الصلوات للأيام الجاية
    func rescheduleAll() async {
        guard let lat = Store.latitude, let lng = Store.longitude else { return }
        guard await requestAuthorization() else { return }
        cancelAll()
        let calc = PrayerCalculator(latitude: lat, longitude: lng)
        let now = Date()
        var fajrMap: [String: Double] = [:]
        for dayOffset in 0..<daysAhead {
            let day = Calendar.current.date(byAdding: .day, value: dayOffset, to: now)!
            for (prayer, time) in calc.times(for: day) where time > now && Store.isEnabled(prayer) {
                let id = UUID()
                await schedule(id: id, prayer: prayer, at: time)
                if prayer == .fajr { fajrMap[id.uuidString] = time.timeIntervalSince1970 }
            }
        }
        Store.fajrScheduled = fajrMap
    }

    static func makeConfig(prayer: Prayer, at date: Date) -> AlarmManager.AlarmConfiguration<PrayerAlarmData> {
        let isFajr = prayer == .fajr
        let stop = AlarmButton(text: isFajr ? "غفوة" : "إيقاف", textColor: .white, systemImageName: isFajr ? "zzz" : "stop.fill")
        let camera = AlarmButton(text: "صوّر المكان", textColor: .white, systemImageName: "camera.fill")
        let alert: AlarmPresentation.Alert
        if isFajr {
            alert = AlarmPresentation.Alert(
                title: LocalizedStringResource(stringLiteral: "الصلاة خير من النوم"),
                stopButton: stop,
                secondaryButton: camera,
                secondaryButtonBehavior: .custom)
        } else {
            alert = AlarmPresentation.Alert(
                title: LocalizedStringResource(stringLiteral: "حان الآن موعد أذان \(prayer.arabic)"),
                stopButton: stop)
        }
        let attributes = AlarmAttributes<PrayerAlarmData>(
            presentation: AlarmPresentation(alert: alert),
            metadata: PrayerAlarmData(prayer: prayer.rawValue),
            tintColor: .green)
        return AlarmManager.AlarmConfiguration<PrayerAlarmData>.alarm(
            schedule: .fixed(date),
            attributes: attributes,
            stopIntent: isFajr ? FajrStopIntent() : nil,
            secondaryIntent: isFajr ? OpenCameraIntent() : nil,
            sound: .named("adhan.caf"))
    }

    func schedule(id: UUID, prayer: Prayer, at date: Date) async {
        _ = try? await manager.schedule(id: id, configuration: Self.makeConfig(prayer: prayer, at: date))
    }

    /// منبه فجر إضافي بعد ثواني لو اتقفل من غير صورة
    nonisolated static func scheduleFajrRepeat(after seconds: TimeInterval) async {
        let date = Date().addingTimeInterval(seconds)
        _ = try? await AlarmManager.shared.schedule(id: UUID(), configuration: makeConfig(prayer: .fajr, at: date))
    }

    /// بعد الصورة الصحيحة: نلغي أي تكرار فجر معلّق
    func fajrVerified() async {
        Store.fajrVerifiedAt = Date()
        Store.activeFajrStart = nil
        let scheduled = Store.fajrScheduled
        for a in (try? manager.alarms) ?? [] {
            // نلغي التكرارات بس (اللي مش في جدول الفجر الأصلي)
            if scheduled[a.id.uuidString] == nil, case .fixed(let d)? = a.schedule, d.timeIntervalSinceNow < 3600 {
                try? manager.cancel(id: a.id)
            }
        }
        await rescheduleAll()
    }
}

/// زرار «غفوة» في منبه الفجر: لو مفيش صورة، المنبه يرجع بعد ٣٠ ثانية
struct FajrStopIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "إيقاف الفجر"
    init() {}
    func perform() async throws -> some IntentResult {
        let verified = UserDefaults.standard.object(forKey: "fajrVerifiedAt") as? Date
        let recentlyVerified = verified.map { Date().timeIntervalSince($0) < 3 * 3600 } ?? false
        if !recentlyVerified {
            if UserDefaults.standard.object(forKey: "activeFajrStart") == nil {
                UserDefaults.standard.set(Date(), forKey: "activeFajrStart")
            }
            await AlarmService.scheduleFajrRepeat(after: 30)
        }
        return .result()
    }
}

/// زرار «صوّر المكان»: يفتح التطبيق على الكاميرا
struct OpenCameraIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "تصوير المكان"
    static let openAppWhenRun = true
    init() {}
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: "openCamera")
        if UserDefaults.standard.object(forKey: "activeFajrStart") == nil {
            UserDefaults.standard.set(Date(), forKey: "activeFajrStart")
        }
        // أمان: لو قفل التطبيق من غير ما يصوّر، يرجع يرن بعد دقيقتين
        let verified = UserDefaults.standard.object(forKey: "fajrVerifiedAt") as? Date
        if !(verified.map { Date().timeIntervalSince($0) < 3 * 3600 } ?? false) {
            await AlarmService.scheduleFajrRepeat(after: 120)
        }
        return .result()
    }
}

/// تنبيه قبل انتهاء صلاحية التطبيق بيوم (حساب أبل المجاني = ٧ أيام)
enum ExpiryWatcher {
    static func expirationDate() -> Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<plist"), let end = text.range(of: "</plist>") else { return nil }
        let xml = Data(text[start.lowerBound..<end.upperBound].utf8)
        let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any]
        return plist?["ExpirationDate"] as? Date
    }

    static func scheduleReminder() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        center.removePendingNotificationRequests(withIdentifiers: ["expiry"])
        guard let exp = expirationDate() else { return }
        let fire = exp.addingTimeInterval(-24 * 3600)
        guard fire > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = "تطبيق الفجر هيقف بكرة"
        content.body = "افتح SideStore ودوس تجديد، وإلا الأذان مش هيرن."
        content.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        let req = UNNotificationRequest(identifier: "expiry", content: content,
                                        trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
        try? await center.add(req)
    }
}
