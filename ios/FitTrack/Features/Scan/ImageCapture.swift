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
        VStack(spacing: Theme.Spacing.l) {
            EmptyStateView(systemImage: "camera.viewfinder", title: prompt,
                           message: "Take a photo or pick one from your library.")
            VStack(spacing: Theme.Spacing.m) {
                if cameraAvailable {
                    Button {
                        showCamera = true
                    } label: {
                        Label("Take photo", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accentTeal)
                }
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("Choose from library", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, Theme.Spacing.xl)
        }
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
