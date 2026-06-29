import SwiftUI
import PhotosUI
import UIKit

// Image source helpers for the food-capture flows (spec §7.3): take a fresh
// photo with the camera, or pick one from the library. Both yield a UIImage that
// the caller downscales + encodes (ImageEncoding) before any backend call (§13).

/// UIImagePickerController wrapper for live camera capture (PhotosPicker has no
/// camera source on iOS). Returns a single UIImage or nil on cancel.
struct CameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    var onImage: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.onImage(info[.originalImage] as? UIImage)
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onImage(nil)
            parent.dismiss()
        }
    }
}

/// Source chooser shown before any capture: Take photo (camera, if available) or
/// Choose from library (PhotosPicker). Emits the selected UIImage to `onImage`.
struct ImageSourcePicker: View {
    var prompt: String
    var onImage: (UIImage) -> Void

    @State private var showCamera = false
    @State private var pickerItem: PhotosPickerItem?

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer(minLength: 0)
            VStack(spacing: Theme.Spacing.ml) {
                ZStack {
                    Circle()
                        .fill(Theme.accentTeal.opacity(0.12))
                        .frame(width: 116, height: 116)
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 52, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Theme.accentGradient)
                }
                .accessibilityHidden(true)
                VStack(spacing: Theme.Spacing.s) {
                    Text(prompt)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text("Take a photo or pick one from your library.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            VStack(spacing: Theme.Spacing.sm) {
                if cameraAvailable {
                    Button {
                        Haptics.tap()
                        showCamera = true
                    } label: {
                        Label("Take photo", systemImage: "camera.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityHint("Opens the camera")
                }
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("Choose from library", systemImage: "photo.on.rectangle")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: Theme.minTapTarget)
                }
                .buttonStyle(.bordered)
                .tint(Theme.accentTeal)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let image { onImage(image) }
            }
            .ignoresSafeArea()
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    onImage(image)
                }
                pickerItem = nil
            }
        }
    }
}
