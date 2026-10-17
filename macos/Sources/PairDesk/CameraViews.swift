import SwiftUI
@preconcurrency import LiveKit

struct CameraStrip: View {
    let feeds: [CameraFeed]

    var body: some View {
        if !feeds.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(feeds) { feed in
                        VStack(alignment: .leading, spacing: 4) {
                            SwiftUIVideoView(feed.track,
                                             layoutMode: .fill,
                                             mirrorMode: feed.isLocal ? .mirror : .off)
                                .frame(width: 112, height: 68)
                                .background(.black)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text(feed.isLocal ? "\(feed.name) · You" : feed.name)
                                .font(.caption2)
                                .foregroundStyle(Theme.textMuted)
                                .lineLimit(1)
                                .frame(width: 112, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 1)
            }
            .frame(height: 90)
            .accessibilityLabel("Camera video from people on this call")
        }
    }
}
