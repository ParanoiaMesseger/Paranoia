package app.paranoia.client;

import android.Manifest;
import android.app.Activity;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ActivityInfo;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.media.AudioManager;
import android.net.Uri;
import android.os.Build;
import android.provider.DocumentsContract;
import android.provider.MediaStore;
import android.provider.OpenableColumns;
import android.util.Log;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;

public final class ParanoiaAndroidUtils {
    private static final String TAG = "ParanoiaAndroidUtils";
    private static final int FILE_PERMISSION_REQUEST = 2027;
    private static final int MICROPHONE_PERMISSION_REQUEST = 2028;
    private static final int CAMERA_PERMISSION_REQUEST = 2029;
    private static final String SHARE_PREFS = "paranoia_share_target";
    private static final String SHARE_PREF_TEXT = "share_text";
    private static final String SHARE_PREF_URIS = "share_uris";

    private static final String PICKER_PREFS = "paranoia_attachment_picker";
    private static final String PICKER_PREF_URI = "picked_uri";
    public static final int REQUEST_PICK_IMAGE = 2030;
    public static final int REQUEST_PICK_VIDEO = 2031;

    private ParanoiaAndroidUtils() {}

    // Запускает системный photo picker (галерею) для выбора одного фото или
    // видео. Результат прилетает в ParanoiaActivity.onActivityResult, который
    // кладёт URI в picker shared prefs (см. takePickedAttachment).
    public static void pickMediaFromGallery(Context context, boolean wantImage) {
        if (!(context instanceof Activity)) return;
        Activity activity = (Activity) context;
        Intent intent;
        if (Build.VERSION.SDK_INT >= 33 && wantImage) {
            // Android 13+ photo picker: показывает встроенный «безопасный»
            // выбор фото без необходимости READ_MEDIA_IMAGES permission.
            intent = new Intent(MediaStore.ACTION_PICK_IMAGES);
            intent.setType("image/*");
            // Мультивыбор фото (для отправки мозаикой-каруселью). Лимит — min(10,
            // системный максимум); >1 включает множественный выбор в пикере.
            int max = Math.max(2, Math.min(10, MediaStore.getPickImagesMaxLimit()));
            intent.putExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, max);
        } else {
            // Универсальный путь: ACTION_PICK с MediaStore CONTENT_URI — у всех
            // OEM открывается «Галерея» / Photos, а не файловый менеджер.
            Uri base = wantImage
                    ? MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                    : MediaStore.Video.Media.EXTERNAL_CONTENT_URI;
            intent = new Intent(Intent.ACTION_PICK, base);
            intent.setType(wantImage ? "image/*" : "video/*");
            // Best-effort мультивыбор фото на <33 (часть OEM-галерей понимает).
            if (wantImage) intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
        }
        try {
            activity.startActivityForResult(intent,
                wantImage ? REQUEST_PICK_IMAGE : REQUEST_PICK_VIDEO);
        } catch (Exception e) {
            Log.w(TAG, "Cannot launch media picker", e);
            // Fallback: универсальный GET_CONTENT (с мультивыбором для фото).
            try {
                Intent fallback = new Intent(Intent.ACTION_GET_CONTENT);
                fallback.setType(wantImage ? "image/*" : "video/*");
                fallback.addCategory(Intent.CATEGORY_OPENABLE);
                if (wantImage) fallback.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
                activity.startActivityForResult(fallback,
                    wantImage ? REQUEST_PICK_IMAGE : REQUEST_PICK_VIDEO);
            } catch (Exception ignored) {}
        }
    }

    public static synchronized void storePickedAttachment(Context context, String uri) {
        if (context == null) return;
        SharedPreferences prefs = context.getApplicationContext()
                .getSharedPreferences(PICKER_PREFS, Context.MODE_PRIVATE);
        prefs.edit().putString(PICKER_PREF_URI, uri == null ? "" : uri).apply();
    }

    // Несколько выбранных вложений — храним тип ("img"/"vid") первой строкой,
    // затем список URI, всё склеено через '\n'. C++ (consumePickedAttachment)
    // разбивает: фото роутит через QML (подпись из поля ввода, мозаика при >1),
    // видео — обычной отправкой по одному.
    public static synchronized void storePickedAttachments(Context context, java.util.List<String> uris,
                                                           boolean isImage) {
        if (context == null || uris == null) return;
        String joined = (isImage ? "img\n" : "vid\n") + android.text.TextUtils.join("\n", uris);
        SharedPreferences prefs = context.getApplicationContext()
                .getSharedPreferences(PICKER_PREFS, Context.MODE_PRIVATE);
        prefs.edit().putString(PICKER_PREF_URI, joined).apply();
    }

    public static synchronized String takePickedAttachment(Context context) {
        if (context == null) return "";
        SharedPreferences prefs = context.getApplicationContext()
                .getSharedPreferences(PICKER_PREFS, Context.MODE_PRIVATE);
        String uri = prefs.getString(PICKER_PREF_URI, "");
        prefs.edit().remove(PICKER_PREF_URI).apply();
        return uri == null ? "" : uri;
    }

    // Записывает входящий share-intent (текст + список content://-uri) в
    // shared prefs. Читается C++-сторонами через takeShareTarget; пара
    // методов разнесена, потому что Activity и QML-движок инициализируются
    // в разные моменты — данные могут «висеть» в prefs пока движок не подхватит.
    public static synchronized void storeShareTarget(Context context, String text, ArrayList<String> uris) {
        if (context == null) return;
        SharedPreferences prefs = context.getApplicationContext()
                .getSharedPreferences(SHARE_PREFS, Context.MODE_PRIVATE);
        SharedPreferences.Editor editor = prefs.edit();
        editor.putString(SHARE_PREF_TEXT, text == null ? "" : text);
        StringBuilder joined = new StringBuilder();
        if (uris != null) {
            for (int i = 0; i < uris.size(); ++i) {
                if (i > 0) joined.append('\n');
                joined.append(uris.get(i) == null ? "" : uris.get(i));
            }
        }
        editor.putString(SHARE_PREF_URIS, joined.toString());
        editor.apply();
    }

    // Возвращает «texturi1\nuri2\n...». Разделитель текст/uri'ы — ,
    // потому что в URL'ах встречается \n. После чтения prefs очищаются.
    public static synchronized String takeShareTarget(Context context) {
        if (context == null) return "";
        SharedPreferences prefs = context.getApplicationContext()
                .getSharedPreferences(SHARE_PREFS, Context.MODE_PRIVATE);
        String text = prefs.getString(SHARE_PREF_TEXT, "");
        String uris = prefs.getString(SHARE_PREF_URIS, "");
        prefs.edit().remove(SHARE_PREF_TEXT).remove(SHARE_PREF_URIS).apply();
        if ((text == null || text.isEmpty()) && (uris == null || uris.isEmpty())) return "";
        StringBuilder out = new StringBuilder();
        out.append(text == null ? "" : text);
        out.append('\u0001');
        out.append(uris == null ? "" : uris);
        return out.toString();
    }

    /// Перевести audio-стек в режим VoIP-звонка. Без MODE_IN_COMMUNICATION
    /// AudioManager на Android считает наше приложение медиа-плеером, и при
    /// одновременном recording (микрофон) приглушает media stream — звук
    /// QAudioSink становится физически неслышен в динамике.
    ///
    /// Speakerphone=true гарантирует, что вывод идёт через громкий динамик,
    /// а не «телефонную трубку» (earpiece). Для нашего use-case (видеозвонок
    /// с экрана) это правильный выбор.
    ///
    /// При `enable=false` возвращаем NORMAL — чтобы после звонка системные
    /// звуки/музыка снова шли как ожидается.
    public static void setVoiceCallMode(Context context, boolean enable, boolean speakerphone) {
        if (context == null) return;
        try {
            AudioManager am = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
            if (am == null) return;
            if (enable) {
                am.setMode(AudioManager.MODE_IN_COMMUNICATION);
                am.setSpeakerphoneOn(speakerphone);
                Log.i(TAG, "voice call mode ON, speakerphone=" + speakerphone);
            } else {
                am.setMode(AudioManager.MODE_NORMAL);
                am.setSpeakerphoneOn(false);
                Log.i(TAG, "voice call mode OFF");
            }
        } catch (Exception e) {
            Log.w(TAG, "setVoiceCallMode failed: " + e.getMessage());
        }
    }

    /// Заблокировать ориентацию Activity на portrait (или вернуть UNSPECIFIED).
    /// Используется на время звонка, чтобы интерфейс не «прыгал» при повороте
    /// устройства. Если context — не Activity, no-op.
    public static void lockOrientationPortrait(Context context, boolean lock) {
        if (!(context instanceof Activity)) return;
        try {
            Activity activity = (Activity) context;
            int orientation = lock
                    ? ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                    : ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED;
            activity.runOnUiThread(() -> activity.setRequestedOrientation(orientation));
            Log.i(TAG, "orientation lock=" + lock);
        } catch (Exception e) {
            Log.w(TAG, "lockOrientationPortrait failed: " + e.getMessage());
        }
    }

    public static void requestFileAccessIfNeeded(Context context) {
        if (!(context instanceof Activity) || Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return;
        }

        Activity activity = (Activity) context;
        ArrayList<String> permissions = new ArrayList<>();
        if (Build.VERSION.SDK_INT >= 33) {
            addIfDenied(activity, permissions, "android.permission.READ_MEDIA_IMAGES");
            addIfDenied(activity, permissions, "android.permission.READ_MEDIA_VIDEO");
            addIfDenied(activity, permissions, "android.permission.READ_MEDIA_AUDIO");
        } else {
            addIfDenied(activity, permissions, Manifest.permission.READ_EXTERNAL_STORAGE);
        }
        if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.P) {
            addIfDenied(activity, permissions, Manifest.permission.WRITE_EXTERNAL_STORAGE);
        }
        if (!permissions.isEmpty()) {
            activity.requestPermissions(permissions.toArray(new String[0]), FILE_PERMISSION_REQUEST);
        }
    }

    public static void requestMicrophonePermission(Context context) {
        if (!(context instanceof Activity) || Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return;
        }
        Activity activity = (Activity) context;
        if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO)
                != PackageManager.PERMISSION_GRANTED) {
            activity.requestPermissions(
                new String[]{Manifest.permission.RECORD_AUDIO},
                MICROPHONE_PERMISSION_REQUEST);
        }
    }

    public static void requestCameraPermission(Context context) {
        if (!(context instanceof Activity) || Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return;
        }
        Activity activity = (Activity) context;
        if (activity.checkSelfPermission(Manifest.permission.CAMERA)
                != PackageManager.PERMISSION_GRANTED) {
            activity.requestPermissions(
                new String[]{Manifest.permission.CAMERA},
                CAMERA_PERMISSION_REQUEST);
        }
    }

    public static String copyUriToCache(Context context, String uriString) {
        if (context == null || uriString == null || uriString.isEmpty()) {
            return "";
        }
        try {
            Uri uri = Uri.parse(uriString);
            ContentResolver resolver = context.getContentResolver();
            String displayName = sanitizeFileName(displayName(resolver, uri));
            if (displayName.isEmpty()) {
                displayName = "attachment.bin";
            }
            File dir = new File(context.getCacheDir(), "attachments");
            if (!dir.exists() && !dir.mkdirs()) {
                return "";
            }
            File target = new File(dir, System.currentTimeMillis() + "-" + displayName);
            try (InputStream input = resolver.openInputStream(uri);
                 OutputStream output = new FileOutputStream(target)) {
                if (input == null) {
                    return "";
                }
                copy(input, output);
            }
            return target.getAbsolutePath();
        } catch (Exception e) {
            Log.w(TAG, "Cannot copy URI to cache", e);
            return "";
        }
    }

    public static boolean copyFileToUri(Context context, String sourcePath, String uriString) {
        if (context == null || sourcePath == null || uriString == null || uriString.isEmpty()) {
            return false;
        }
        try {
            Uri uri = Uri.parse(uriString);
            try (InputStream input = new FileInputStream(sourcePath);
                 OutputStream output = context.getContentResolver().openOutputStream(uri, "w")) {
                if (output == null) {
                    return false;
                }
                copy(input, output);
            }
            return true;
        } catch (Exception e) {
            Log.w(TAG, "Cannot copy file to URI", e);
            return false;
        }
    }

    public static boolean copyFileToDirectoryUri(Context context, String sourcePath, String treeUriString, String fileName) {
        if (context == null || sourcePath == null || treeUriString == null || treeUriString.isEmpty()) {
            return false;
        }
        try {
            Uri treeUri = Uri.parse(treeUriString);
            ContentResolver resolver = context.getContentResolver();
            String treeDocumentId = DocumentsContract.getTreeDocumentId(treeUri);
            Uri parentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, treeDocumentId);
            String displayName = uniqueDisplayName(resolver, treeUri, sanitizeFileName(fileName));
            Uri targetUri = DocumentsContract.createDocument(resolver, parentUri, "application/octet-stream", displayName);
            if (targetUri == null) {
                return false;
            }
            try (InputStream input = new FileInputStream(sourcePath);
                 OutputStream output = resolver.openOutputStream(targetUri, "w")) {
                if (output == null) {
                    return false;
                }
                copy(input, output);
            }
            return true;
        } catch (Exception e) {
            Log.w(TAG, "Cannot copy file to directory URI", e);
            return false;
        }
    }

    private static void addIfDenied(Activity activity, ArrayList<String> permissions, String permission) {
        if (activity.checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) {
            permissions.add(permission);
        }
    }

    private static String displayName(ContentResolver resolver, Uri uri) {
        try (Cursor cursor = resolver.query(uri, new String[] { OpenableColumns.DISPLAY_NAME }, null, null, null)) {
            if (cursor != null && cursor.moveToFirst()) {
                String name = cursor.getString(0);
                if (name != null) {
                    return name;
                }
            }
        } catch (Exception ignored) {
        }
        String fallback = uri.getLastPathSegment();
        return fallback == null ? "" : fallback;
    }

    private static String sanitizeFileName(String value) {
        String result = value == null ? "" : value.replaceAll("[\\\\/:*?\"<>|]", "_").trim();
        while (result.endsWith(".") || result.endsWith(" ")) {
            result = result.substring(0, result.length() - 1);
        }
        return result.isEmpty() ? "attachment.bin" : result;
    }

    private static String uniqueDisplayName(ContentResolver resolver, Uri treeUri, String fileName) {
        String safeName = sanitizeFileName(fileName);
        String base = safeName;
        String suffix = "";
        int dot = safeName.lastIndexOf('.');
        if (dot > 0 && dot < safeName.length() - 1) {
            base = safeName.substring(0, dot);
            suffix = safeName.substring(dot);
        }

        String treeDocumentId = DocumentsContract.getTreeDocumentId(treeUri);
        Uri childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, treeDocumentId);
        ArrayList<String> existing = new ArrayList<>();
        try (Cursor cursor = resolver.query(childrenUri, new String[] { DocumentsContract.Document.COLUMN_DISPLAY_NAME },
                null, null, null)) {
            while (cursor != null && cursor.moveToNext()) {
                String name = cursor.getString(0);
                if (name != null) existing.add(name);
            }
        } catch (Exception ignored) {
        }

        String candidate = safeName;
        for (int i = 1; existing.contains(candidate); ++i) {
            candidate = base + " (" + i + ")" + suffix;
        }
        return candidate;
    }

    private static void copy(InputStream input, OutputStream output) throws java.io.IOException {
        byte[] buffer = new byte[64 * 1024];
        int read;
        while ((read = input.read(buffer)) >= 0) {
            output.write(buffer, 0, read);
        }
    }
}
