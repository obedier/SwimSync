import SwiftUI
import AVFoundation

/// Turns a text file into a spoken MP3 and drops it in the queue.
struct SpeechView: View {
    let document: TextDocument

    @EnvironmentObject var speech: SpeechMaker
    @EnvironmentObject var library: MobileLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var voiceID = ""
    @State private var rate: Float = 0.52
    @State private var voices: [AVSpeechSynthesisVoice] = []

    private var selectedVoice: AVSpeechSynthesisVoice? {
        voices.first { $0.identifier == voiceID } ?? voices.first
    }

    /// ~150 words a minute at the default rate, scaled by the slider.
    private var estimatedMinutes: Int {
        let words = document.text.split(whereSeparator: \.isWhitespace).count
        let perMinute = 150.0 * Double(rate) / Double(AVSpeechUtteranceDefaultSpeechRate)
        return max(1, Int((Double(words) / perMinute).rounded(.up)))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    preview
                    settings
                    if speech.isRunning { running }
                }
                .padding(16)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Read aloud")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        speech.cancel()
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { createBar }
        }
        .interactiveDismissDisabled(speech.isRunning)
        .onAppear {
            title = document.suggestedTitle
            voices = SpeechSynthesis.voices()
            voiceID = voices.first?.identifier ?? ""
        }
        .alert("Something went wrong", isPresented: problemBinding) {
            Button("OK") { speech.problem = nil }
        } message: {
            Text(speech.problem ?? "")
        }
    }

    private var problemBinding: Binding<Bool> {
        Binding(get: { speech.problem != nil }, set: { if !$0 { speech.problem = nil } })
    }

    // MARK: - Sections

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: document.name, tint: Theme.library)
            Text(document.text.prefix(400) + (document.text.count > 400 ? "…" : ""))
                .font(.system(size: 13))
                .foregroundStyle(Theme.textDim)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(document.text.count.formatted()) characters · about \(estimatedMinutes) min spoken")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textFaint)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "Recording")

            VStack(alignment: .leading, spacing: 4) {
                Text("Title").font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text)
                    .padding(10)
                    .background(Theme.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous))
                Text("Becomes the filename on the player.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Voice").font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
                Picker("Voice", selection: $voiceID) {
                    ForEach(voices, id: \.identifier) { voice in
                        Text("\(voice.name) · \(SpeechSynthesis.qualityLabel(voice))").tag(voice.identifier)
                    }
                }
                .pickerStyle(.menu)
                .tint(Theme.text)
                Text("Premium and Enhanced voices sound far more natural. Download them in Settings → Accessibility → Spoken Content → Voices.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Speed").font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
                    Spacer()
                    Text(String(format: "%.0f%%", Double(rate / AVSpeechUtteranceDefaultSpeechRate) * 100))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textFaint)
                }
                Slider(value: $rate, in: 0.35...0.7)
                    .tint(Theme.accent)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
        .disabled(speech.isRunning)
        .opacity(speech.isRunning ? 0.6 : 1)
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recording…")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text("\(Int((speech.progress ?? 0) * 100))%")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.accent)
            }
            ProgressView(value: speech.progress ?? 0)
                .tint(Theme.accent)
            Text("Keep SwimSync open. The voice runs on this iPhone, so nothing is uploaded.")
                .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private var createBar: some View {
        VStack(spacing: 8) {
            if speech.isRunning {
                Button("Stop") { speech.cancel() }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.warn)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Theme.warn.opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
            } else {
                Button(action: create) {
                    Text("Create MP3 and queue it")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.88))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
                }
                .disabled(document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
    }

    private func create() {
        let voice = selectedVoice
        let text = document.text
        let name = title
        let speed = rate
        Task {
            if let url = await speech.render(text: text, title: name, voice: voice, rate: speed) {
                library.add([url])
                dismiss()
            }
        }
    }
}
