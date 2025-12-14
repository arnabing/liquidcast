import SwiftUI

/// Overlay displayed during media conversion
struct ConversionOverlayView: View {
    let progress: Double
    let status: String
    let fileName: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            // Icon
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.white.opacity(0.8))
                .rotationEffect(.degrees(progress * 360))
                .animation(.linear(duration: 2).repeatForever(autoreverses: false), value: progress > 0)

            // Title
            Text("Converting for AirPlay")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.white)

            // File name
            Text(fileName)
                .font(.caption)
                .foregroundColor(.white.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal)

            // Progress bar
            VStack(spacing: 8) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // Background
                        Capsule()
                            .fill(.white.opacity(0.2))

                        // Progress fill
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.blue, .purple],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geometry.size.width * CGFloat(progress))
                            .animation(.easeInOut(duration: 0.3), value: progress)
                    }
                }
                .frame(height: 6)
                .padding(.horizontal, 32)

                // Status text
                Text(status)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            }

            // Cancel button
            Button(action: onCancel) {
                Text("Cancel")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .stroke(.white.opacity(0.3), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(32)
        .frame(maxWidth: 320)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(.white.opacity(0.2), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
    }
}

/// Error overlay when conversion fails
struct ConversionErrorView: View {
    let errorMessage: String
    let onDismiss: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            // Icon
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.orange)

            // Title
            Text("Conversion Failed")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.white)

            // Error message
            Text(errorMessage)
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            // Buttons
            HStack(spacing: 16) {
                Button(action: onDismiss) {
                    Text("Dismiss")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .stroke(.white.opacity(0.3), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button(action: onRetry) {
                    Text("Retry")
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(.blue)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(32)
        .frame(maxWidth: 320)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(.white.opacity(0.2), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
    }
}

#Preview("Converting") {
    ZStack {
        Color.black.ignoresSafeArea()

        ConversionOverlayView(
            progress: 0.45,
            status: "Converting... 45%",
            fileName: "Jurassic.World.2025.4K.mkv",
            onCancel: {}
        )
    }
}

#Preview("Error") {
    ZStack {
        Color.black.ignoresSafeArea()

        ConversionErrorView(
            errorMessage: "FFmpeg not found. Please install it with: brew install ffmpeg",
            onDismiss: {},
            onRetry: {}
        )
    }
}
