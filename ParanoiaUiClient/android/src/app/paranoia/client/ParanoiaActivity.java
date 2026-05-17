package app.paranoia.client;

import android.os.Process;
import android.util.Log;

import org.qtproject.qt.android.bindings.QtActivity;

// Главная (и единственная) активити приложения — тонкий подкласс QtActivity.
//
// Qt в QtActivityBase.onDestroy() в самом конце зовёт System.exit(0), но
// перед этим — terminateQt() и QtThread.exit(), которые синхронно ждут
// завершения Qt-потока. Если в Qt-потоке висит блокирующая задача (сетевой
// FFI-вызов в QThreadPool, незавершённый poll), onDestroy зависает и до
// System.exit(0) дело не доходит — процесс остаётся жить зомби.
//
// Тогда следующий запуск (иконка или тап по уведомлению) создаёт ВТОРОЙ
// QtActivity-инстанс в том же процессе. Qt — singleton на процесс, второй
// инстанс конфликтует с недобитым первым → белый экран.
//
// Watchdog ниже добивает процесс, если штатный Qt-shutdown не уложился в
// таймаут. При штатном завершении Qt сам вызовет System.exit(0) раньше и
// watchdog-поток умрёт вместе с процессом.
public final class ParanoiaActivity extends QtActivity {
    private static final String TAG = "ParanoiaActivity";
    private static final long SHUTDOWN_WATCHDOG_MS = 1500L;

    @Override
    protected void onDestroy() {
        // isChangingConfigurations() → onDestroy из-за смены конфигурации:
        // Qt сохраняет состояние и НЕ завершает процесс. Убивать нельзя.
        if (!isChangingConfigurations()) {
            Thread watchdog = new Thread(() -> {
                try {
                    Thread.sleep(SHUTDOWN_WATCHDOG_MS);
                } catch (InterruptedException ignored) {
                    return;
                }
                Log.i(TAG, "Qt shutdown did not finish in time; force-killing process");
                Process.killProcess(Process.myPid());
            }, "paranoia-shutdown-watchdog");
            watchdog.setDaemon(true);
            watchdog.start();
        }
        super.onDestroy();
    }
}
