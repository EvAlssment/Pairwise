import SwiftUI
@preconcurrency import LiveKit

enum CameraGalleryLayout: String, CaseIterable, Identifiable {
    case spotlight
    case grid
    static let preferenceKey = "cameraGalleryLayout.v1"

    var id: String { rawValue }
}

enum CameraGalleryFocus {
    static func primaryIdentity(feedIdentities: [String], speakingIdentities: Set<String>, pinnedIdentity: String?) -> String? {
        if let pinnedIdentity, feedIdentities.contains(pinnedIdentity) { return pinnedIdentity }
        return feedIdentities.first(where: speakingIdentities.contains) ?? feedIdentities.first
    }
}

struct CameraGalleryFocusTracker {
    static let speakerSwitchDelay: TimeInterval = 0.65

    private(set) var focusedIdentity: String?
    private var pendingIdentity: String?
    private var pendingSince: TimeInterval?

    var hasPendingSpeakerSwitch: Bool { pendingIdentity != nil }

    mutating func update(feedIdentities: [String], speakingIdentities: Set<String>,
                         pinnedIdentity: String?, now: TimeInterval) -> String? {
        if let pinnedIdentity, feedIdentities.contains(pinnedIdentity) {
            focusedIdentity = pinnedIdentity
            clearPendingSwitch()
            return pinnedIdentity
        }

        if let focusedIdentity, !feedIdentities.contains(focusedIdentity) {
            self.focusedIdentity = nil
        }
        guard let focusedIdentity else {
            let initial = feedIdentities.first(where: speakingIdentities.contains) ?? feedIdentities.first
            self.focusedIdentity = initial
            clearPendingSwitch()
            return initial
        }

        guard !speakingIdentities.contains(focusedIdentity),
              let candidate = feedIdentities.first(where: speakingIdentities.contains),
              candidate != focusedIdentity else {
            clearPendingSwitch()
            return focusedIdentity
        }

        if pendingIdentity == candidate, let pendingSince {
            guard now - pendingSince >= Self.speakerSwitchDelay else { return focusedIdentity }
            self.focusedIdentity = candidate
            clearPendingSwitch()
            return candidate
        }
        pendingIdentity = candidate
        pendingSince = now
        return focusedIdentity
    }

    private mutating func clearPendingSwitch() {
        pendingIdentity = nil
        pendingSince = nil
    }
}

struct CameraStrip: View {
    let feeds: [CameraFeed]
    let onExpand: () -> Void

    var body: some View {
        if !feeds.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("VIDEO · \(feeds.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                    Spacer()
                    Button(action: onExpand) {
                        Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .help("Open camera video in a larger window")
                    .accessibilityLabel("Expand camera video")
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(feeds) { feed in
                            CameraFeedTile(feed: feed).id(ObjectIdentifier(feed.track))
                        }
                    }
                    .padding(.horizontal, 1)
                }
                .frame(height: 108)
            }
            .accessibilityLabel("Camera video from people on this call")
        }
    }
}

struct CameraGalleryView: View {
    @ObservedObject var rtc: RTCService

    private let columns = [GridItem(.adaptive(minimum: 340), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Camera view").font(.title2.bold())
                    Text("Live video from people on this call")
                        .font(.callout).foregroundStyle(Theme.textMuted)
                }
                Spacer()
                Text("\(rtc.cameraFeeds.count) \(rtc.cameraFeeds.count == 1 ? "camera" : "cameras")")
                    .font(.callout.monospacedDigit()).foregroundStyle(Theme.textMuted)
            }

            if rtc.cameraFeeds.isEmpty {
                ContentUnavailableView("No cameras are on", systemImage: "video.slash",
                                       description: Text("Turn on a camera from the call controls to show video here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(rtc.cameraFeeds) { feed in
                            CameraGalleryCard(feed: feed).id(ObjectIdentifier(feed.track))
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        .padding(22)
        .background(Theme.surface)
        .frame(minWidth: 700, minHeight: 480)
    }
}

private struct CameraGalleryCard: View {
    let feed: CameraFeed

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                Color.black
                SwiftUIVideoView(feed.track,
                                 layoutMode: .fill,
                                 mirrorMode: feed.isLocal ? .mirror : .off)
                LinearGradient(colors: [.clear, .black.opacity(0.68)], startPoint: .center, endPoint: .bottom)
                Label(feed.isLocal ? "\(feed.name) · You" : feed.name,
                      systemImage: feed.isLocal ? "person.crop.rectangle" : "person.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(12)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.1), lineWidth: 1))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Camera from \(feed.name)\(feed.isLocal ? ", you" : "")")
    }
}

private struct CameraFeedTile: View {
    let feed: CameraFeed
    var expanded = false
    var tileWidth: CGFloat = 112
    let rtc: RTCService?
    @StateObject private var observer: TrackDelegateObserver

    init(feed: CameraFeed, expanded: Bool = false, tileWidth: CGFloat = 112, rtc: RTCService? = nil) {
        self.feed = feed
        self.expanded = expanded
        self.tileWidth = tileWidth
        self.rtc = rtc
        _observer = StateObject(wrappedValue: TrackDelegateObserver(track: feed.track))
    }

    private var metrics: CameraVideoMetrics {
        guard let statistics = observer.statistics else { return CameraVideoMetrics() }
        if feed.isLocal {
            let video = statistics.outboundRtpStream.first(where: { $0.kind == "video" })
                ?? statistics.outboundRtpStream.first
            return CameraVideoMetrics(width: video?.frameWidth, height: video?.frameHeight,
                                      framesPerSecond: video?.framesPerSecond)
        }
        let video = statistics.inboundRtpStream.first(where: { $0.kind == "video" })
            ?? statistics.inboundRtpStream.first
        return CameraVideoMetrics(width: video?.frameWidth, height: video?.frameHeight,
                                  framesPerSecond: video?.framesPerSecond)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if expanded {
                SwiftUIVideoView(feed.track,
                                 layoutMode: .fit,
                                 mirrorMode: feed.isLocal ? .mirror : .off)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(metrics.aspectRatio, contentMode: .fit)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                SwiftUIVideoView(feed.track,
                                 layoutMode: .fit,
                                 mirrorMode: feed.isLocal ? .mirror : .off)
                    .frame(width: tileWidth, height: tileWidth * 9 / 16)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 6) {
                Text(feed.isLocal ? "\(feed.name) · You" : feed.name)
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                if feed.isHandRaised {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel("\(feed.name) has raised their hand")
                }
                if let rtc, !feed.isLocal {
                    ParticipantAudioVolumeMenu(identity: feed.identity, name: feed.name, rtc: rtc)
                }
                Spacer(minLength: 0)
                if feed.isSpeaking && (expanded || tileWidth > 112) {
                    Label("Speaking", systemImage: "waveform")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.online)
                        .accessibilityLabel("\(feed.name) is speaking")
                }
            }
            .frame(maxWidth: expanded ? .infinity : tileWidth, alignment: .leading)
            Text(metrics.summary)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .frame(maxWidth: expanded ? .infinity : tileWidth, alignment: .leading)
                .accessibilityLabel("Camera video quality: \(metrics.summary)")
        }
        .frame(maxWidth: expanded ? .infinity : nil, alignment: .leading)
        .help("\(feed.isLocal ? "Your camera" : "\(feed.name)'s camera") · \(metrics.summary)")
    }
}
