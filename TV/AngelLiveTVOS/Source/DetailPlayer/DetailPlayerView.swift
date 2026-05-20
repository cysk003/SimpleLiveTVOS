//
//  DetailPlayerView.swift
//  SimpleLiveTVOS
//
//  Created by pc on 2023/12/12.
//

import SwiftUI
import AVKit
import AngelLiveDependencies
import AngelLiveCore


struct DetailPlayerView: View {
    
    @StateObject private var playerCoordinator = KSVideoPlayer.Coordinator()
    @State private var didCleanup = false
    @Environment(RoomInfoViewModel.self) var roomInfoViewModel
    @Environment(AppState.self) var appViewModel
    public var didExitView: (Bool, String) -> Void = {_, _ in}
    
    var body: some View {
        if roomInfoViewModel.displayState == .streamerOffline {
            // 主播已下播页面
            VStack(spacing: 30) {
                Image(systemName: "tv.slash")
                    .font(.system(size: 80))
                    .foregroundColor(.gray)
                Text("主播已下播")
                    .font(.title)
                    .foregroundColor(.white)
                Text(roomInfoViewModel.currentRoom.userName)
                    .font(.headline)
                    .foregroundColor(.gray)
                Button("返回") {
                    endPlay()
                }
                .padding(.top, 20)
            }
            .frame(width: 1920, height: 1080)
            .background(.black)
        } else if roomInfoViewModel.hasError, let error = roomInfoViewModel.currentError {
            ErrorView(
                title: error.isAuthRequired ? "播放失败-请登录\(LiveParseTools.getLivePlatformName(roomInfoViewModel.currentRoom.liveType))账号" : "播放失败",
                message: error.liveParseMessage,
                detailMessage: error.liveParseDetail,
                curlCommand: error.liveParseCurl,
                showRetry: true,
                showLoginButton: error.isAuthRequired,
                onDismiss: {
                    endPlay()
                },
                onRetry: {
                    roomInfoViewModel.hasError = false
                    roomInfoViewModel.currentError = nil
                    playerCoordinator.playerLayer?.play()
                }
            )
        } else if roomInfoViewModel.currentPlayURL == nil {
            ZStack {
                KFImage(URL(string: roomInfoViewModel.currentRoom.roomCover))
                    .resizable()
                    .scaledToFill()
                    .frame(width: 1920, height: 1080)
                    .clipped()
                    .blur(radius: 24)
                    .overlay {
                        Color.black.opacity(0.5)
                    }

                VStack(spacing: 14) {
                    ProgressView()
                        .tint(.white)
                    Text("正在解析直播地址")
                }
            }
            .font(.headline)
            .frame(width: 1920, height: 1080)
            .background(.black)
        }else {
            ZStack {
                KSVideoPlayer(coordinator: playerCoordinator, url: roomInfoViewModel.currentPlayURL ?? URL(string: "")!, options: roomInfoViewModel.playerOption)
                    .background(Color.black)
                    .onAppear {
                        playerCoordinator.playerLayer?.play()
                        roomInfoViewModel.setPlayerDelegate(playerCoordinator: playerCoordinator)
                    }
                    .safeAreaPadding(.all)
                    .zIndex(1)

                // 加载/缓冲指示器 - URL 已就绪但尚未开始播放，或播放中缓冲时显示
                if shouldShowStreamLoading {
                    TVStreamLoadingOverlay(
                        title: isInitialStreamLoading ? "正在加载直播流…" : "缓冲中…",
                        speedProvider: { [playerCoordinator] in
                            guard let speed = playerCoordinator.playerLayer?.player.dynamicInfo.networkSpeed else {
                                return nil
                            }
                            return Int64(speed)
                        }
                    )
                    .zIndex(4)
                }

                PlayerControlView(playerCoordinator: playerCoordinator)
                    .zIndex(3)
                    .frame(width: 1920, height: 1080)
//                    .opacity(roomInfoViewModel.showControlView ? 1 : 0)
                    .safeAreaPadding(.all)
                    .environment(roomInfoViewModel)
                    .environment(appViewModel)
                if roomInfoViewModel.supportsDanmu {
                    VStack {
                        if appViewModel.danmuSettingsViewModel.danmuAreaIndex >= 3 {
                            Spacer()
                        }
                        DanmuView(coordinator: roomInfoViewModel.danmuCoordinator, height: appViewModel.danmuSettingsViewModel.getDanmuArea().0)
                            .frame(width: 1920, height: appViewModel.danmuSettingsViewModel.getDanmuArea().0)
                            .opacity(appViewModel.danmuSettingsViewModel.showDanmu ? 1 : 0)
                            .environment(appViewModel)
                        if appViewModel.danmuSettingsViewModel.danmuAreaIndex < 3 {
                            Spacer()
                        }
                    }
                    .zIndex(2)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: SimpleLiveNotificationNames.playerEndPlay)) { _ in
                endPlay()
            }
            .onDisappear {
                cleanupPlayer()
            }
            .onPlayPauseCommand {
                roomInfoViewModel.togglePlayPause()
            }
            .frame(width: 1920, height: 1080)
        }
    }
    
    @MainActor func endPlay() {
        cleanupPlayer()
        didExitView(false, "")
    }

    @MainActor
    private func cleanupPlayer() {
        guard !didCleanup else { return }
        didCleanup = true
        playerCoordinator.resetPlayer()
        roomInfoViewModel.disConnectSocket()
    }

    /// 是否应展示加载层（缓冲或初次加载）。
    private var shouldShowStreamLoading: Bool {
        let state = playerCoordinator.state
        if state == .buffering { return true }
        if playerCoordinator.playerLayer?.player.playbackState == .seeking { return true }
        return isInitialStreamLoading
    }

    /// 流首次加载（URL 已就绪但未开始播放）。
    /// 注意：.readyToPlay 是「准备好可以播」而非「已在播」，KSPlayer 此时尚未渲染帧。
    /// 不能用 isPlaying 二次过滤，否则 .readyToPlay 与 .buffering 之间会闪一帧黑。
    private var isInitialStreamLoading: Bool {
        switch playerCoordinator.state {
        case .initialized, .preparing, .readyToPlay:
            return true
        default:
            return false
        }
    }
}

// MARK: - 直播加载指示

/// tvOS 直播流加载层：菊花 + 标题 + 实时网速。
struct TVStreamLoadingOverlay: View {
    let title: String
    let speedProvider: () -> Int64?

    @State private var bytesPerSecond: Int64 = 0
    @State private var hasSpeed: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(2.0)
                .tint(.white)
            Text(title)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.white)
            Text(hasSpeed ? Self.formatSpeed(bytesPerSecond) : "正在测速…")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.75))
                .monospacedDigit()
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 32)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .task {
            // KSPlayer 的 dynamicInfo.networkSpeed 仅在播放推进时（~1.5s 一次）更新，
            // 初次加载阶段会一直停留在 0 → 只在拿到正数后再点亮，避免恒显 0 KB/s 的误导。
            while !Task.isCancelled {
                if let speed = speedProvider(), speed > 0 {
                    bytesPerSecond = speed
                    hasSpeed = true
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private static func formatSpeed(_ bytesPerSecond: Int64) -> String {
        let bps = max(bytesPerSecond, 0)
        let kb = Double(bps) / 1024.0
        if kb < 1024 {
            return String(format: "%.0f KB/s", kb)
        }
        return String(format: "%.1f MB/s", kb / 1024.0)
    }
}
