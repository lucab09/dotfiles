import CoreLocation
import Foundation

/// Helper eseguito come .app minimale (LSUIElement) e lanciato via `open`:
/// scrive `{"lat":..,"lon":..}` nel file di cache usando la posizione reale
/// del Mac (CoreLocation), poi esce. Deve essere una vera app lanciata da
/// LaunchServices — un binario nudo eseguito da uno script eredita il
/// processo "responsabile" TCC di chi lo ha avviato e non fa mai comparire
/// il prompt di autorizzazione. weather.sh legge il file di cache dopo
/// aver atteso l'uscita del processo (`open -W`), perché `open` non
/// inoltra lo stdout dell'app lanciata al chiamante.
let cacheURL = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Caches/sketchybar-geolocation.json")

final class LocationFetcher: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var didFinish = false

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorized:
            manager.startUpdatingLocation()
        default:
            finish(nil)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorized:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            finish(nil)
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }

    private func finish(_ location: CLLocation?) {
        guard !didFinish else { return }
        didFinish = true
        manager.stopUpdatingLocation()

        if let location {
            let json = "{\"lat\":\(location.coordinate.latitude),\"lon\":\(location.coordinate.longitude)}"
            try? json.write(to: cacheURL, atomically: true, encoding: .utf8)
            exit(0)
        } else {
            exit(1)
        }
    }
}

let fetcher = LocationFetcher()
fetcher.start()

DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
    exit(1)
}

RunLoop.main.run(until: Date(timeIntervalSinceNow: 9))
exit(1)
