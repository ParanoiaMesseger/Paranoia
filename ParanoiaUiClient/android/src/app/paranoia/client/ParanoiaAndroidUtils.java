package app.paranoia.client;

import android.Manifest;
import android.app.Activity;
import android.content.ContentResolver;
import android.content.Context;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.media.AudioManager;
import android.net.Uri;
import android.os.Build;
import android.provider.DocumentsContract;
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

    private ParanoiaAndroidUtils() {}

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
