#pragma once

class QGuiApplication;
class QQmlApplicationEngine;

namespace paranoia::profiling
{
// Точка входа профайлинг-харнеса. Вызывается из main() ПОСЛЕ загрузки QML и
// создания корневого окна. Если env-флаг PARANOIA_PROFILE не задан (пуст/«0»),
// делает ровно ничего — харнес полностью спящий.
//
// При активации вешает FrameProfiler на корневое окно и MainThreadWatchdog на
// GUI-поток, а на aboutToQuit сбрасывает отчёты в каталог PARANOIA_PROFILE_DIR
// (по умолчанию <CacheLocation>/profiling). Тонкие настройки — через env:
//   PARANOIA_PROFILE_DIR       каталог отчётов
//   PARANOIA_PROFILE_FRAMES    1/0 — профайлер кадров (по умолчанию 1)
//   PARANOIA_PROFILE_WATCHDOG  1/0 — сторож GUI-потока (по умолчанию 1)
//   PARANOIA_PROFILE_STALL_MS  порог столла, мс (по умолчанию 250)
//   PARANOIA_PROFILE_STACKS    1/0 — снимать стек GUI на столле (по умолчанию 1)
//
// Компилируется только при PARANOIA_PROFILING (см. CMake).
void installIfRequested(QGuiApplication *app, QQmlApplicationEngine *engine);
}
