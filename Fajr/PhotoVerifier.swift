import UIKit
import Vision
import SwiftUI

/// يقارن صورة الصبح بصورة المكان المسجّلة
enum PhotoVerifier {
    static let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("reference.print")
    static let photoURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("reference.jpg")

    static var hasReference: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    static var threshold: Float {
        get { (UserDefaults.standard.object(forKey: "threshold") as? Float) ?? 0.85 }
        set { UserDefaults.standard.set(newValue, forKey: "threshold") }
    }

    static func featurePrint(_ image: UIImage) -> VNFeaturePrintObservation? {
        guard let cg = image.cgImage else { return nil }
        let req = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up)
        try? handler.perform([req])
        return req.results?.first
    }

    static func saveReference(_ image: UIImage) -> Bool {
        guard let fp = featurePrint(image),
              let data = try? NSKeyedArchiver.archivedData(withRootObject: fp, requiringSecureCoding: true) else { return false }
        try? data.write(to: fileURL)
        try? image.jpegData(compressionQuality: 0.6)?.write(to: photoURL)
        return true
    }

    /// يرجّع (مطابقة؟، المسافة)
    static func check(_ image: UIImage) -> (Bool, Float) {
        guard let data = try? Data(contentsOf: fileURL),
              let ref = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data),
              let fp = featurePrint(image) else { return (false, 99) }
        var distance: Float = 99
        try? fp.computeDistance(&distance, to: ref)
        return (distance <= threshold, distance)
    }
}

/// كاميرا بس، من غير ألبوم الصور (عشان مينفعش تختار صورة قديمة)
struct CameraView: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraView
        init(_ p: CameraView) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onImage(img) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
