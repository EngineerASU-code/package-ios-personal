import CoreLocation
import MapKit
import SwiftUI
import WeatherKit

fileprivate struct WeatherCity: Codable, Equatable, Identifiable {
    let title: String
    let latitude: Double
    let longitude: Double

    var id: String { title }
    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }

    init?(_ result: MKMapItem) {
        let placemark = result.placemark
        guard let locality = placemark.locality, placemark.thoroughfare == nil,
              CLLocationCoordinate2DIsValid(placemark.coordinate) else { return nil }
        let parts = [locality, placemark.administrativeArea, placemark.country].compactMap { $0 }
        title = parts.reduce(into: [String]()) { labels, part in
            if !labels.contains(part) { labels.append(part) }
        }.joined(separator: ", ")
        latitude = placemark.coordinate.latitude
        longitude = placemark.coordinate.longitude
    }
}

@MainActor
final class CompanionWeatherModel: ObservableObject {
    @Published fileprivate private(set) var city: WeatherCity?
    @Published fileprivate private(set) var status: Status = .idle

    fileprivate enum Status {
        case idle, loading, updated, unavailable, storageError
    }

    private let defaults = UserDefaults.standard
    private let cityKey = "companionWeatherCity"
    private let clearKey = "companionWeatherClearPending"
    private var request: Task<Void, Never>?

    var isEnabled: Bool { city != nil }

    init() {
        if let data = defaults.data(forKey: cityKey) {
            city = try? JSONDecoder().decode(WeatherCity.self, from: data)
        }
    }

    fileprivate func enable(_ city: WeatherCity, persist: @escaping (SceneWeather?) -> Bool) {
        guard self.city == nil, let data = try? JSONEncoder().encode(city) else { return }
        if defaults.bool(forKey: clearKey), !persist(nil) {
            status = .storageError
            return
        }
        defaults.removeObject(forKey: clearKey)
        defaults.set(data, forKey: cityKey)
        self.city = city
        refreshIfNeeded(nil, persist: persist)
    }

    fileprivate func disable(persist: (SceneWeather?) -> Bool) {
        forgetCity()
        let cleared = persist(nil)
        defaults.set(!cleared, forKey: clearKey)
        status = cleared ? .idle : .storageError
    }

    func forgetCity() {
        cancelRequest()
        defaults.removeObject(forKey: cityKey)
        defaults.removeObject(forKey: clearKey)
        city = nil
        status = .idle
    }

    func cancelRequest() {
        request?.cancel()
        request = nil
        if status == .loading { status = .idle }
    }

    func refreshIfNeeded(_ snapshot: SceneWeather?, persist: @escaping (SceneWeather?) -> Bool) {
        guard let city else {
            if defaults.bool(forKey: clearKey) {
                let cleared = persist(nil)
                defaults.set(!cleared, forKey: clearKey)
                status = cleared ? .idle : .storageError
            }
            return
        }
        guard request == nil else { return }
        if snapshot?.isFresh(at: Date()) == true {
            status = .updated
            return
        }
        status = .loading
        request = Task { [weak self] in
            do {
                let conditions = try await WeatherService.shared.weather(for: city.location, including: .current)
                guard let self, !Task.isCancelled else { return }
                self.request = nil
                let snapshot = SceneWeather(isSunny: conditions.isDaylight && conditions.condition == .clear,
                                            observedAt: conditions.date)
                guard snapshot.isFresh(at: Date()) else {
                    self.status = .unavailable
                    return
                }
                self.status = persist(snapshot) ? .updated : .storageError
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.request = nil
                self.status = .unavailable
            }
        }
    }
}

struct CompanionWeatherSettings: View {
    @ObservedObject var model: CompanionWeatherModel
    let persist: (SceneWeather?) -> Bool
    @State private var query = ""
    @State private var cities: [WeatherCity] = []
    @State private var choice: WeatherCity?
    @State private var activeSearch: MKLocalSearch?
    @State private var searchMessage = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        Form {
            Section {
                LabeledContent("Эмоции героя", value: "Авто")
                    .accessibilityIdentifier("weather-automatic-emotions")
                Text(model.city == nil ? "Погода выключена" : "Погода включена")
                    .accessibilityIdentifier("weather-status")
                if let city = model.city {
                    LabeledContent("Город", value: city.title)
                        .privacySensitive()
                    Button("Выключить погоду") { model.disable(persist: persist) }
                }
            } footer: {
                Text("Герой реагирует на время суток и ваши действия. С вашего согласия он также может порадоваться ясному дню.")
            }
            if model.city == nil {
                Section {
                    TextField("Город", text: $query)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .onSubmit(search)
                        .accessibilityIdentifier("weather-city-query")
                    Button("Найти город", action: search)
                        .disabled(searchQuery.isEmpty || activeSearch != nil)
                        .accessibilityIdentifier("weather-city-search")
                    if activeSearch != nil { ProgressView("Поиск города…") }
                    if !searchMessage.isEmpty { Text(searchMessage) }
                    ForEach(cities) { city in
                        Button {
                            choice = city
                        } label: {
                            HStack {
                                Text(city.title)
                                Spacer()
                                if choice == city { Image(systemName: "checkmark") }
                            }
                        }
                        .accessibilityAddTraits(choice == city ? .isSelected : [])
                    }
                    if let choice {
                        Button("Использовать погоду") {
                            model.enable(choice, persist: persist)
                            query = ""
                            cities = []
                            self.choice = nil
                        }
                        .accessibilityIdentifier("weather-enable")
                    }
                } footer: {
                    Text("Поиск отправляет введённое название в службу Apple «Карты». После включения Weather получает координаты выбранного города. Доступ к геопозиции iPhone не запрашивается.")
                }
            } else {
                Section {
                    switch model.status {
                    case .idle: EmptyView()
                    case .loading: ProgressView("Получаем погоду…")
                    case .updated: Text("Погодный контекст обновлён.")
                    case .unavailable: Text("Погода недоступна. Герой продолжит реагировать как обычно.")
                    case .storageError: Text("Не удалось сохранить погодный контекст.")
                    }
                } footer: {
                    Text("Источник: Weather. Данные Apple преобразованы в сигнал для эмоций героя.")
                }
            }
            if model.city == nil && model.status == .storageError {
                Text("Не удалось очистить сохранённый погодный контекст. Повторим при следующем открытии приложения.")
            }
        }
        .navigationTitle("Погода и эмоции")
        .onDisappear {
            activeSearch?.cancel()
            activeSearch = nil
        }
        .onChange(of: query) {
            activeSearch?.cancel()
            activeSearch = nil
            cities = []
            choice = nil
            searchMessage = ""
        }
    }

    private var searchQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func search() {
        guard !searchQuery.isEmpty, activeSearch == nil else { return }
        searchFocused = false
        searchMessage = ""
        cities = []
        choice = nil
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchQuery
        request.resultTypes = .address
        let operation = MKLocalSearch(request: request)
        activeSearch = operation
        Task { @MainActor in
            do {
                let response = try await operation.start()
                guard activeSearch === operation else { return }
                var seen = Set<String>()
                cities = response.mapItems.compactMap(WeatherCity.init).filter { seen.insert($0.id).inserted }
                if cities.isEmpty { searchMessage = "Город не найден. Уточните название." }
            } catch {
                guard activeSearch === operation else { return }
                searchMessage = "Не удалось найти город. Проверьте интернет и повторите поиск."
            }
            activeSearch = nil
        }
    }
}
