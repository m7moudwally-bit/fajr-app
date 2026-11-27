import Foundation

enum Prayer: String, CaseIterable, Codable, Identifiable {
    case fajr, dhuhr, asr, maghrib, isha
    var id: String { rawValue }
    var arabic: String {
        switch self {
        case .fajr: "الفجر"
        case .dhuhr: "الظهر"
        case .asr: "العصر"
        case .maghrib: "المغرب"
        case .isha: "العشاء"
        }
    }
}

/// حساب مواعيد الصلاة بطريقة الهيئة المصرية العامة للمساحة (فجر 19.5°، عشاء 17.5°، عصر شافعي)
struct PrayerCalculator {
    let latitude: Double
    let longitude: Double
    var fajrAngle = 19.5
    var ishaAngle = 17.5

    private func rad(_ d: Double) -> Double { d * .pi / 180 }
    private func deg(_ r: Double) -> Double { r * 180 / .pi }
    private func fix(_ a: Double, _ b: Double) -> Double { let r = a.truncatingRemainder(dividingBy: b); return r < 0 ? r + b : r }

    private func julian(_ y: Int, _ m: Int, _ d: Int) -> Double {
        var y = y, m = m
        if m <= 2 { y -= 1; m += 12 }
        let a = Double(y / 100), b = 2 - a + floor(a / 4)
        return floor(365.25 * Double(y + 4716)) + floor(30.6001 * Double(m + 1)) + Double(d) + b - 1524.5
    }

    private func sun(_ jd: Double) -> (decl: Double, eqt: Double) {
        let d = jd - 2451545.0
        let g = fix(357.529 + 0.98560028 * d, 360)
        let q = fix(280.459 + 0.98564736 * d, 360)
        let l = fix(q + 1.915 * sin(rad(g)) + 0.020 * sin(rad(2 * g)), 360)
        let e = 23.439 - 0.00000036 * d
        let ra = fix(deg(atan2(cos(rad(e)) * sin(rad(l)), cos(rad(l)))) / 15, 24)
        return (deg(asin(sin(rad(e)) * sin(rad(l)))), q / 15 - ra)
    }

    /// يرجّع المواعيد بتوقيت UTC بالساعات العشرية ثم يحوّلها لتواريخ
    func times(for date: Date) -> [Prayer: Date] {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        var local = Calendar(identifier: .gregorian); local.timeZone = .current
        let c = local.dateComponents([.year, .month, .day], from: date)
        let jd = julian(c.year!, c.month!, c.day!) - longitude / 360

        func noon(_ t: Double) -> Double { fix(12 - sun(jd + t / 24).eqt, 24) }
        func angleTime(_ angle: Double, _ t: Double, ccw: Bool) -> Double {
            let decl = sun(jd + t / 24).decl
            let n = noon(t)
            let v = (-sin(rad(angle)) - sin(rad(decl)) * sin(rad(latitude))) / (cos(rad(decl)) * cos(rad(latitude)))
            let h = deg(acos(max(-1, min(1, v)))) / 15
            return n + (ccw ? -h : h)
        }
        func asrTime(_ t: Double) -> Double {
            let decl = sun(jd + t / 24).decl
            let a = -deg(atan(1 / (1 + tan(rad(abs(latitude - decl))))))
            return angleTime(a, t, ccw: false)
        }
        // تقريب أولي ثم تكرار مرة للدقة
        var f = angleTime(fajrAngle, 5, ccw: true)
        var dh = noon(12)
        var a = asrTime(13)
        var m = angleTime(0.833, 18, ccw: false)
        var i = angleTime(ishaAngle, 18, ccw: false)
        f = angleTime(fajrAngle, f, ccw: true); dh = noon(dh); a = asrTime(a)
        m = angleTime(0.833, m, ccw: false); i = angleTime(ishaAngle, i, ccw: false)

        let tz = 0.0 // نشتغل بـ UTC ثم نحوّل
        func toDate(_ hours: Double, plusMinutes: Double = 0) -> Date {
            let h = hours - longitude / 15 + tz + plusMinutes / 60
            let base = utc.date(from: DateComponents(year: c.year, month: c.month, day: c.day))!
            return base.addingTimeInterval((h * 3600).rounded())
        }
        return [
            .fajr: toDate(f),
            .dhuhr: toDate(dh, plusMinutes: 1),
            .asr: toDate(a),
            .maghrib: toDate(m, plusMinutes: 1),
            .isha: toDate(i)
        ]
    }
}
