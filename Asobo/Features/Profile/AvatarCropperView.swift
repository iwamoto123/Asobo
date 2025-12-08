import SwiftUI

private struct CropCircleAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

struct AvatarCropperView: View {
    let image: UIImage
    var onCancel: () -> Void
    var onCrop: (UIImage) -> Void
    
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 4
    private let outputSize: CGFloat = 600 // 600x600の出力（十分な解像度で保存）
    private let overlayNudgeY: CGFloat = -2 // 黒マスクの円を微調整（上へ）
    
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let cropSize = min(geometry.size.width, geometry.size.height) * 0.75
                let baseScale = baseScale(for: cropSize)
                
                ZStack {
                    Color.black.opacity(0.8).ignoresSafeArea()
                    
                    VStack(spacing: 24) {
                        VStack(spacing: 8) {
                            Text("丸枠に合わせて調整")
                                .font(.headline)
                                .foregroundColor(.white)
                            Text("ピンチで拡大・縮小、ドラッグで位置を調整してください")
                                .font(.footnote)
                                .foregroundColor(.white.opacity(0.8))
                        }
                        
                        ZStack {
                            Color.black
                            
                            Image(uiImage: image)
                                .resizable()
                                .frame(
                                    width: image.size.width * baseScale * scale,
                                    height: image.size.height * baseScale * scale
                                )
                                .offset(offset)
                                // 画像全体にうっすら暗幕を敷く
                                .overlay(
                                    Color.black.opacity(0.2)
                                        .allowsHitTesting(false)
                                )
                                .gesture(
                                    DragGesture()
                                        .onChanged { value in
                                            let proposed = CGSize(
                                                width: lastOffset.width + value.translation.width,
                                                height: lastOffset.height + value.translation.height
                                            )
                                            offset = clampedOffset(proposed, cropSize: cropSize, baseScale: baseScale, scale: scale)
                                        }
                                        .onEnded { _ in
                                            lastOffset = offset
                                        }
                                )
                                .simultaneousGesture(
                                    MagnificationGesture()
                                        .onChanged { value in
                                            let proposedScale = min(max(lastScale * value, minScale), maxScale)
                                            scale = proposedScale
                                            offset = clampedOffset(offset, cropSize: cropSize, baseScale: baseScale, scale: scale)
                                        }
                                        .onEnded { value in
                                            let newScale = min(max(lastScale * value, minScale), maxScale)
                                            lastScale = newScale
                                            scale = newScale
                                            offset = clampedOffset(offset, cropSize: cropSize, baseScale: baseScale, scale: scale)
                                        }
                                )
                        }
                        .frame(width: cropSize, height: cropSize)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                                .frame(width: cropSize, height: cropSize)
                                .allowsHitTesting(false)
                        )
                        .overlay(
                            Circle()
                                .fill(
                                    RadialGradient(
                                        gradient: Gradient(colors: [Color.white.opacity(0.12), Color.clear]),
                                        center: .center,
                                        startRadius: cropSize * 0.1,
                                        endRadius: cropSize * 0.5
                                    )
                                )
                                .frame(width: cropSize, height: cropSize)
                                .allowsHitTesting(false)
                        )
                        .anchorPreference(key: CropCircleAnchorKey.self, value: .bounds) { $0 }
                        
                        HStack(spacing: 16) {
                            Button(role: .cancel) {
                                onCancel()
                            } label: {
                                Text("キャンセル")
                                    .frame(maxWidth: .infinity)
                            }
                            .padding()
                            .background(Color.white.opacity(0.1))
                            .foregroundColor(.white)
                            .cornerRadius(12)
                            
                            Button {
                                if let cropped = croppedImage(cropSize: cropSize, baseScale: baseScale) {
                                    onCrop(cropped)
                                }
                            } label: {
                                Text("この位置で使う")
                                    .fontWeight(.semibold)
                                    .frame(maxWidth: .infinity)
                            }
                            .padding()
                            .background(Color.white)
                            .foregroundColor(.black)
                            .cornerRadius(12)
                        }
                        .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 24)
                }
                .overlayPreferenceValue(CropCircleAnchorKey.self) { anchor in
                    GeometryReader { proxy in
                        if let anchor {
                            let rect = proxy[anchor]
                            Path { path in
                                let fullRect = CGRect(origin: .zero, size: proxy.size)
                                path.addRect(fullRect)
                                path.addEllipse(in: rect.offsetBy(dx: 0, dy: overlayNudgeY))
                            }
                            .fill(Color.black.opacity(0.35), style: FillStyle(eoFill: true))
                            .allowsHitTesting(false)
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { onCancel() }
                        .foregroundColor(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
    
    private func baseScale(for cropSize: CGFloat) -> CGFloat {
        guard image.size.width > 0, image.size.height > 0 else { return 1 }
        return max(cropSize / image.size.width, cropSize / image.size.height)
    }
    
    private func clampedOffset(_ proposed: CGSize, cropSize: CGFloat, baseScale: CGFloat, scale: CGFloat) -> CGSize {
        let effectiveScale = baseScale * scale
        let displayWidth = image.size.width * effectiveScale
        let displayHeight = image.size.height * effectiveScale
        
        let horizontalLimit = max((displayWidth - cropSize) / 2, 0)
        let verticalLimit = max((displayHeight - cropSize) / 2, 0)
        
        let clampedX = min(max(proposed.width, -horizontalLimit), horizontalLimit)
        let clampedY = min(max(proposed.height, -verticalLimit), verticalLimit)
        
        return CGSize(width: clampedX, height: clampedY)
    }
    
    private func croppedImage(cropSize: CGFloat, baseScale: CGFloat) -> UIImage? {
        let normalized = normalize(image: image)
        guard let cgImage = normalized.cgImage else { return nil }
        
        let effectiveScale = baseScale * scale
        let displayWidth = normalized.size.width * effectiveScale
        let displayHeight = normalized.size.height * effectiveScale
        
        // View上の画像の原点
        let originX = (cropSize - displayWidth) / 2 + offset.width
        let originY = (cropSize - displayHeight) / 2 + offset.height
        
        // 画像座標系でのクロップ領域
        let cropOriginX = -originX / effectiveScale
        let cropOriginY = -originY / effectiveScale
        let cropRect = CGRect(
            x: cropOriginX,
            y: cropOriginY,
            width: cropSize / effectiveScale,
            height: cropSize / effectiveScale
        )
        
        let boundedRect = cropRect.intersection(CGRect(origin: .zero, size: normalized.size))
        guard boundedRect.width > 0, boundedRect.height > 0 else { return nil }
        let scaleFactor = normalized.scale
        let pixelRect = CGRect(
            x: boundedRect.origin.x * scaleFactor,
            y: boundedRect.origin.y * scaleFactor,
            width: boundedRect.width * scaleFactor,
            height: boundedRect.height * scaleFactor
        ).integral
        
        guard let croppedCG = cgImage.cropping(to: pixelRect) else { return nil }
        
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: outputSize, height: outputSize))
        let circular = renderer.image { context in
            let rect = CGRect(origin: .zero, size: CGSize(width: outputSize, height: outputSize))
            context.cgContext.addEllipse(in: rect)
            context.cgContext.clip()
            
            UIImage(cgImage: croppedCG).draw(in: rect)
        }
        
        return circular
    }
    
    private func normalize(image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
