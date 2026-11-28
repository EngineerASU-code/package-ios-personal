# Решение о TestFlight · 27 ноября 2026

**Статус HOLD.** Версия проекта 0.1 (1), iPhone, iOS 17+. Проверены настройки Release рабочего дерева на базе `e2ce9dd382344c3b6ea558f8b3535aa0fc9090a6` (ветка main). Источники app и extension, общая группа, встраивание extension и оба privacy manifest присутствуют в проекте. Store обращается к атрибутам файла внутри App Group при ошибке открытия SQLite, что соответствует заявленной причине C617.1. Подписанный архив и номер принятой сборки App Store Connect отсутствуют. Результаты по этому срезу приведены в [отчёте](../TEST_REPORT.md).

## Состав и конфиденциальность

В Release приложение `local.mycompanion` встраивает `local.mycompanion.widget` в PlugIns. У расширения включены `APPLICATION_EXTENSION_API_ONLY` и `SKIP_INSTALL`. У обоих одинаковые источники версии и entitlement `group.local.mycompanion`. Приложение запрашивает доступ EventKit с русским пояснением и разрешение на локальные уведомления. Для локальных задач разрешение на системные напоминания не требуется.

Данные героя, задач и снимок событий хранятся локально. Настройки приложения используют стандартные defaults. App Group передаёт настройку видимости календаря расширению. В исходниках поставляемых targets не обнаружено отправки данных разработчику, аналитического SDK и рекламного трекинга. В манифестах указаны пустой перечень собираемых типов и отсутствие трекинга. Причины UserDefaults в приложении — CA92.1 и 1C8F.1, в виджете — 1C8F.1. Для чтения метаданных файла БД внутри App Group обоими targets указана C617.1 (File Timestamp). Проверить эти заявления по privacy report архива и фактическим SDK перед заполнением App Privacy. [Причины Apple](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype) · [Определение сбора данных](https://developer.apple.com/app-store/app-privacy-details/)

Шесть пакетов и 65 изображений копируются в каждый target. Их реестры разрешают личное локальное использование. Для TestFlight требуются права на персонажей и графику для выбранной аудитории. В Documentation/WidgetPreviews при подготовке учтены 48 PNG и 9 GIF, включая системные кадры и производные обзоры. Они находятся вне фаз копирования продукта. Маркетинговый набор и его разрешения ожидают выбора владельца. Встроенные в ТЗ R01–R14 предназначены для дизайн-ревью. В рабочем дереве отдельная оригинальная иконка-фонарь включена в AppIcon приложения. Владелец утвердил оформление 27 ноября 2026 года. Требуются сборка каталога Xcode и проверка на устройстве. [Реестр по героям](CHARACTER_REFERENCES.md)

## Требования Apple

На 27.11.2026 для загрузки требуется Xcode 26+ и iOS SDK 26+. Минимальный deployment target для подачи — iOS 13, проект указывает iOS 17. С апреля 2027 Apple объявила переход на iOS SDK 27+ и deployment target iOS 15+. Сверить требования снова в день архивации. [Действующие требования](https://developer.apple.com/news/upcoming-requirements/) · [Следующее изменение](https://developer.apple.com/app-store/submitting/)

## Допуск конкретной сборки

| Состояние | Ответственный | Действие и свидетельство |
|---|---|---|
| Открыто | Владелец прав | Подтвердить лицензии для выбранного канала и территории либо предоставить разрешённую замену. Согласовать права на каждый выбранный маркетинговый кадр. |
| Открыто | Разработчик iOS | Проверить отображение утверждённой AppIcon на устройстве и её присутствие в архиве. |
| Открыто | Владелец Apple Developer | Подтвердить регистрацию обоих bundle ID и App Group на одной Team, профили, сертификаты и свободный build number в App Store Connect. |
| Частично | Этап 9 и QA | Контент прошёл проверку 6 × 150 реплик и 30 находок. Привязать к конечному дереву результаты 0–9, перечислить дефекты и сохранить ссылки на Swift, iOS build и XCTest. Повторить после изменения состава иконки или манифестов. [Отчёт](../TEST_REPORT.md) |
| Открыто | QA устройства | Записать реальные модель и iOS. Проверить установку и обновление, App Group, виджеты и интенты, разрешения, уведомления, доступность, нагрузку, энергию и 24/72 ч. [Матрица](DEVICE_MATRIX.md) |
| Открыто | Владелец и редактор | Утвердить политику и разместить публичный URL в метаданных и внутри приложения. Проверить App Privacy, ответы о шифровании и возрастную анкету по фактическому содержимому, включая оружие у персонажа и образы на скриншотах. [App Privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/) · [App Review](https://developer.apple.com/app-store/review/guidelines/) |
| BLOCKED | Инженер релиза на Mac | Сделать подписанный архив Release для generic iOS device. Записать путь к .xcarchive, build number, SHA/снимок дерева, версии Xcode/SDK, время и результат Validate App. На проверенной Windows-площадке отсутствуют Xcode и архив кандидата. |
| BLOCKED | Владелец | Выбрать группу внутреннего или внешнего тестирования. Для внешнего подготовить Beta App Review и инструкции. Записать решение Go/Hold с идентификатором проверенного архива. Загрузка и выдача доступа требуют отдельного согласия. [TestFlight](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/) |

### Проверка архива на Mac

1. Сверить `xcodebuild -version`, `xcrun --sdk iphoneos --show-sdk-version` и доступную схему через `xcodebuild -list -project MyCompanion.xcodeproj`. Архивировать схему MyCompanion с конфигурацией Release для generic iOS device.
2. В Products/Applications/MyCompanion.app проверить обработанный Info.plist, иконку, версию, ресурсы и PrivacyInfo.xcprivacy. Повторить для PlugIns/CompanionWidget.appex с его отдельным манифестом. Сверить состав обеих папок Characters с реестром.
3. Проверить подпись каждого bundle через `codesign --verify --strict` и entitlements через `codesign -d --entitlements :-`. Сопоставить Team, идентификаторы и App Group с профилями. Сгенерировать в Organizer privacy report и сохранить результат Validate App.

Для выпуска версии с напоминанием о перерыве владелец Apple Developer запрашивает разрешение Family Controls для приложения и расширения Device Activity Monitor. Для погодных реакций требуется включить WeatherKit у идентификатора приложения и проверить подписанную сборку с реальным запросом выбранного города. Порог Screen Time, тихие часы и отзыв доступа проверяются на физическом iPhone. [Family Controls](https://developer.apple.com/documentation/familycontrols/requesting-the-family-controls-entitlement) · [WeatherKit](https://developer.apple.com/weatherkit/)
