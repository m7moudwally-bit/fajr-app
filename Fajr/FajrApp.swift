import SwiftUI
import CoreLocation
import BackgroundTasks

@main
struct FajrApp: App {
    @Environment(\.scenePhase) private var phase

    init() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.mahmoud.fajr.refresh", using: nil) { task in
            Task { @MainActor in
                await AlarmService.shared.rescheduleAll()
                FajrApp.scheduleRefresh()
                task.setTaskCompleted(success: true)
            }
        }
    }

    static func scheduleRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: "com.mahmoud.fajr.refresh")
        req.earliestBeginDate = Date().addingTimeInterval(12 * 3600)
        try? BGTaskScheduler.shared.submit(req)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "ar_EG"))
        }
        .onChange(of: phase) { _, p in
            if p == .background { FajrApp.scheduleRefresh() }
        }
    }
}

final class LocationGetter: NSObject, CLLocationManagerDelegate, ObservableObject {
    private let m = CLLocationManager()
    var done: ((CLLocation?) -> Void)?
    override init() { super.init(); m.delegate = self; m.desiredAccuracy = kCLLocationAccuracyKilometer }
    func fetch(_ cb: @escaping (CLLocation?) -> Void) {
        done = cb
        m.requestWhenInUseAuthorization()
        m.requestLocation()
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) { done?(locations.last); done = nil }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { done?(nil); done = nil }
}

struct ContentView: View {
    @StateObject private var loc = LocationGetter()
    @State private var times: [Prayer: Date] = [:]
    @State private var enabled: [Prayer: Bool] = Dictionary(uniqueKeysWithValues: Prayer.allCases.map { ($0, Store.isEnabled($0)) })
    @State private var showCamera = false
    @State private var cameraMode: CameraMode = .verify
    @State private var message: String?
    @State private var hasRef = PhotoVerifier.hasReference
    @State private var expiry = ExpiryWatcher.expirationDate()
    @State private var needsVerify = false
    @Environment(\.scenePhase) private var phase

    enum CameraMode { case reference, verify }

    var body: some View {
        NavigationStack {
            List {
                if needsVerify {
                    Section {
                        Button {
                            cameraMode = .verify; showCamera = true
                        } label: {
                            Label("صوّر المكان عشان توقف الفجر", systemImage: "camera.fill")
                                .font(.title3.bold())
                        }
                        .listRowBackground(Color.green.opacity(0.25))
                    }
                }
                Section("مواعيد النهارده") {
                    ForEach(Prayer.allCases) { p in
                        HStack {
                            Text(p.arabic).font(.headline)
                            Spacer()
                            if let t = times[p] { Text(t, style: .time).monospacedDigit() }
                            Toggle("", isOn: Binding(
                                get: { enabled[p] ?? true },
                                set: { v in enabled[p] = v; Store.setEnabled(p, v); Task { await AlarmService.shared.rescheduleAll() } }
                            )).labelsHidden()
                        }
                    }
                }
                Section("مكان إيقاف الفجر") {
                    if hasRef, let img = UIImage(contentsOfFile: PhotoVerifier.photoURL.path) {
                        Image(uiImage: img).resizable().scaledToFit().frame(maxHeight: 180).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    Button(hasRef ? "غيّر صورة المكان" : "صوّر المكان (حنفية الحمام أو باب الشقة)") {
                        cameraMode = .reference; showCamera = true
                    }
                    Button("جرّب الصورة دلوقتي") { cameraMode = .verify; showCamera = true }
                        .disabled(!hasRef)
                }
                Section {
                    Button("جرّب صوت الأذان بعد ١٠ ثواني") {
                        Task { await AlarmService.shared.schedule(id: UUID(), prayer: .dhuhr, at: Date().addingTimeInterval(10)) }
                        message = "اقفل الشاشة واستنى ١٠ ثواني."
                    }
                    Button("تحديث المكان والمواعيد") { refreshLocation() }
                } footer: {
                    if let e = expiry {
                        Text("صلاحية التطبيق لحد: \(e.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
            }
            .navigationTitle("الفجر")
            .sheet(isPresented: $showCamera) {
                CameraView { img in handle(img) }.ignoresSafeArea()
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("تمام", role: .cancel) {}
            }
            .task { await start() }
            .onChange(of: phase) { _, p in if p == .active { checkCameraFlag() } }
        }
    }

    func start() async {
        _ = await AlarmService.shared.requestAuthorization()
        await ExpiryWatcher.scheduleReminder()
        if Store.latitude == nil { refreshLocation() } else { await reload() }
        checkCameraFlag()
    }

    func reload() async {
        if let lat = Store.latitude, let lng = Store.longitude {
            times = PrayerCalculator(latitude: lat, longitude: lng).times(for: Date())
        }
        await AlarmService.shared.rescheduleAll()
    }

    func refreshLocation() {
        loc.fetch { l in
            if let l {
                Store.latitude = l.coordinate.latitude; Store.longitude = l.coordinate.longitude
            } else if Store.latitude == nil {
                // القاهرة الجديدة كافتراضي لو المكان مش متاح
                Store.latitude = 30.03; Store.longitude = 31.47
            }
            Task { await reload() }
        }
    }

    func checkCameraFlag() {
        needsVerify = Store.activeFajrStart != nil
        if Store.openCamera {
            Store.openCamera = false
            needsVerify = true
            if hasRef { cameraMode = .verify; showCamera = true }
        }
    }

    func handle(_ img: UIImage) {
        switch cameraMode {
        case .reference:
            hasRef = PhotoVerifier.saveReference(img)
            message = hasRef ? "اتسجل المكان. الصبح لازم تصوّره من نفس الزاوية تقريبًا." : "الصورة مش واضحة، جرب تاني."
        case .verify:
            let (ok, dist) = hasRef ? PhotoVerifier.check(img) : (true, 0)
            if ok {
                needsVerify = false
                Task { await AlarmService.shared.fajrVerified() }
                message = "صباح الخير، تقبل الله"
            } else {
                message = "مش نفس المكان (\(String(format: "%.2f", dist))). قوم صوّره تاني."
            }
        }
    }
}
