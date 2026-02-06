import AVFoundation

class AudioService: ObservableObject {
    static let shared = AudioService()
    
    @Published var isBeepEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isBeepEnabled, forKey: "beepEnabled")
        }
    }
    
    private var audioPlayer: AVAudioPlayer?
    
    private init() {
        isBeepEnabled = UserDefaults.standard.bool(forKey: "beepEnabled")
    }
    
    func playBeep() {
        guard isBeepEnabled else { return }
        
        // Generate a simple beep tone programmatically
        AudioServicesPlaySystemSound(1054) // System beep sound
    }
}
