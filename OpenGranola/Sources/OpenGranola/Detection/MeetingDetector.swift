import CoreAudio
import Observation

/// Detects when another app activates the microphone, indicating a meeting is in progress.
/// Uses polling (every 2s) because `AudioObjectAddPropertyListenerBlock` for
/// `kAudioDevicePropertyDeviceIsRunningSomewhere` doesn't reliably fire in SwiftUI apps.
@Observable
@MainActor
final class MeetingDetector {
    private(set) var isMeetingDetected = false
    private(set) var isDismissed = false

    private var pollTask: Task<Void, Never>?
    private var isMonitoring = false
    private var lastMicRunning = false

    /// External check — when true, mic activation is ignored (it's our own capture).
    var isRecording: () -> Bool = { false }

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        diagLog("[MEETING-DETECTOR] startMonitoring")
        startPolling()
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        pollTask?.cancel()
        pollTask = nil
        isMeetingDetected = false
        isDismissed = false
        lastMicRunning = false
    }

    func dismiss() {
        isDismissed = true
        isMeetingDetected = false
    }

    func acknowledgeRecordingStarted() {
        isMeetingDetected = false
        isDismissed = true
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.pollMicState()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func pollMicState() {
        let deviceID = Self.defaultInputDeviceID()
        let running = Self.isMicRunning(deviceID: deviceID)

        // Only act on state transitions
        guard running != lastMicRunning else { return }
        lastMicRunning = running

        diagLog("[MEETING-DETECTOR] mic state changed: running=\(running), isRecording=\(isRecording()), isDismissed=\(isDismissed)")

        if running {
            // Ignore if we're already recording (our own capture triggered this)
            guard !isRecording() else {
                diagLog("[MEETING-DETECTOR] Ignoring — app is already recording")
                return
            }
            if !isDismissed {
                diagLog("[MEETING-DETECTOR] Meeting detected!")
                isMeetingDetected = true
            }
        } else {
            // Mic released — reset dismissal so a new activation triggers a fresh popup
            isMeetingDetected = false
            isDismissed = false
        }
    }

    // MARK: - CoreAudio Helpers

    private static func defaultInputDeviceID() -> AudioDeviceID {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        return deviceID
    }

    private static func isMicRunning(deviceID: AudioDeviceID) -> Bool {
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isRunning)
        return status == noErr && isRunning != 0
    }
}
