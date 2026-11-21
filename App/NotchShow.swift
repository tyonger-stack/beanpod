import SwiftUI

extension NotchPanel {
    enum Show: Equatable {
        case recordingStarted(preview: Bool)
        case recordingEnded(elapsed: TimeInterval, preview: Bool)

        var duration: Double { 2.7 }
    }
}

struct NotchShowView: View {
    @Environment(BeanStore.self) private var store
    let show: NotchPanel.Show
    let notch: CGSize
    let size: CGSize

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notch.height)
            HStack(spacing: 14) {
                DevicePhotoView().frame(width: 74, height: 74).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    switch show {
                    case .recordingStarted(let preview):
                        Label(preview ? "预览 · 正在录音" : store.recState == .paused ? "已暂停" : "正在录音", systemImage: "record.circle")
                            .foregroundStyle(!preview && store.recState == .paused ? Theme.amber : Theme.rec)
                        if preview {
                            Text("00:48").monospacedDigit()
                                .accessibilityLabel("预览时长")
                                .accessibilityValue(spokenDuration(48))
                        } else {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let elapsed = store.elapsed(at: context.date)
                                Text(NotchView.clock(elapsed))
                                    .monospacedDigit()
                                    .accessibilityLabel("已录时长")
                                    .accessibilityValue(spokenDuration(elapsed))
                            }
                        }
                    case .recordingEnded(let elapsed, let preview):
                        Label(preview ? "预览 · 录音已结束" : "录音已结束", systemImage: "stop.circle")
                        Text(NotchView.clock(elapsed)).monospacedDigit()
                            .accessibilityLabel(preview ? "预览时长" : "已录时长")
                            .accessibilityValue(spokenDuration(elapsed))
                    }
                }
                .font(.callout.weight(.medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}
