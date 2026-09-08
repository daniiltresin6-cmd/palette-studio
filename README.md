## Palette Studio

Профессиональный генератор цветовых палитр с продвинутой системой гармоний и экспортом в различные форматы.

**Статус:** Завершён, готов к публикации  
**Объём:** ~2000 строк кода  
**Платформа:** Android (iOS в разработке)

---

## 🛠️ Стек

- **Flutter 3.x**, **Dart** (null-safety)
- **Provider** (state management)
- **CustomPainter** (кастомная отрисовка UI)
- **Method Channels** (нативная интеграция с Android)
- **SharedPreferences** (локальное хранилище)
- **sensors_plus** (акселерометр для аварийного выхода)
- **path_provider**, **permission_handler** (работа с файловой системой)

---
## Ключевые возможности

### Генерация палитр
- 6 алгоритмов цветовой гармонии:
  - **Monochromatic** (монохромная)
  - **Complementary** (комплементарная, 180°)
  - **Triadic** (триада, 120°)
  - **Tetradic** (тетрада, 90°)
  - **Analogous** (аналогичная, ±30°)
  - **Split-Complementary** (раздельно-комплементарная)
- Настраиваемый угол гармонии (для пресетов 2-5)
- Система оттенков (5 уровней lightness для каждого цвета)

### Интерфейс
- Кастомный цветовой круг (HSV/HSL color space)
- 2D палитра (Saturation vs Value)
- Адаптивная тема (светлая / тёмная / системная)
- Material Design 3
- Плавные анимации (AnimatedContainer, TweenAnimationBuilder)

### Экспорт и интеграция
- Копирование в буфер обмена:
  - **HEX** (#RRGGBB)
  - **CSS Variables** (--color-primary, --color-secondary)
  - **JSON** (структурированный формат)
- Сохранение палитры как PNG (через нативный Method Channel)
- Предпросмотр в UI (mock-up интерфейса)

### Скрытый модуль (Hidden Vault)
- Трекинг состояния (energy, mood, comfort)
- Аварийный выход по перевороту устройства (акселерометр)
- Шифрованное хранение записей (SharedPreferences + JSON)
- Паттерн-триггер для доступа (последовательность нажатий)

---

## 🚀 Установка и запуск

### Требования
- Flutter SDK 3.0+
- Android Studio / VS Code
- Android SDK (для сборки под Android)

### Быстрый старт

1. Клонируйте репозиторий:
```bash
git clone https://github.com/daniiltresin6-cmd/palette-studio.git
cd palette-studio
```

2. Установите зависимости:
```bash
flutter pub get
```

3. Запустите приложение:
```bash
flutter run
```

### Сборка APK

```bash
flutter build apk --release
```

APK будет находиться в `build/app/outputs/flutter-apk/app-release.apk`

---

## 📱 Использование

### Основной экран (Color Wheel)
1. Выберите цвет на круге (drag & drop)
2. Настройте насыщенность на 2D-палитре
3. Выберите пресет гармонии (6 вариантов)
4. При необходимости отрегулируйте угол (слайдер)
5. Копируйте цвета или экспортируйте палитру

### Вкладка "Настройка" (Tune)
- Точная настройка HSL (Hue, Saturation, Lightness)
- Генерация случайного цвета
- Просмотр всех оттенков системы

### Вкладка "Список" (List)
- Полный список цветов палитры с HEX-кодами
- Система оттенков для каждого цвета
- Быстрое копирование в буфер обмена
- Экспорт в PNG / HEX / CSS / JSON

---

## ️ Архитектура и технические решения

### State Management
- **Provider** + **ChangeNotifier** для реактивного управления состоянием
- Разделение логики: `ThemeManager` (темы) отделён от UI

### Кастомная графика
- **ColorWheel** — CustomPainter с Gradient.sweep для hue и Gradient.radial для saturation
- **ColorSquarePicker** — 2D HSV picker с динамическим маркером
- **_PresetIcon** — мини-иконки пресетов (wedge-сегменты на круге)

### Математика цвета
- Конвертация **HSL ↔ HSV ↔ RGB** с точностью до 1%
- Нормализация hue (0-360°) с учётом отрицательных значений
- Алгоритм генерации shades через манипуляцию lightness

### Нативная интеграция (Android)
```kotlin
// Method Channel: сохранение PNG в галерею
override fun onMethodCall(call: MethodCall, result: Result) {
    when (call.method) {
        "saveImage" -> {
            val bytes = call.argument<ByteArray>("bytes")
            val name = call.argument<String>("name")
            // Сохранение через MediaStore
            ...
        }
    }
}
```

### Скрытый модуль безопасности
- **AccelerometerEvents** — мониторинг ориентации устройства
- Триггер: `event.z > 9.5` (положение "лицом вниз") → таймер 300ms → exit
- Шифрование данных через XOR-маскирование (базовая защита)

---

## 📂 Структура проекта

```
lib/
├── main.dart                    # Точка входа, инициализация Provider
├── theme_manager.dart           # Управление темами (light/dark/system)
└── screens/
    ├── palette_screen.dart      # Главный экран с навигацией
    ├── hidden_vault_screen.dart # Скрытый модуль трекинга
    └── mock_preview_sheet.dart  # Предпросмотр в UI
└── widgets/
    ├── color_wheel.dart         # Цветовой круг
    ├── color_square_picker.dart # 2D палитра
    └── preset_icon.dart         # Иконки пресетов
```

---

## 🔧 Конфигурация

### Android (android/app/src/main/AndroidManifest.xml)

Добавьте разрешения для сохранения изображений:

```xml
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"/>
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"/>
```

### iOS (планируется)

Для будущей iOS-версии потребуется настроить:
- `Info.plist` с разрешением на доступ к фото
- Method Channel для iOS (UIImageWriteToSavedPhotosAlbum)

---

##  Тестирование

### Ручное тестирование
1. Проверка всех 6 пресетов гармонии
2. Тестирование экспорта (HEX, CSS, JSON, PNG)
3. Проверка скрытого модуля (паттерн нажатий, акселерометр)
4. Тестирование на разных разрешениях экрана

### Unit-тесты (в разработке)
- Тесты на конвертацию цветов (HSL → RGB → HEX)
- Тесты на нормализацию углов
- Тесты на валидацию входных данных

---

##  Дизайн-система

### Цветовая схема
- **Primary:** Teal (из Material Design)
- **Surface:** Белый / Тёмно-серый (в зависимости от темы)
- **Accent:** Зелёный (для кнопок действий)

### Типографика
- **Заголовки:** FontWeight.w700, 18-26sp
- **Текст:** FontWeight.w400, 14sp
- **Моноширинный:** Для HEX-кодов (fontFamily: 'monospace')

---

## 📄 Лицензия

MIT License

---

##  Контакты

Разработчик: Даниил (ETI)  
GitHub: https://github.com/daniiltresin6-cmd  
Telegram: @EttiRi
