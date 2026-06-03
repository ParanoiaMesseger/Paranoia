package app.paranoia.client;

import android.content.ClipData;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Parcelable;
import android.os.Process;
import android.util.Log;

import org.qtproject.qt.android.bindings.QtActivity;

import java.util.ArrayList;
import java.util.LinkedHashSet;

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

    // JNI-мост в MainBackend (см. MainBackend.cpp). Вызывается после того,
    // как captureShareIntent сохранил share-target в shared prefs — даёт
    // QML‑стороне сигнал, что пора перечитать данные. Иначе при уже активном
    // приложении (warm share) Window.active не меняется и QML‑onActiveChanged
    // не срабатывает → banner не появляется.
    private static native void nativeShareTargetReady();

    // QtActivity объявляет onCreate как public — Java не позволяет сузить
    // видимость при override'е, поэтому здесь тоже public.
    @Override
    public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        captureShareIntent(getIntent());
    }

    @Override
    public void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        captureShareIntent(intent);
    }

    // Результат системного photo/video picker'а (см. ParanoiaAndroidUtils.pickMediaFromGallery).
    // Сохраняем URI в shared prefs, ChatBackend подбирает его при возврате
    // приложения в foreground (onApplicationStateChanged → Active).
    @Override
    public void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != ParanoiaAndroidUtils.REQUEST_PICK_IMAGE
                && requestCode != ParanoiaAndroidUtils.REQUEST_PICK_VIDEO) {
            return;
        }
        if (resultCode != RESULT_OK || data == null) return;
        // Мультивыбор: при выборе нескольких фото URI приходят в ClipData;
        // при одном — в data.getData(). Собираем все и сохраняем списком.
        ArrayList<String> picked = new ArrayList<>();
        ClipData clip = data.getClipData();
        if (clip != null) {
            for (int i = 0; i < clip.getItemCount(); i++) {
                Uri u = clip.getItemAt(i).getUri();
                if (u == null) continue;
                tryPersistRead(u);
                picked.add(u.toString());
            }
        } else {
            Uri uri = data.getData();
            if (uri != null) {
                tryPersistRead(uri);
                picked.add(uri.toString());
            }
        }
        if (picked.isEmpty()) return;
        boolean isImage = (requestCode == ParanoiaAndroidUtils.REQUEST_PICK_IMAGE);
        ParanoiaAndroidUtils.storePickedAttachments(getApplicationContext(), picked, isImage);
    }

    // ACTION_PICK обычно не выдаёт FLAG_GRANT_READ_URI_PERMISSION навсегда —
    // запрашиваем persistable permission, где это возможно, чтобы ChatBackend
    // успел прочитать файл при последующей отправке. Не у всех provider'ов есть
    // persistable permission (напр. photo-picker URI) — это норма.
    private void tryPersistRead(Uri uri) {
        try {
            getContentResolver().takePersistableUriPermission(
                uri, Intent.FLAG_GRANT_READ_URI_PERMISSION);
        } catch (SecurityException ignored) {
        }
    }

    // Если приложение запущено через системный share-sheet — складываем
    // содержимое (текст и/или список content://-URI) в shared prefs. QML
    // достаёт через MainBackend.takeShareTarget() и предлагает выбрать чат.
    private void captureShareIntent(Intent intent) {
        if (intent == null) return;
        final String action = intent.getAction();
        if (action == null) return;
        if (!Intent.ACTION_SEND.equals(action) && !Intent.ACTION_SEND_MULTIPLE.equals(action)) return;

        String text = "";
        ArrayList<String> uris = new ArrayList<>();

        CharSequence rawText = intent.getCharSequenceExtra(Intent.EXTRA_TEXT);
        if (rawText != null) text = rawText.toString();
        CharSequence rawSubject = intent.getCharSequenceExtra(Intent.EXTRA_SUBJECT);
        if (text.isEmpty() && rawSubject != null) text = rawSubject.toString();

        // EXTRA_STREAM (классический путь). На Android 33+ старый
        // getParcelableExtra(String) deprecated и реально возвращает null —
        // приходится использовать типизированный overload.
        LinkedHashSet<String> uriSet = new LinkedHashSet<>();
        if (Intent.ACTION_SEND.equals(action)) {
            Uri stream;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                stream = intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri.class);
            } else {
                Parcelable raw = intent.getParcelableExtra(Intent.EXTRA_STREAM);
                stream = (raw instanceof Uri) ? (Uri) raw : null;
            }
            if (stream != null) uriSet.add(stream.toString());
        } else { // SEND_MULTIPLE
            ArrayList<Uri> streams;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                streams = intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri.class);
            } else {
                ArrayList<Parcelable> raw = intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM);
                streams = new ArrayList<>();
                if (raw != null) {
                    for (Parcelable p : raw) {
                        if (p instanceof Uri) streams.add((Uri) p);
                    }
                }
            }
            if (streams != null) {
                for (Uri u : streams) {
                    if (u != null) uriSet.add(u.toString());
                }
            }
        }

        // ClipData (современный путь). Многие приложения шарят файлы через
        // intent.setClipData(...) + FLAG_GRANT_READ_URI_PERMISSION, иногда
        // вообще без EXTRA_STREAM. Без этого fallback'а файлы из таких
        // приложений просто теряются.
        ClipData clip = intent.getClipData();
        if (clip != null) {
            for (int i = 0; i < clip.getItemCount(); ++i) {
                ClipData.Item item = clip.getItemAt(i);
                if (item == null) continue;
                Uri itemUri = item.getUri();
                if (itemUri != null) uriSet.add(itemUri.toString());
                if (text.isEmpty()) {
                    CharSequence itemText = item.getText();
                    if (itemText != null && itemText.length() > 0) {
                        text = itemText.toString();
                    }
                }
            }
        }

        uris.addAll(uriSet);

        if (text.isEmpty() && uris.isEmpty()) return;

        // FLAG_GRANT_READ_URI_PERMISSION у content:// URI живёт только пока
        // наш task жив. Если пользователь долго думает в MainPage перед тем,
        // как выбрать чат, sender процесс может прибиться и доступ к URI
        // отвалится → ChatBackend.sendFile уже не сможет прочитать файл.
        // Поэтому копируем содержимое в наш cache ПРЯМО сейчас и сохраняем
        // file://-пути на копии.
        //
        // ВАЖНО: используем this (activity context), а не getApplicationContext():
        // FLAG_GRANT_READ_URI_PERMISSION привязывается к Activity, а у
        // application context'а доступа к URI может уже не быть.
        ArrayList<String> resolved = new ArrayList<>(uris.size());
        for (String s : uris) {
            String localPath = ParanoiaAndroidUtils.copyUriToCache(this, s);
            if (localPath != null && !localPath.isEmpty()) {
                resolved.add("file://" + localPath);
                Log.i(TAG, "captureShareIntent copied URI to cache path_len=" + localPath.length());
            } else {
                // Если копирование не удалось — кладём оригинальный URI как
                // last-resort fallback, sendFile попробует прочитать ещё раз.
                resolved.add(s);
                Log.w(TAG, "captureShareIntent copyUriToCache failed, falling back to URI");
            }
        }

        Log.i(TAG, "captureShareIntent action=" + action + " text_len=" + text.length()
                + " files=" + resolved.size());
        ParanoiaAndroidUtils.storeShareTarget(getApplicationContext(), text, resolved);

        // Уведомляем Qt-сторону, что данные готовы — если приложение уже было
        // активным, onActiveChanged может не сработать.
        try {
            nativeShareTargetReady();
        } catch (UnsatisfiedLinkError e) {
            // Qt-библиотека ещё не загружена (cold start, до super.onCreate);
            // тогда QML подхватит данные на старте через Component.onCompleted.
            Log.i(TAG, "nativeShareTargetReady: lib not ready yet, deferring");
        }
    }

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
