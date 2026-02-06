import AVFoundation
import AudioToolbox

class AudioService: ObservableObject {
    static let shared = AudioService()
    
    @Published var isBeepEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isBeepEnabled, forKey: "beepEnabled")
        }
    }
    
    private var audioPlayer: AVAudioPlayer?
    
    private init() {
        // Set default value if not set
        if UserDefaults.standard.object(forKey: "beepEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "beepEnabled")
        }
        isBeepEnabled = UserDefaults.standard.bool(forKey: "beepEnabled")
    }
    
    func playBeep() {
        guard isBeepEnabled else { return }
        
        // Generate a simple beep tone programmatically
        AudioServicesPlaySystemSound(1054) // System beep sound
    }
}
