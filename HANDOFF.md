# HANDOFF.md — Журнал передачи состояний разработки

**Проект:** Battery Hog (`apps/battery-hog`)  
**Категория:** Продуктовые приложения (`apps` / `macos-utility`)  
**Текущий релиз:** v1.5.0 (Интеграция MacMemoryGuard)  
**Дата фиксации:** 22.11.2026, 01:35 МСК  
**Текущий исполнитель:** Google Antigravity  
**Следующий исполнитель:** Google Antigravity / OpenAI Codex  

---

## 1. Текущий статус разработки

* **Завершённые этапы**:
  1. Выполнена миграция проекта в целевой каталог студии `apps/battery-hog` в соответствии с регламентом каталогов SPDev.
  2. Перенесено техническое задание `MacMemoryGuard_Antigravity_TZ.md` в каталог `docs/`.
  3. Устранены пробелы в именах системных скриптов.
  4. Проект включён в управляемый контур линтера структуры SPDev (`spdev-lint-structure.py`).
  5. **Встроена страница аналитики памяти MacMemoryGuard**:
     - В боковое меню `dashboard.html` добавлен пункт «Память и Swap» (`data-room="memory"`).
     - Разработан UI экран с карточками давления памяти, ОЗУ, компрессора, Swap, таблицей процессов по физическому Footprint (`ri_phys_footprint`) с флагами защиты (`Gemini`, `Antigravity`, `agy`), а также историей эпизодов за 72 часа.
     - Создан нативный мост `src/MemoryGuardBridge.swift` для прямого вызова системных API Darwin и чтения `~/.macmemoryguard/metrics.db`.
     - В `src/BatteryHogBackend.swift` добавлены эндпоинты `/api/memory` и `/api/memory/report`, функция `memory()` переведена на нативные замеры без вызова шелла `vm_stat`.
     - Приложение успешно пересобрано и обновлено в `/Applications/Battery Hog.app`.
* **Контрольная точка**: Релиз v1.5.0 успешно собран и установлен в `/Applications/Battery Hog.app`. Страница «Память и Swap» активна.
* **Следующая задача**: Запуск фонового сбора данных MacMemoryGuard через LaunchAgent и наблюдение в течение 72 часов.

---

## 2. Подтверждённые архитектурные решения

1. **ADR-BH-001 (Native Swift + WebKit)**: Полный отказ от Electron. Ядро приложения написано на чистом Swift без сторонних runtime-зависимостей, UI визуализируется через встроенный WKWebView.
2. **ADR-BH-002 (Privacy First Local Monitoring)**: Все метрики читаются исключительно локально из системных API macOS (`IOPSCopyPowerSourcesInfo`, `proc_pidinfo`, `proc_pid_rusage`), без сетевых телеметрий.
3. **ADR-BH-003 (Agent Mode Coordinator)**: Координация очередей тяжелых сборок AI-агентов при работе от батареи.
4. **ADR-BH-004 (MacMemoryGuard Seamless Bridge)**: Бесшовный нативный мост между дашбордом Battery Hog и локальным хранилищем метрик `~/.macmemoryguard/metrics.db`.

---

## 3. Фактические результаты проверок качества

* **Сборка приложения**:
  * Команда: `./src/build.sh`
  * Результат: **Сборка успешна, бинарник установлен в `/Applications/Battery Hog.app`**.
* **Линтер структуры студии**:
  * Команда: `python3 tools/linters/spdev-lint-structure.py`
  * Результат: **0 ошибок, 0 предупреждений**.
* **Структура файлов**:
  * Исходники: `src/` (включая `MemoryGuardBridge.swift`)
  * Интерфейс: `dashboard.html` (включая секцию `#page-memory`)
  * Документация и ТЗ: `docs/`
  * Тесты: `tests/`

---

## 4. Карта ключевых файлов и компонентов

* `src/MemoryGuardBridge.swift` — нативный сбор метрик Darwin и чтение SQLite базы MacMemoryGuard.
* `src/BatteryHogBackend.swift` — диспетчеризация API маршрутов `/api/memory` и `/api/memory/report`.
* `src/BatteryHogApp.swift` — главное окно macOS, WKWebView и координация событий.
* `dashboard.html` — SPA-интерфейс (Энергия, Приложения, Нагрузки, Аккумулятор, Память и Swap, Настройки).
* `src/native_build.sh` — сборочный скрипт Swift-компилятора.

---

## 5. Открытые вопросы, блокеры и следующие шаги для передачи в работу

* **Открытые вопросы**:
  * Оценить удобство отображения дельт Swap и списка защищенных процессов в реальном времени.
* **Блокеры**:
  * Блокеров нет. Приложение функционирует штатно.
* **Следующие шаги**:
  1. Запустить Battery Hog из Spotlight или папки «Программы» (`/Applications/Battery Hog.app`).
  2. Переключиться на вкладку **«Память и Swap»** и оценить обновленный интерфейс.
  3. При необходимости запустить фоновый сбор `macmemoryguard install-agent` для непрерывного наполнения базы истории.
