package app.paranoia.client;

import android.app.Activity;
import android.content.ClipData;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Parcelable;
import android.util.Log;

import java.util.ArrayList;
import java.util.LinkedHashSet;

// Тонкий НЕ-Qt трамплин для системного share-sheet (ACTION_SEND/SEND_MULTIPLE).
//
// Почему отдельная Activity, а не intent-filter на ParanoiaActivity:
// при launchMode=singleTop (обязателен для Qt — singleTask даёт неубиваемый белый
// экран) share из другого приложения создавал ВТОРОЙ инстанс QtActivity в новом
// процессе/таске → Qt singleton конфликтует, vault залочен → PIN/белый экран.
//
// Здесь: ловим share в лёгкой Activity (Qt НЕ инициализируется), складываем
// содержимое в shared prefs (как раньше делала ParanoiaActivity.captureShareIntent),
// затем запускаем ОБЫЧНЫЙ launcher-intent — он переиспользует УЖЕ ЖИВОЙ
// ParanoiaActivity (onNewIntent, тот же процесс/таск, vault уже разблокирован),
// ровно как тап по иконке. QML на активации читает prefs (MainBackend.takeShareTarget)
// и показывает плашку «Поделиться». Если процесс был мёртв — launcher поднимет
// его штатно (один QtActivity, без белого экрана), а payload переживёт PIN.
public final class ShareActivity extends Activity {
    private static final String TAG = "ParanoiaShare";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        try {
            captureShareIntent(getIntent());
        } catch (Throwable t) {
            Log.w(TAG, "captureShareIntent failed: " + t);
        }
        // Запускаем основное приложение тем же путём, что иконка лаунчера —
        // переиспользует живой ParanoiaActivity (singleTop) либо поднимает с нуля.
        try {
            Intent launch = getPackageManager().getLaunchIntentForPackage(getPackageName());
            if (launch != null) {
                launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
                startActivity(launch);
            }
        } catch (Throwable t) {
            Log.w(TAG, "launch main failed: " + t);
        }
        finish();
    }

    // Складываем содержимое share (текст и/или список content://-URI) в shared
    // prefs. Логика идентична прежней ParanoiaActivity.captureShareIntent.
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

        // Копируем содержимое URI в наш cache ПРЯМО сейчас (используем this —
        // FLAG_GRANT_READ_URI_PERMISSION привязан к этой Activity) и сохраняем
        // file://-пути на копии: к моменту отправки sender-процесс может умереть.
        ArrayList<String> resolved = new ArrayList<>(uris.size());
        for (String s : uris) {
            String localPath = ParanoiaAndroidUtils.copyUriToCache(this, s);
            if (localPath != null && !localPath.isEmpty()) {
                resolved.add("file://" + localPath);
            } else {
                resolved.add(s); // last-resort: оригинальный URI
            }
        }

        Log.i(TAG, "captureShareIntent action=" + action + " text_len=" + text.length()
                + " files=" + resolved.size());
        ParanoiaAndroidUtils.storeShareTarget(getApplicationContext(), text, resolved);
    }
}
