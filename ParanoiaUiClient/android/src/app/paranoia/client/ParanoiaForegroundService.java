package app.paranoia.client;

import android.Manifest;
import android.app.Activity;
import android.app.AlarmManager;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkInfo;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

public final class ParanoiaForegroundService extends Service {
    private static final String CHANNEL_ID = "paranoia_polling";
    private static final String MESSAGE_CHANNEL_ID = "paranoia_messages";
    private static final String EXTRA_OPEN_PROFILE_ID = "app.paranoia.client.OPEN_PROFILE_ID";
    private static final String EXTRA_OPEN_PEER = "app.paranoia.client.OPEN_PEER";
    private static final String ACTION_START = "app.paranoia.client.START_NOTIFICATION_SERVICE";
    private static final String ACTION_SET_APP_FOREGROUND = "app.paranoia.client.SET_APP_FOREGROUND";
    private static final String ACTION_POLL_NOW = "app.paranoia.client.POLL_NOW";
    private static final String ACTION_SET_SNAPSHOT = "app.paranoia.client.SET_SNAPSHOT";
    private static final String ACTION_CLEAR_SNAPSHOT = "app.paranoia.client.CLEAR_SNAPSHOT";
    private static final String EXTRA_APP_FOREGROUND = "app.paranoia.client.APP_FOREGROUND";
    private static final String EXTRA_SNAPSHOT_JSON = "app.paranoia.client.SNAPSHOT_JSON";
    private static final int POLL_ALARM_REQUEST = 2027;
    private static final String PREFS = "paranoia_notifications";
    private static final String PREF_APP_FOREGROUND = "app_foreground";
    private static final String PREF_SERVICE_REQUESTED = "service_requested";
    private static final String PREF_OPEN_PROFILE_ID = "open_profile_id";
    private static final String PREF_OPEN_PEER = "open_peer";
    private static final String TAG = "ParanoiaService";
    private static final int FOREGROUND_NOTIFICATION_ID = 1001;
    private static final int MESSAGE_NOTIFICATION_ID = 1002;
    private static final long POLL_INTERVAL_MS = 60_000L;
    // Если poll не завершился за это время — считаем его зависшим (несмотря на
    // 60s request-timeout в Rust) и разрешаем стартовать новый. Зависший поток
    // утечёт, но cached pool не даст ему заблокировать следующие опросы.
    private static final long POLL_HARD_TIMEOUT_MS = 120_000L;

    private static final ExecutorService POLL_EXECUTOR = Executors.newCachedThreadPool();
    // Время старта текущего poll'а (мс), 0 = poll не идёт. Раньше тут был
    // AtomicBoolean — но один зависший сетевой вызов оставлял его в true
    // навсегда, и сервис переставал опрашивать совсем.
    private static final AtomicLong pollStartedAtMs = new AtomicLong(0L);
    private static volatile boolean started = false;
    private static volatile boolean appForeground = false;
    private static volatile boolean nativeLibraryLoaded = false;
    private static volatile boolean nativeLibraryLoadAttempted = false;
    private static volatile boolean paranoiaInitialized = false;

    // ── JNI (libParanoiaService_<abi>.so) ─────────────────────────────────
    // Тонкая обёртка над paranoia_lib без Qt — см. android/jni/paranoia_service_jni.c.
    // Сервис принципиально не открывает SQLCipher и не работает с vault'ом;
    // всё, что нужно для запроса /notify к серверу — приходит из snapshot'а,
    // который UI присылает после unlock'а (см. handleSnapshotIntent).
    private static native boolean paranoiaInit(Context context);
    private static native long paranoiaServiceNotifyCount(String serverUrl, String reserveUrlsJson,
                                                          String signingKeyB64, String senderServerId,
                                                          String partnerServerId, long seq);
    private static native String paranoiaLastError();

    // ── Snapshot модель ────────────────────────────────────────────────────
    // Живёт ТОЛЬКО в RAM сервиса. На диск не пишется. После reboot / kill
    // процесса исчезает; UI запушит свежий снимок при следующем unlock'е.
    //
    // Содержит минимум для подписи /notify-запроса и трэкинга «уже виденного»
    // last_pulled_seq. Никаких сессионных ключей диалога, master_key, db_key.
    private static final AtomicReference<Snapshot> SNAPSHOT = new AtomicReference<>(Snapshot.empty());

    private static final class Snapshot {
        final List<ProfileHint> profiles;
        Snapshot(List<ProfileHint> profiles) {
            this.profiles = Collections.unmodifiableList(profiles);
        }
        static Snapshot empty() {
            return new Snapshot(new ArrayList<ProfileHint>());
        }
        boolean isEmpty() {
            for (ProfileHint p : profiles) {
                if (!p.dialogs.isEmpty()) return false;
            }
            return true;
        }
    }

    private static final class ProfileHint {
        final String serverUrl;
        final String reserveUrlsJson;
        final String signingKeyB64;
        final String senderServerId;
        final List<DialogHint> dialogs;
        ProfileHint(String serverUrl, String reserveUrlsJson, String signingKeyB64,
                    String senderServerId, List<DialogHint> dialogs) {
            this.serverUrl = serverUrl;
            this.reserveUrlsJson = reserveUrlsJson;
            this.signingKeyB64 = signingKeyB64;
            this.senderServerId = senderServerId;
            this.dialogs = Collections.unmodifiableList(dialogs);
        }
    }

    private static final class DialogHint {
        final String partnerServerId;
        final long seq;
        DialogHint(String partnerServerId, long seq) {
            this.partnerServerId = partnerServerId;
            this.seq = seq;
        }
    }

    public static void initialize(Context context) {
        initialize(context, "");
    }

    /// Второй аргумент сохранён ради бинарной совместимости со старым
    /// PlatformNotifications::registerBackgroundTasks (тот шлёт сюда путь к
    /// appDataRoot). Сейчас сервис работает строго по snapshot'у и не
    /// читает с диска — поэтому путь игнорируется.
    public static void initialize(Context context, String appDataRoot) {
        ensureChannels(context);
        requestPostNotificationsIfNeeded(context);
    }

    /// Передать сервису свежий snapshot. JSON формат:
    /// {"profiles":[{"server":"...", "reserveUrls":["..."], "signingKeyB64":"...",
    ///               "senderServerId":"...",
    ///               "dialogs":[{"partnerServerId":"...", "seq":123}, ...]}, ...]}
    /// Вызывать из UI-процесса:
    ///  - сразу после unlock'а;
    ///  - после pull'а, при котором last_pulled_seq реально сдвинулся;
    ///  - при добавлении/удалении диалога;
    ///  - при rotation signing key.
    public static void publishSnapshot(Context context, String snapshotJson) {
        if (context == null || snapshotJson == null) return;
        Intent intent = new Intent(context, ParanoiaForegroundService.class);
        intent.setAction(ACTION_SET_SNAPSHOT);
        intent.putExtra(EXTRA_SNAPSHOT_JSON, snapshotJson);
        try {
            startServiceCompat(context, intent);
        } catch (RuntimeException e) {
            Log.w(TAG, "Cannot publish snapshot", e);
        }
    }

    /// Очистить snapshot (logout / явная отписка). После этого сервис
    /// останавливается на следующем poll'е («нет целей»).
    public static void clearSnapshot(Context context) {
        if (context == null) return;
        Intent intent = new Intent(context, ParanoiaForegroundService.class);
        intent.setAction(ACTION_CLEAR_SNAPSHOT);
        try {
            startServiceCompat(context, intent);
        } catch (RuntimeException e) {
            Log.w(TAG, "Cannot clear snapshot", e);
        }
    }

    public static void setApplicationForeground(Context context, boolean foreground) {
        appForeground = foreground;
        prefs(context).edit().putBoolean(PREF_APP_FOREGROUND, foreground).commit();
        if (foreground) {
            cancelMessageNotification(context);
        }
        if (serviceRequested(context)) {
            Intent intent = new Intent(context, ParanoiaForegroundService.class);
            intent.setAction(ACTION_SET_APP_FOREGROUND);
            intent.putExtra(EXTRA_APP_FOREGROUND, foreground);
            try {
                startServiceCompat(context, intent);
            } catch (RuntimeException e) {
                Log.w(TAG, "Cannot send foreground state to service", e);
            }
        }
    }

    public static void start(Context context) {
        Log.i(TAG, "start requested");
        ensureChannels(context);
        requestPostNotificationsIfNeeded(context);
        Intent intent = new Intent(context, ParanoiaForegroundService.class);
        intent.setAction(ACTION_START);
        intent.putExtra(EXTRA_APP_FOREGROUND, isApplicationForeground(context));
        try {
            started = true;
            prefs(context).edit().putBoolean(PREF_SERVICE_REQUESTED, true).commit();
            Log.i(TAG, "startForegroundService requested");
            startServiceCompat(context, intent);
        } catch (RuntimeException e) {
            started = false;
            Log.w(TAG, "Cannot start foreground service", e);
        }
    }

    public static void stop(Context context) {
        started = false;
        prefs(context).edit().putBoolean(PREF_SERVICE_REQUESTED, false).commit();
        context.stopService(new Intent(context, ParanoiaForegroundService.class));
    }

    /// Уведомление полностью обезличено: ни имени контакта, ни peer-ID.
    /// Это сознательная архитектурная мера — сервис не знает о peer'ах
    /// human-readable, а notification text не должен раскрывать опаковые
    /// серверные ID. По тапу открывается само приложение (без deep-link).
    public static void showNewMessages(Context context, long count) {
        Log.i(TAG, "showNewMessages requested: count=" + count);
        if (count <= 0) {
            cancelMessageNotification(context);
            return;
        }
        if (isApplicationForeground(context)) {
            Log.i(TAG, "showNewMessages skipped: application is foreground");
            return;
        }
        requestPostNotificationsIfNeeded(context);
        if (!notificationsAllowed(context)) {
            Log.i(TAG, "showNewMessages skipped: POST_NOTIFICATIONS is not granted");
            return;
        }
        ensureChannels(context);
        NotificationManager manager = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
        if (manager == null) {
            return;
        }
        Notification.Builder builder = notificationBuilder(context, MESSAGE_CHANNEL_ID)
                .setContentTitle("Paranoia")
                .setContentText("Новые сообщения (" + count + ")")
                .setSmallIcon(context.getApplicationInfo().icon)
                .setContentIntent(openAppIntent(context, MESSAGE_NOTIFICATION_ID, null, null))
                .setAutoCancel(true)
                .setShowWhen(true);
        try {
            manager.notify(MESSAGE_NOTIFICATION_ID, buildNotification(builder));
            Log.i(TAG, "showNewMessages posted notification id=" + MESSAGE_NOTIFICATION_ID);
        } catch (RuntimeException e) {
            Log.w(TAG, "Cannot show message notification", e);
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        final String action = intent != null ? intent.getAction() : null;
        Log.i(TAG, "onStartCommand action=" + action);
        if (ACTION_SET_SNAPSHOT.equals(action)) {
            handleSnapshotIntent(intent);
        } else if (ACTION_CLEAR_SNAPSHOT.equals(action)) {
            SNAPSHOT.set(Snapshot.empty());
            Log.i(TAG, "snapshot cleared by UI");
        }
        if (intent != null && intent.hasExtra(EXTRA_APP_FOREGROUND)) {
            appForeground = intent.getBooleanExtra(EXTRA_APP_FOREGROUND, appForeground);
            prefs(this).edit().putBoolean(PREF_APP_FOREGROUND, appForeground).commit();
        } else {
            appForeground = isApplicationForeground(this);
        }
        ensureChannels(this);
        Notification notification = buildForegroundNotification();
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(FOREGROUND_NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
            } else {
                startForeground(FOREGROUND_NOTIFICATION_ID, notification);
            }
            Log.i(TAG, "entered foreground");
            started = true;
            triggerPollAndReschedule();
        } catch (RuntimeException e) {
            started = false;
            Log.w(TAG, "Cannot enter foreground", e);
            stopSelf();
            return START_NOT_STICKY;
        }
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        cancelPollAlarm(this);
        started = false;
        stopForeground(true);
        super.onDestroy();
    }

    @Override
    public void onTaskRemoved(Intent rootIntent) {
        Log.i(TAG, "task removed: keep notification service running");
        appForeground = false;
        prefs(this).edit().putBoolean(PREF_APP_FOREGROUND, false).commit();
        triggerPollAndReschedule();
        super.onTaskRemoved(rootIntent);
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private Notification buildForegroundNotification() {
        Notification.Builder builder = notificationBuilder(this, CHANNEL_ID)
                .setContentTitle("Paranoia")
                .setContentText("Paranoia: ожидание сообщений")
                .setSmallIcon(getApplicationInfo().icon)
                .setContentIntent(openAppIntent(this, FOREGROUND_NOTIFICATION_ID, null, null))
                .setOngoing(true)
                .setShowWhen(false);
        return buildNotification(builder);
    }

    private void triggerPollAndReschedule() {
        runAutonomousPoll();
        schedulePollAlarm(this, POLL_INTERVAL_MS);
    }

    // ── Wake-locked polling через AlarmManager ───────────────────────────
    // Handler.postDelayed на main looper'е сервиса замерзает, когда устройство
    // уходит в Doze/light idle (на Transsion + старших Android'ах FGS не
    // освобождает от этого). AlarmManager + BroadcastReceiver гарантирует, что
    // система разбудит процесс и доставит PendingIntent даже из глубокого сна.
    //
    // Используем именно BroadcastReceiver, а не PendingIntent.getForegroundService:
    // OEM-агрессивные battery saver'ы (Transsion Hiber, MIUI) часто блокируют
    // запуск FGS из background даже для уже-запущенного сервиса, тогда как
    // broadcast'ы с RTC_WAKEUP проходят через эти ограничения и временно
    // снимают app standby. Получатель сам подтягивает CPU через wake lock и
    // делегирует работу POLL_EXECUTOR'у.
    private static PendingIntent pollAlarmIntent(Context context) {
        Intent intent = new Intent(context, PollAlarmReceiver.class);
        intent.setAction(ACTION_POLL_NOW);
        intent.setPackage(context.getPackageName());
        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) flags |= PendingIntent.FLAG_IMMUTABLE;
        return PendingIntent.getBroadcast(context, POLL_ALARM_REQUEST, intent, flags);
    }

    public static final class PollAlarmReceiver extends BroadcastReceiver {
        @Override
        public void onReceive(Context context, Intent intent) {
            final Context appContext = context.getApplicationContext();
            Log.i(TAG, "alarm received, dispatching poll");
            // Сразу планируем следующий alarm, чтобы цикл не сломался, если
            // текущий poll зависнет в сети или native-вызове.
            schedulePollAlarm(appContext, POLL_INTERVAL_MS);

            PowerManager pm = (PowerManager) appContext.getSystemService(Context.POWER_SERVICE);
            final PowerManager.WakeLock wakeLock = pm == null ? null
                    : pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "paranoia:poll");
            if (wakeLock != null) {
                wakeLock.setReferenceCounted(false);
                // Потолок чуть выше Rust request-timeout (60s) — на штатном
                // завершении release в finally отпустит раньше.
                wakeLock.acquire(75_000L);
            }

            if (!tryBeginPoll()) {
                if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
                return;
            }
            // НЕ используем goAsync() / PendingResult: у broadcast-receiver жёсткий
            // ~10-сек ANR-timeout даже в async-режиме, а notify_count в холодном
            // service-процессе делает DNS + TLS handshake — легко выпадает за этот
            // лимит. Процесс держит живым foreground-service, CPU — wake lock.
            POLL_EXECUTOR.execute(new Runnable() {
                @Override
                public void run() {
                    try {
                        processPollResult(appContext, pollNotifications(appContext));
                    } finally {
                        endPoll();
                        if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
                    }
                }
            });
        }
    }

    // Разрешает старт нового poll'а, если предыдущего нет либо он висит дольше
    // POLL_HARD_TIMEOUT_MS (считаем мёртвым). Возвращает true, если право на
    // poll получено.
    private static boolean tryBeginPoll() {
        final long now = System.currentTimeMillis();
        while (true) {
            final long started = pollStartedAtMs.get();
            if (started != 0L && now - started < POLL_HARD_TIMEOUT_MS) {
                return false;
            }
            if (pollStartedAtMs.compareAndSet(started, now)) {
                if (started != 0L) {
                    Log.w(TAG, "previous poll exceeded hard timeout; starting a fresh one");
                }
                return true;
            }
        }
    }

    private static void endPoll() {
        pollStartedAtMs.set(0L);
    }

    private static void schedulePollAlarm(Context context, long delayMs) {
        AlarmManager manager = (AlarmManager) context.getSystemService(Context.ALARM_SERVICE);
        if (manager == null) {
            Log.w(TAG, "AlarmManager unavailable; cannot schedule next poll");
            return;
        }
        long when = System.currentTimeMillis() + Math.max(1000L, delayMs);
        PendingIntent pi = pollAlarmIntent(context);
        try {
            // Без exact-alarm'а app standby bucket откладывает срабатывание на минуты —
            // см. dumpsys alarm: policyWhenElapsed app_standby=-2m48s. Exact-alarm
            // обходит этот лимит, остаётся только doze (его покрывает …AllowWhileIdle).
            boolean useExact = true;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                useExact = manager.canScheduleExactAlarms();
            }
            if (useExact && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, when, pi);
                Log.i(TAG, "next poll scheduled in " + delayMs + "ms (exact, allow while idle)");
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, when, pi);
                Log.i(TAG, "next poll scheduled in " + delayMs + "ms (inexact, allow while idle; exact not granted)");
            } else {
                manager.setExact(AlarmManager.RTC_WAKEUP, when, pi);
                Log.i(TAG, "next poll scheduled in " + delayMs + "ms (legacy exact)");
            }
        } catch (RuntimeException e) {
            Log.w(TAG, "Cannot schedule poll alarm", e);
        }
    }

    private static void cancelPollAlarm(Context context) {
        AlarmManager manager = (AlarmManager) context.getSystemService(Context.ALARM_SERVICE);
        if (manager == null) return;
        try {
            manager.cancel(pollAlarmIntent(context));
        } catch (RuntimeException e) {
            Log.w(TAG, "Cannot cancel poll alarm", e);
        }
    }

    private void runAutonomousPoll() {
        if (!tryBeginPoll()) {
            return;
        }
        final Context appContext = getApplicationContext();
        POLL_EXECUTOR.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    processPollResult(appContext, pollNotifications(appContext));
                } finally {
                    endPoll();
                }
            }
        });
    }

    private static void processPollResult(Context context, PollResult result) {
        if (!result.hasTargets) {
            Log.i(TAG, "poll finished: no targets, stopping service");
            stop(context);
            return;
        }
        if (result.total > 0) {
            showNewMessages(context, result.total);
        } else if (result.anySuccess) {
            cancelMessageNotification(context);
        }
    }

    // ── Опрос notify_count по snapshot'у ────────────────────────────────
    // Источник данных — только in-memory snapshot. Никаких файлов с диска,
    // никакого SQLCipher. Пустой snapshot ⇒ нет целей ⇒ сервис остановится
    // (UI запушит свежий после следующего unlock'а).
    private static PollResult pollNotifications(Context context) {
        if (isApplicationForeground(context)) {
            Log.i(TAG, "poll skipped: application is foreground");
            return PollResult.withTargets(false);
        }
        if (!networkAvailable(context)) {
            Log.i(TAG, "poll skipped: no network");
            return PollResult.withTargets(false);
        }
        if (!loadNativeLibrary()) {
            return PollResult.withTargets(false);
        }
        if (!ensureParanoiaInitialized(context)) {
            return PollResult.withTargets(false);
        }

        Snapshot snapshot = SNAPSHOT.get();
        if (snapshot == null || snapshot.isEmpty()) {
            Log.i(TAG, "poll skipped: snapshot is empty");
            return new PollResult();  // hasTargets=false → service stops
        }

        PollResult result = new PollResult();
        result.hasTargets = true;
        int dialogIndex = 0;
        for (ProfileHint profile : snapshot.profiles) {
            for (DialogHint dialog : profile.dialogs) {
                long count = paranoiaServiceNotifyCount(
                    profile.serverUrl, profile.reserveUrlsJson, profile.signingKeyB64,
                    profile.senderServerId, dialog.partnerServerId, dialog.seq);
                if (count < 0) {
                    Log.w(TAG, "service notify_count failed [dialog #" + dialogIndex + "]: "
                            + paranoiaLastError());
                    dialogIndex++;
                    continue;
                }
                result.anySuccess = true;
                result.total += count;
                if (count > 0) result.pendingPeers++;
                dialogIndex++;
            }
        }
        Log.i(TAG, "snapshot poll finished: total=" + result.total
                + " pendingPeers=" + result.pendingPeers + " dialogs=" + dialogIndex);
        return result;
    }

    private static void handleSnapshotIntent(Intent intent) {
        if (intent == null) return;
        String json = intent.getStringExtra(EXTRA_SNAPSHOT_JSON);
        if (json == null || json.isEmpty()) {
            SNAPSHOT.set(Snapshot.empty());
            Log.i(TAG, "snapshot cleared (empty JSON)");
            return;
        }
        try {
            JSONObject root = new JSONObject(json);
            JSONArray rawProfiles = root.optJSONArray("profiles");
            if (rawProfiles == null) rawProfiles = new JSONArray();
            List<ProfileHint> profiles = new ArrayList<>();
            for (int i = 0; i < rawProfiles.length(); i++) {
                JSONObject p = rawProfiles.optJSONObject(i);
                if (p == null) continue;
                String server = p.optString("server").trim();
                String signingKey = p.optString("signingKeyB64").trim();
                String sender = p.optString("senderServerId").trim();
                if (server.isEmpty() || signingKey.isEmpty() || sender.isEmpty()) continue;

                JSONArray reserves = p.optJSONArray("reserveUrls");
                String reservesJson = reserves != null ? reserves.toString() : "[]";

                JSONArray rawDialogs = p.optJSONArray("dialogs");
                if (rawDialogs == null) rawDialogs = new JSONArray();
                List<DialogHint> dialogs = new ArrayList<>();
                for (int j = 0; j < rawDialogs.length(); j++) {
                    JSONObject d = rawDialogs.optJSONObject(j);
                    if (d == null) continue;
                    String partner = d.optString("partnerServerId").trim();
                    if (partner.isEmpty()) continue;
                    long seq = d.optLong("seq", 0L);
                    dialogs.add(new DialogHint(partner, seq < 0 ? 0 : seq));
                }
                if (dialogs.isEmpty()) continue;

                profiles.add(new ProfileHint(server, reservesJson, signingKey, sender, dialogs));
            }
            SNAPSHOT.set(new Snapshot(profiles));
            int total = 0;
            for (ProfileHint p : profiles) total += p.dialogs.size();
            Log.i(TAG, "snapshot updated: profiles=" + profiles.size() + " dialogs=" + total);
        } catch (JSONException e) {
            Log.w(TAG, "Cannot parse snapshot JSON", e);
        }
    }

    private static boolean ensureParanoiaInitialized(Context context) {
        if (paranoiaInitialized) return true;
        synchronized (ParanoiaForegroundService.class) {
            if (paranoiaInitialized) return true;
            if (!paranoiaInit(context.getApplicationContext())) {
                Log.w(TAG, "paranoia_android_init failed: " + paranoiaLastError());
                return false;
            }
            paranoiaInitialized = true;
        }
        return true;
    }

    private static boolean loadNativeLibrary() {
        if (nativeLibraryLoaded) {
            return true;
        }
        synchronized (ParanoiaForegroundService.class) {
            if (nativeLibraryLoaded) {
                return true;
            }
            if (nativeLibraryLoadAttempted) {
                return false;
            }
            nativeLibraryLoadAttempted = true;
            // Грузим маленькую .so без Qt-зависимостей. Перебираем supported
            // ABIs для совместимости с multi-arch APK; первое имя, которое
            // System.loadLibrary разрулит, — наше.
            List<String> names = new ArrayList<>();
            for (String abi : Build.SUPPORTED_ABIS) {
                if (abi != null && !abi.isEmpty()) {
                    names.add("ParanoiaService_" + abi);
                }
            }
            names.add("ParanoiaService");
            for (String name : names) {
                try {
                    System.loadLibrary(name);
                    nativeLibraryLoaded = true;
                    Log.i(TAG, "loaded native library: " + name);
                    return true;
                } catch (UnsatisfiedLinkError e) {
                    Log.i(TAG, "cannot load native library " + name + ": " + e.getMessage());
                }
            }
            Log.w(TAG, "ParanoiaService native library is not available for background polling");
            return false;
        }
    }

    private static boolean networkAvailable(Context context) {
        ConnectivityManager manager = (ConnectivityManager) context.getSystemService(Context.CONNECTIVITY_SERVICE);
        if (manager == null) {
            return true;
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Network network = manager.getActiveNetwork();
            if (network == null) {
                return false;
            }
            NetworkCapabilities capabilities = manager.getNetworkCapabilities(network);
            return capabilities != null && capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET);
        }
        NetworkInfo info = manager.getActiveNetworkInfo();
        return info != null && info.isConnected();
    }

    private static void startServiceCompat(Context context, Intent intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent);
        } else {
            context.startService(intent);
        }
    }

    private static boolean isApplicationForeground(Context context) {
        appForeground = prefs(context).getBoolean(PREF_APP_FOREGROUND, appForeground);
        return appForeground;
    }

    private static boolean serviceRequested(Context context) {
        return prefs(context).getBoolean(PREF_SERVICE_REQUESTED, false);
    }

    private static Notification.Builder notificationBuilder(Context context, String channelId) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            return new Notification.Builder(context, channelId);
        }
        return new Notification.Builder(context);
    }

    private static Notification buildNotification(Notification.Builder builder) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN) {
            return builder.build();
        }
        return builder.getNotification();
    }

    private static void ensureChannels(Context context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return;
        }
        NotificationManager manager = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
        if (manager == null) {
            return;
        }
        NotificationChannel polling = new NotificationChannel(
                CHANNEL_ID,
                "Paranoia polling",
                NotificationManager.IMPORTANCE_LOW);
        polling.setDescription("Фоновая проверка новых сообщений");
        polling.setShowBadge(false);
        manager.createNotificationChannel(polling);

        NotificationChannel messages = new NotificationChannel(
                MESSAGE_CHANNEL_ID,
                "Paranoia messages",
                NotificationManager.IMPORTANCE_DEFAULT);
        messages.setDescription("Уведомления о новых сообщениях без раскрытия отправителя");
        manager.createNotificationChannel(messages);
    }

    // Уведомление открывает QtActivity напрямую — тем же интентом, что и иконка
    // лаунчера (ACTION_MAIN + CATEGORY_LAUNCHER + NEW_TASK). Никакого activity-
    // trampoline'а: отдельная LaunchActivity роняла QtActivity в собственную
    // task, а Qt — singleton на процесс и второй QtActivity-инстанс приводил к
    // зависанию. EXTRA_OPEN_* кладём в интент: при холодном старте QtActivity
    // их видно через getIntent() (см. takeOpenTarget).
    private static PendingIntent openAppIntent(Context context, int requestCode, String profileId, String peer) {
        Intent launchIntent = new Intent(Intent.ACTION_MAIN);
        launchIntent.addCategory(Intent.CATEGORY_LAUNCHER);
        launchIntent.setClassName(context, "app.paranoia.client.ParanoiaActivity");
        launchIntent.setPackage(context.getPackageName());
        launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        if (profileId != null && !profileId.isEmpty()) {
            launchIntent.putExtra(EXTRA_OPEN_PROFILE_ID, profileId);
        }
        if (peer != null && !peer.isEmpty()) {
            launchIntent.putExtra(EXTRA_OPEN_PEER, peer);
        }
        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags |= PendingIntent.FLAG_IMMUTABLE;
        }
        return PendingIntent.getActivity(context, requestCode, launchIntent, flags);
    }

    public static String takeOpenTarget(Context context) {
        String profileId = "";
        String peer = "";
        if (context instanceof Activity) {
            Intent intent = ((Activity) context).getIntent();
            if (intent != null) {
                profileId = valueOrEmpty(intent.getStringExtra(EXTRA_OPEN_PROFILE_ID));
                peer = valueOrEmpty(intent.getStringExtra(EXTRA_OPEN_PEER));
                intent.removeExtra(EXTRA_OPEN_PROFILE_ID);
                intent.removeExtra(EXTRA_OPEN_PEER);
            }
        }
        if (peer.isEmpty()) {
            SharedPreferences prefs = prefs(context);
            profileId = prefs.getString(PREF_OPEN_PROFILE_ID, "");
            peer = prefs.getString(PREF_OPEN_PEER, "");
            prefs.edit().remove(PREF_OPEN_PROFILE_ID).remove(PREF_OPEN_PEER).apply();
        }
        if (peer == null || peer.isEmpty()) {
            return "";
        }
        return valueOrEmpty(profileId) + "\n" + peer;
    }

    public static String takeOpenPeer(Context context) {
        String target = takeOpenTarget(context);
        int separator = target.indexOf('\n');
        return separator >= 0 ? target.substring(separator + 1) : target;
    }

    private static void requestPostNotificationsIfNeeded(Context context) {
        if (Build.VERSION.SDK_INT < 33 || !(context instanceof Activity)) {
            return;
        }
        Activity activity = (Activity) context;
        if (activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            return;
        }
        activity.requestPermissions(new String[] { Manifest.permission.POST_NOTIFICATIONS }, 2026);
    }

    private static boolean notificationsAllowed(Context context) {
        if (Build.VERSION.SDK_INT < 33) {
            return true;
        }
        return context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED;
    }

    private static void cancelMessageNotification(Context context) {
        NotificationManager manager = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
        if (manager != null) {
            manager.cancel(MESSAGE_NOTIFICATION_ID);
        }
    }

    // Публичная точка входа для C++ (см. PlatformNotifications::clearAccumulatedNotifications).
    // Чистит все message-карточки при ручном открытии приложения, даже если событие
    // PREF_APP_FOREGROUND ещё не прошло через сервисный Intent.
    public static void clearMessageNotifications(Context context) {
        if (context == null) return;
        cancelMessageNotification(context);
    }

    private static SharedPreferences prefs(Context context) {
        return context.getApplicationContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    private static String valueOrEmpty(String value) {
        return value == null ? "" : value;
    }

    private static final class PollResult {
        boolean hasTargets;
        boolean anySuccess;
        long total;
        int pendingPeers;
        String profileId = "";
        String peer = "";

        static PollResult withTargets(boolean anySuccess) {
            PollResult result = new PollResult();
            result.hasTargets = true;
            result.anySuccess = anySuccess;
            return result;
        }
    }
}
