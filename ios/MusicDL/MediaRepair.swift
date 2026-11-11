import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

struct MediaRepairCheck: Identifiable {
    enum Status: Equatable { case normal, attention, unavailable }
    let id: String
    let title: String
    let detail: String
    let status: Status
}

struct MediaRepairReport {
    var checks: [MediaRepairCheck] = []
    var findings: [String] = []
    var repairs: [String] = []
    var errors: [String] = []
    var limitations: [String] = [
        "灵动岛的显示时机和过渡动画由 iOS 控制，本功能不能强制隐藏、上岛或改变系统动画。",
        "音频激活仅报告本 App 的调用与中断记录；兼容的 iOS 公开接口不提供通用的实时激活状态查询。",
        "仅检查本 App 持有的会话和指令注册，无法枚举系统或其他 App 的会话、指令处理器。",
        "当前版本未接入 Live Activity，没有可按类型查询的活动；不会尝试结束其他 App 或未知类型的活动。"
    ]
    var summary: String {
        if !errors.isEmpty { return "检测未完成，请重新检测" }
        if !repairs.isEmpty { return "已同步可修复的媒体状态" }
        return "未发现可自动修复的异常"
    }
}

@MainActor
enum MediaMetadataInspection {
    static func staticDifferences(actual: [String: Any]?, expected: [String: Any]) -> [String] {
        let keys = [MPMediaItemPropertyTitle: "歌名", MPMediaItemPropertyArtist: "歌手",
                    MPMediaItemPropertyAlbumTitle: "专辑", MPNowPlayingInfoPropertyExternalContentIdentifier: "歌曲标识",
                    MPNowPlayingInfoPropertyPlaybackQueueIndex: "队列位置", MPNowPlayingInfoPropertyPlaybackQueueCount: "队列数量",
                    MPNowPlayingInfoPropertyDefaultPlaybackRate: "默认速率"]
        var result: [String] = []
        for key in keys.keys.sorted() {
            let expectedValue = expected[key] as? NSObject
            let actualValue = actual?[key] as? NSObject
            if actualValue?.isEqual(expectedValue) != true { result.append(keys[key]!) }
        }
        let wanted = expected[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
        let found = actual?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
        // Without a fetched reference, a system/embedded cover is unknown,
        // not proven incorrect. Never discard it just because loading lags.
        if wanted != nil && !artworkMatches(found, wanted) { result.append("封面") }
        return result
    }

    static func systemDifferences(actual: [String: Any]?, expected: [String: Any],
                                  duration: Double, elapsed: Double, rate: Float, checkPausedPosition: Bool) -> [String] {
        var result = staticDifferences(actual: actual, expected: expected)
        func number(_ key: String) -> Double? {
            guard let value = (actual?[key] as? NSNumber)?.doubleValue, value.isFinite else { return nil }
            return value
        }
        if duration.isFinite && duration > 0 {
            if number(MPMediaItemPropertyPlaybackDuration).map({ abs($0 - duration) < 0.5 }) != true { result.append("播放时长") }
        }
        if number(MPNowPlayingInfoPropertyPlaybackRate).map({ abs($0 - Double(rate)) < 0.01 }) != true { result.append("播放速率") }
        if elapsed.isFinite {
            if let base = number(MPNowPlayingInfoPropertyElapsedPlaybackTime), base >= 0,
               (!duration.isFinite || duration <= 0 || base <= duration + 1) {
                // While playing, this dictionary may contain a clock anchor.
                // iOS extrapolates it; a stale-looking anchor is not drift.
                if checkPausedPosition && abs(base - elapsed) > 1 { result.append("暂停进度") }
            } else { result.append("进度基准") }
        }
        return result
    }

    private static func artworkMatches(_ a: MPMediaItemArtwork?, _ b: MPMediaItemArtwork?) -> Bool {
        if a == nil && b == nil { return true }
        guard let a, let b else { return false }
        if a === b { return true }
        let size = CGSize(width: 48, height: 48)
        guard let first = a.image(at: size), let second = b.image(at: size) else { return false }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        func pixels(_ image: UIImage) -> Data {
            renderer.pngData { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        }
        return pixels(first) == pixels(second)
    }
}

struct MediaRepairLink: View {
    var body: some View {
        NavigationLink { MediaRepairScreen() } label: {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("灵动岛修复")
                    Text("检测并重新同步系统音乐播放状态。").font(.caption).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: "waveform.badge.magnifyingglass") }
        }.accessibilityIdentifier("media-repair-settings")
    }
}

struct MediaRepairScreen: View {
    @EnvironmentObject private var audio: AudioEngine
    @Environment(\.musicAccent) private var accent
    var body: some View {
        Form {
            Section {
                Label("检测并重新同步系统音乐播放状态。", systemImage: "waveform.path").foregroundStyle(accent)
                Text("保留当前歌曲、播放进度和队列。仅修复能确认的媒体信息与控制指令异常。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("灵动岛的显示时机与系统动画由 iOS 控制。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button { Task { await audio.detectAndRepairMediaState() } } label: {
                    HStack {
                        if audio.isRepairingMedia { ProgressView() }
                        Text(audio.isRepairingMedia ? "正在检测…" : audio.mediaRepairReport == nil ? "开始检测并修复" : "重新检测并修复")
                    }.frame(maxWidth: .infinity).padding(.vertical, 5)
                }.buttonStyle(.borderedProminent).foregroundStyle(MusicDesign.onAccent)
                    .disabled(audio.isRepairingMedia).accessibilityIdentifier("media-repair-start")
            }
            if let report = audio.mediaRepairReport {
                Section("检测结果") {
                    Text(report.summary).font(.headline).accessibilityIdentifier("media-repair-summary")
                    ForEach(report.checks) { check in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(check.title, systemImage: check.status == .normal ? "checkmark.circle" : check.status == .attention ? "exclamationmark.circle" : "info.circle")
                            Text(check.detail).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 3).accessibilityIdentifier("media-check-" + check.id)
                    }
                }
                if !report.findings.isEmpty { resultSection("发现的问题", values: report.findings) }
                if !report.repairs.isEmpty { resultSection("已执行的修复", values: report.repairs) }
                if !report.errors.isEmpty { resultSection("未能完成的项目", values: report.errors) }
                resultSection("仍存在的限制", values: report.limitations)
                Section { Text("检测过程已记录到 Diagnostics/media-session.jsonl，不记录歌名、播放地址或账号凭证。")
                    .font(.caption).foregroundStyle(.secondary) }
            }
        }.navigationTitle("灵动岛修复").navigationBarTitleDisplayMode(.inline)
    }
    private func resultSection(_ title: String, values: [String]) -> some View {
        Section(title) { ForEach(Array(values.enumerated()), id: \.offset) { _, value in Text(value).font(.subheadline) } }
    }
}
