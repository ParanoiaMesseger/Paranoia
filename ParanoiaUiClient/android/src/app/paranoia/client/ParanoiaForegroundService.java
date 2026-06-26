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
    // UI сообщает, что САМ опрашивает звонки (foreground/активный звонок). Доставляем
    // ИНТЕНТОМ (а не cross-process prefs — те ненадёжны: :notifications читает свой
    // устаревший кэш), чтобы фон-сервис писал флаг в СВОЁМ процессе и читал верно.
    private static final String ACTION_SET_UI_CALL_POLLING = "app.paranoia.client.SET_UI_CALL_POLLING";
    private static final String EXTRA_UI_CALL_POLLING = "app.paranoia.client.UI_CALL_POLLING";
    private static final String EXTRA_APP_FOREGROUND = "app.paranoia.client.APP_FOREGROUND";
    private static final String EXTRA_SNAPSHOT_JSON = "app.paranoia.client.SNAPSHOT_JSON";
    private static final int POLL_ALARM_REQUEST = 2027;
    private static final String PREFS = "paranoia_notifications";
    private static final String PREF_APP_FOREGROUND = "app_foreground";
    // Дедлайн (elapsedRealtime, ms) до которого флаг foreground считается валидным.
    // UI шлёт heartbeat раз в 60с; TTL 150с даёт запас на 1 пропуск. Если UI-процесс
    // упал/убит «активным», флаг истечёт и сервис возобновит фоновый опрос (раньше
    // флаг залипал в true → уведомления молча терялись до перезапуска приложения).
    private static final String PREF_APP_FOREGROUND_UNTIL = "app_foreground_until";
    private static final long APP_FOREGROUND_TTL_MS = 150_000L;
    private static final String PREF_SERVICE_REQUESTED = "service_requested";
    private static final String PREF_OPEN_PROFILE_ID = "open_profile_id";
    private static final String PREF_OPEN_PEER = "open_peer";
    // Отложенный конверт входящего звонка (#6 handoff): фон-процесс пишет в prefs
    // (cross-process), UI-процесс забирает при открытии и поднимает экран вызова.
    private static final String PREF_CALL_OFFER = "pending_call_offer";
    // Время сохранения оффера (elapsedRealtime, ms). Оффер «протухает»: звонок
    // звенит недолго, а несработавший/сброшенный оффер мог залежаться в prefs и
    // потом инжектнуться в открытое приложение, заняв состояние мёртвым звонком →
    // реальные входящие отбивались как BUSY. Старше TTL — выбрасываем.
    private static final String PREF_CALL_OFFER_TS = "pending_call_offer_ts";
    // call_id показанного/сохранённого оффера — чтобы по Hangup(kind=2) понять, что
    // ИМЕННО этот звонок отменён, и погасить баннер + стереть оффер (иначе на входе
    // в приложение инжектился экран уже отменённого звонка).
    private static final String PREF_CALL_OFFER_CALLID = "pending_call_offer_callid";
    private static final long CALL_OFFER_TTL_MS = 60_000L;
    // Дедлайн (elapsedRealtime, ms), пока которого ОПРОС ЗВОНКОВ ведёт UI-процесс
    // (его in-app сигналинг активен: foreground или идёт звонок). Фон-сервис в это
    // время НЕ опрашивает call_poll — иначе два поллера дерутся за drain-эндпоинт
    // и UI-клиент «съедал» оффер, показывая невидимый экран вместо баннера.
    // UI шлёт heartbeat (~30с), TTL 90с — переживает 1-2 пропуска; на падении UI
    // флаг истекает и фон-сервис снова берёт звонки на себя.
    private static final String PREF_UI_CALL_POLLING_UNTIL = "ui_call_polling_until";
    private static final long UI_CALL_POLLING_TTL_MS = 90_000L;
    private static final String TAG = "ParanoiaService";
    private static final int FOREGROUND_NOTIFICATION_ID = 1001;
    private static final int MESSAGE_NOTIFICATION_ID = 1002;
    // Входящие звонки в фоне (#6): баннер высокого приоритета с кнопками.
    private static final String CALL_CHANNEL_ID = "paranoia_calls";
    private static final int CALL_NOTIFICATION_ID = 1003;
    private static final String ACTION_CALL_DISMISS = "app.paranoia.client.CALL_DISMISS";
    private static final String EXTRA_CALL_ID = "app.paranoia.client.CALL_ID";
    // Конверт оффера передаём в UI ИМЕННО через intent-extra (надёжный
    // cross-process канал; SharedPreferences между процессами ненадёжен) +
    // prefs как fallback для тёплого резюма.
    private static final String EXTRA_CALL_OFFER = "app.paranoia.client.CALL_OFFER";
    // Флаг «пользователь нажал ОТВЕТИТЬ в баннере» (а не просто тапнул тело):
    // после ввода PIN звонок принимается автоматически, без второго тапа на экране.
    private static final String EXTRA_CALL_ANSWER = "app.paranoia.client.CALL_ANSWER";
    // Уже показанные офферы (по call_id) — чтобы один звонок не звенел на каждом poll'е.
    private static final java.util.Set<String> SEEN_CALL_IDS =
            java.util.Collections.synchronizedSet(new java.util.HashSet<String>());
    // МГНОВЕННЫЕ СООБЩЕНИЯ: per-диалог message long-poll параллельно с call-poll'ом.
    // Отдельный пул (cached, растёт под число диалогов; long-poll возвращается за
    // ≤15с server-cap / ≤60с request-timeout — потоки НЕ виснут). Set — диалоги, по
    // которым сейчас висит long-poll, чтобы не плодить дубли.
    private static final java.util.concurrent.ExecutorService MSG_EXECUTOR =
            java.util.concurrent.Executors.newCachedThreadPool();
    private static final java.util.Set<String> MSG_INFLIGHT =
            java.util.concurrent.ConcurrentHashMap.newKeySet();
    // Высшая «увиденная» seq по диалогу: long-poll опрашивает с НЕЁ (а не с фикс.
    // snapshot.seq), иначе при бэклоге непрочитанных сервер сразу возвращает count>0
    // → tight-loop / задержка новых на бэкофф. Двигая seq за уже посчитанные, ждём
    // ГЕНУИННО новые → мгновенно даже при непрочитанных. Уведомление-итог всё равно
    // считает pollNotifications от реальной last_pulled seq.
    private static final java.util.concurrent.ConcurrentHashMap<String, Long> MSG_SEEN_SEQ =
            new java.util.concurrent.ConcurrentHashMap<>();
    private static final long MSG_LONG_POLL_MS = 15_000L;
    private static final long POLL_INTERVAL_MS = 60_000L;
    // Если poll не завершился за это время — считаем его зависшим (несмотря на
    // 60s request-timeout в Rust) и разрешаем стартовать новый. Зависший поток
    // утечёт, но cached pool не даст ему заблокировать следующие опросы.
    // Совпадает с потолком wakelock'а (75с): если poll завис, не блокируем
    // следующий цикл дольше необходимого (раньше 120с > 60с интервала → каждый
    // второй опрос мог пропускаться tryBeginPoll на медленной сети).
    private static final long POLL_HARD_TIMEOUT_MS = 75_000L;

    // ОГРАНИЧЕННЫЙ пул: при "тихой" потере сети (TCP blackhole) нативный вызов мог
    // висеть минутами; cached-pool плодил бы новые потоки без предела →
    // OutOfMemoryError: pthread_create. Guard'ы (tryBeginPoll/tryBeginCallPoll)
    // и так держат не более 1 msg- + 1 call-poll одновременно; 4 слота с запасом.
    private static final ExecutorService POLL_EXECUTOR = Executors.newFixedThreadPool(4);
    // Время старта текущего poll'а (мс), 0 = poll не идёт. Раньше тут был
    // AtomicBoolean — но один зависший сетевой вызов оставлял его в true
    // навсегда, и сервис переставал опрашивать совсем.
    private static final AtomicLong pollStartedAtMs = new AtomicLong(0L);
    // ОТДЕЛЬНЫЙ in-flight для call-poll (#6): его 30-сек long-poll НЕ должен держать
    // слот опроса СООБЩЕНИЙ — иначе при медленной сети следующий msg-poll
    // пропускался tryBeginPoll и уведомления опаздывали (регрессия). Свой guard
    // + свой wakelock полностью расцепляют звонки от сообщений.
    private static final AtomicLong callPollStartedAtMs = new AtomicLong(0L);
    private static volatile boolean started = false;
    private static volatile boolean appForeground = false;
    // true ТОЛЬКО когда snapshot пуст из-за ЯВНОГО logout/clear из UI. Пустой
    // snapshot из-за рестарта процесса (ещё не пришёл) — НЕ повод останавливать
    // сервис (раньше любой пустой snapshot → stop() + сброс service_requested →
    // сервис умирал навсегда). Различаем «временно пусто» и «осознанно очищено».
    private static volatile boolean snapshotExplicitlyCleared = false;
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
    // Как notifyCount, но long-poll: сервер держит до нового сообщения / longPollMs.
    private static native long paranoiaServiceNotifyCountWait(String serverUrl, String reserveUrlsJson,
                                                              String signingKeyB64, String senderServerId,
                                                              String partnerServerId, long seq, int longPollMs);
    // MULTI-notify long-poll: ОДИН запрос на N диалогов вместо N. itemsJson —
    // [{"partner","seq"}, …]; возвращает JSON [{"partner","n"}, …] зажжённых (n>0)
    // или null при ошибке. Снимает «N диалогов = N запросов» в фон-сервисе.
    private static native String paranoiaServiceNotifyMultiWait(String serverUrl, String reserveUrlsJson,
                                                                String signingKeyB64, String senderServerId,
                                                                String itemsJson, int longPollMs);
    // Stateless опрос входящих звонков → JSON-массив [{sender,kind,payload_json,ts_ms}] или null.
    private static native String paranoiaServiceCallPoll(String serverUrl, String reserveUrlsJson,
                                                         String signingKeyB64, String user,
                                                         String peerKeysJson, int longPollMs);
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
        // JSON-массив [{peer,master_key_b64}] для фонового опроса звонков (call_poll).
        final String peerKeysJson;
        ProfileHint(String serverUrl, String reserveUrlsJson, String signingKeyB64,
                    String senderServerId, List<DialogHint> dialogs, String peerKeysJson) {
            this.serverUrl = serverUrl;
            this.reserveUrlsJson = reserveUrlsJson;
            this.signingKeyB64 = signingKeyB64;
            this.senderServerId = senderServerId;
            this.dialogs = Collections.unmodifiableList(dialogs);
            this.peerKeysJson = peerKeysJson;
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
        long until = foreground ? android.os.SystemClock.elapsedRealtime() + APP_FOREGROUND_TTL_MS : 0L;
        prefs(context).edit()
                .putBoolean(PREF_APP_FOREGROUND, foreground)
                .putLong(PREF_APP_FOREGROUND_UNTIL, until)
                .commit();
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
            // Непустой snapshot пришёл → это НЕ logout; пустой publish трактуем как очистку.
            snapshotExplicitlyCleared = SNAPSHOT.get() == null || SNAPSHOT.get().isEmpty();
        } else if (ACTION_CLEAR_SNAPSHOT.equals(action)) {
            SNAPSHOT.set(Snapshot.empty());
            snapshotExplicitlyCleared = true;
            Log.i(TAG, "snapshot cleared by UI");
        } else if (ACTION_CALL_DISMISS.equals(action)) {
            NotificationManager m = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            if (m != null) m.cancel(CALL_NOTIFICATION_ID);
            // Сброшенный звонок не должен потом инжектнуться в открытое приложение.
            prefs(this).edit().remove(PREF_CALL_OFFER).remove(PREF_CALL_OFFER_TS).remove(PREF_CALL_OFFER_CALLID).apply();
            Log.i(TAG, "incoming call dismissed by user");
        } else if (ACTION_SET_UI_CALL_POLLING.equals(action)) {
            // Пишем флаг в СВОЁМ (:notifications) процессе → uiOwnsCallPolling() читает
            // верно. true → UI сам опрашивает (мы не лезем); false → UI отдал звонки
            // нам, и fall-through triggerPollAndReschedule СРАЗУ стартует наш чейн
            // (без ожидания следующего 60-сек будильника).
            boolean uiActive = intent.getBooleanExtra(EXTRA_UI_CALL_POLLING, false);
            long until = uiActive ? android.os.SystemClock.elapsedRealtime() + UI_CALL_POLLING_TTL_MS : 0L;
            prefs(this).edit().putLong(PREF_UI_CALL_POLLING_UNTIL, until).commit();
        }
        if (intent != null && intent.hasExtra(EXTRA_APP_FOREGROUND)) {
            appForeground = intent.getBooleanExtra(EXTRA_APP_FOREGROUND, appForeground);
            long until = appForeground ? android.os.SystemClock.elapsedRealtime() + APP_FOREGROUND_TTL_MS : 0L;
            prefs(this).edit()
                    .putBoolean(PREF_APP_FOREGROUND, appForeground)
                    .putLong(PREF_APP_FOREGROUND_UNTIL, until)
                    .commit();
        } else {
            appForeground = isApplicationForeground(this);
        }
        ensureChannels(this);
        Notification notification = buildForegroundNotification();
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                // Android 15 (SDK 35) ограничивает dataSync FGS 6 часами/сутки →
                // onTimeout убивает наш постоянный сервис. remoteMessaging — тип FGS
                // для мессенджеров, без этого лимита и без runtime-prerequisites.
                startForeground(FOREGROUND_NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING);
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
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
        started = false;
        stopForeground(true);
        // Отменяем watchdog-alarm ТОЛЬКО при явном стопе (logout). При неявном
        // уничтожении (OEM/system pressure) alarm ОСТАВЛЯЕМ — он разбудит и
        // перезапустит сервис (раньше cancel здесь убивал восстановление навсегда).
        if (!serviceRequested(this)) {
            cancelPollAlarm(this);
        }
        super.onDestroy();
    }

    @Override
    public void onTaskRemoved(Intent rootIntent) {
        Log.i(TAG, "task removed: keep notification service running");
        appForeground = false;
        prefs(this).edit()
                .putBoolean(PREF_APP_FOREGROUND, false)
                .putLong(PREF_APP_FOREGROUND_UNTIL, 0L)
                .commit();
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
        // Отменяем прежний alarm ДО постановки нового: иначе при повторном
        // onStartCommand (start/snapshot/foreground-toggle) к ещё-не-сработавшему
        // alarm'у добавляется новый → два alarm'а, интервал опроса дрейфует.
        cancelPollAlarm(this);
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
    // broadcast'ы с ELAPSED_REALTIME_WAKEUP проходят через эти ограничения и временно
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
            // «Сбросить» из баннера входящего вызова — гасим уведомление и выходим.
            if (intent != null && ACTION_CALL_DISMISS.equals(intent.getAction())) {
                NotificationManager m = (NotificationManager) appContext.getSystemService(Context.NOTIFICATION_SERVICE);
                if (m != null) m.cancel(CALL_NOTIFICATION_ID);
                Log.i(TAG, "incoming call dismissed by user");
                return;
            }
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

            final long pollToken = tryBeginPoll();
            if (pollToken == 0L) {
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
                        executeFullPoll(appContext);
                    } finally {
                        endPoll(pollToken);
                        if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
                    }
                }
            });
        }
    }

    // Разрешает старт нового poll'а, если предыдущего нет либо он висит дольше
    // POLL_HARD_TIMEOUT_MS (считаем мёртвым). Возвращает ТОКЕН старта (монотонное
    // время, !=0) или 0L, если poll уже идёт. Токен нужен endPoll'у: лок снимаем
    // ТОЛЬКО если он всё ещё наш (compareAndSet). Иначе зависший по хард-таймауту
    // старый поток, завершившись, обнулял бы лок, уже принадлежащий новому poll'у
    // → параллельные накладывающиеся опросы.
    private static long tryBeginPoll() {
        long now = android.os.SystemClock.elapsedRealtime();
        if (now == 0L) now = 1L;
        while (true) {
            final long started = pollStartedAtMs.get();
            if (started != 0L && now - started < POLL_HARD_TIMEOUT_MS) {
                return 0L;
            }
            if (pollStartedAtMs.compareAndSet(started, now)) {
                if (started != 0L) {
                    Log.w(TAG, "previous poll exceeded hard timeout; starting a fresh one");
                }
                return now;
            }
        }
    }

    private static void endPoll(long token) {
        if (token != 0L) pollStartedAtMs.compareAndSet(token, 0L);
    }

    // Отдельный in-flight guard для call-poll (хард-таймаут чуть выше его long-poll).
    // Токен — как у tryBeginPoll: снимаем лок только если он наш.
    private static long tryBeginCallPoll() {
        long now = android.os.SystemClock.elapsedRealtime();
        if (now == 0L) now = 1L;
        while (true) {
            final long started = callPollStartedAtMs.get();
            if (started != 0L && now - started < 45_000L) return 0L;
            if (callPollStartedAtMs.compareAndSet(started, now)) return now;
        }
    }

    private static void endCallPoll(long token) {
        if (token != 0L) callPollStartedAtMs.compareAndSet(token, 0L);
    }

    // Запустить call-poll ОТДЕЛЬНОЙ задачей со своим wakelock — не блокируя слот и
    // wakelock опроса сообщений (тот завершается быстро, как до #6). Звонки в фоне
    // — best-effort (Doze), но сообщения больше не ждут 30-сек long-poll звонка.
    private static void scheduleCallPoll(final Context appContext) {
        // Если живой UI сам опрашивает звонки (foreground/активный звонок) — не лезем
        // в call_poll, чтобы не «увести» оффер у in-app клиента (drain-эндпоинт: один
        // читатель). Когда UI уходит в фон/умирает — флаг гаснет, и звонки берём мы.
        if (uiOwnsCallPolling(appContext)) {
            return;
        }
        final long callToken = tryBeginCallPoll();
        if (callToken == 0L) return;
        PowerManager pm = (PowerManager) appContext.getSystemService(Context.POWER_SERVICE);
        final PowerManager.WakeLock wakeLock = pm == null ? null
                : pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "paranoia:callpoll");
        if (wakeLock != null) {
            wakeLock.setReferenceCounted(false);
            wakeLock.acquire(45_000L);
        }
        POLL_EXECUTOR.execute(new Runnable() {
            @Override
            public void run() {
                final long startedAt = android.os.SystemClock.elapsedRealtime();
                try {
                    Snapshot snap = SNAPSHOT.get();
                    if (snap != null) pollCalls(appContext, snap);
                } finally {
                    endCallPoll(callToken);
                    if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
                }
                // ЧЕЙНИМ call-poll, пока приложение в фоне и есть цели: сервер капает
                // long-poll на 30с (MAX_LONG_POLL_MS), поэтому это back-to-back 30-сек
                // long-poll'ы = НЕПРЕРЫВНОЕ покрытие входящих (а не дыра 30с между
                // 60-сек будильниками → задержка до ~минуты). Это сознательный размен
                // батарея↔скорость: без push другого способа real-time-приёма нет, а
                // фон-приём и так требует отключения battery-optimization. В Doze
                // процесс замораживается → чейн встаёт, добивает рекуррентный alarm.
                // Выходим, если: сервис не нужен / приложение на переднем плане
                // (звонок ведёт in-app) / UI сам опрашивает / нет целей.
                // NB: НЕ используем serviceRequested() — PREF_SERVICE_REQUESTED пишет
                // только main-процесс, а :notifications читает свой устаревший кэш
                // (cross-process SharedPreferences ненадёжен). Мы выполняемся ВНУТРИ
                // живого сервиса, значит он запущен; на logout SNAPSHOT чистится
                // (ACTION_CLEAR_SNAPSHOT) → isEmpty() остановит чейн.
                Snapshot snap2 = SNAPSHOT.get();
                boolean fg = isApplicationForeground(appContext);
                boolean uiOwns = uiOwnsCallPolling(appContext);
                boolean hasTargets = snap2 != null && !snap2.isEmpty();
                boolean keepChaining = !fg && !uiOwns && hasTargets;
                if (keepChaining) {
                    // Если опрос вернулся слишком быстро (ошибка/нет сети) — пауза, чтобы
                    // не молотить сервер; нормальный long-poll длится ~30с.
                    long elapsed = android.os.SystemClock.elapsedRealtime() - startedAt;
                    if (elapsed < 5_000L) {
                        try { Thread.sleep(5_000L); } catch (InterruptedException ignore) { return; }
                        if (isApplicationForeground(appContext) || uiOwnsCallPolling(appContext)) {
                            return;
                        }
                    }
                    scheduleCallPoll(appContext);
                }
            }
        });
    }

    private static void schedulePollAlarm(Context context, long delayMs) {
        AlarmManager manager = (AlarmManager) context.getSystemService(Context.ALARM_SERVICE);
        if (manager == null) {
            Log.w(TAG, "AlarmManager unavailable; cannot schedule next poll");
            return;
        }
        // Монотонные часы (elapsedRealtime), а не wall-clock: ручная смена времени/
        // NTP/оператор не должны сдвигать интервал опроса.
        long when = android.os.SystemClock.elapsedRealtime() + Math.max(1000L, delayMs);
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
                manager.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, when, pi);
                Log.i(TAG, "next poll scheduled in " + delayMs + "ms (exact, allow while idle)");
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                manager.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, when, pi);
                Log.i(TAG, "next poll scheduled in " + delayMs + "ms (inexact, allow while idle; exact not granted)");
            } else {
                manager.setExact(AlarmManager.ELAPSED_REALTIME_WAKEUP, when, pi);
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
        final long pollToken = tryBeginPoll();
        if (pollToken == 0L) {
            return;
        }
        final Context appContext = getApplicationContext();
        POLL_EXECUTOR.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    executeFullPoll(appContext);
                } finally {
                    endPoll(pollToken);
                }
            }
        });
    }

    // Полный цикл: сообщения → показ уведомления → ПОТОМ call-poll. Сообщения
    // показываются ДО длинного (30с) call-poll'а, поэтому он их не задерживает
    // (следующий alarm уже запланирован заранее). Зовётся И из alarm-пути
    // (PollAlarmReceiver — рекуррентный, переживает Doze), И из runAutonomousPoll.
    private static void executeFullPoll(Context appContext) {
        PollResult r = pollNotifications(appContext);
        processPollResult(appContext, r);
        // Слот/wakelock сообщений освобождается СРАЗУ (как до #6) — call-poll уходит
        // в свою задачу со своим guard'ом/wakelock'ом и не задерживает уведомления.
        if (r.hasTargets) {
            scheduleCallPoll(appContext);
            startMessageLongPolls(appContext); // мгновенные сообщения, параллельно
        }
    }

    // МГНОВЕННЫЕ СООБЩЕНИЯ в фоне: ОДИН multi-notify long-poll на ВЕСЬ профиль
    // (сервер держит до нового сообщения в ЛЮБОМ из диалогов и возвращает все
    // зажжённые). Раньше был поток-на-диалог → N потоков/N запросов/N wakelock'ов;
    // теперь 1 поток на профиль. Снимает «N диалогов = N запросов» (батарея).
    // Самоперезапускающийся чейн, пока приложение в фоне.
    private static void startMessageLongPolls(final Context appContext) {
        if (isApplicationForeground(appContext) || uiOwnsCallPolling(appContext)) return;
        Snapshot snap = SNAPSHOT.get();
        if (snap == null || snap.isEmpty()) return;
        for (ProfileHint profile : snap.profiles) {
            if (profile.dialogs.isEmpty()) continue;
            spawnProfileLongPoll(appContext, profile);
        }
    }

    // Сформировать items JSON [{"partner","seq"}] для multi-notify. useSeenSeq=true —
    // курсор = max(snapshot.seq, MSG_SEEN_SEQ) (мгновенный long-poll, чтобы не
    // тайт-лупить на бэклоге непрочитанного); false — ровно snapshot.seq (периодика).
    private static String buildItemsJson(ProfileHint profile, boolean useSeenSeq) {
        JSONArray arr = new JSONArray();
        for (DialogHint d : profile.dialogs) {
            long seq = d.seq;
            if (useSeenSeq) {
                Long seen = MSG_SEEN_SEQ.get(profile.senderServerId + "|" + d.partnerServerId);
                if (seen != null && seen > seq) seq = seen;
            }
            try {
                JSONObject o = new JSONObject();
                o.put("partner", d.partnerServerId);
                o.put("seq", seq);
                arr.put(o);
            } catch (JSONException ignore) {}
        }
        return arr.toString();
    }

    private static ProfileHint findProfile(Snapshot s, String senderServerId) {
        if (s == null || senderServerId == null) return null;
        for (ProfileHint p : s.profiles) {
            if (senderServerId.equals(p.senderServerId)) return p;
        }
        return null;
    }

    private static void spawnProfileLongPoll(final Context appContext, final ProfileHint profile) {
        final String key = profile.senderServerId; // один in-flight long-poll на профиль
        if (!MSG_INFLIGHT.add(key)) return;
        MSG_EXECUTOR.execute(new Runnable() {
            @Override
            public void run() {
                final long startedAt = android.os.SystemClock.elapsedRealtime();
                // Курсоры, с которыми реально опрашиваем (для сдвига seen по зажжённым).
                final java.util.HashMap<String, Long> polled = new java.util.HashMap<>();
                JSONArray items = new JSONArray();
                for (DialogHint d : profile.dialogs) {
                    long seq = d.seq;
                    Long seen = MSG_SEEN_SEQ.get(profile.senderServerId + "|" + d.partnerServerId);
                    if (seen != null && seen > seq) seq = seen;
                    polled.put(d.partnerServerId, seq);
                    try {
                        JSONObject o = new JSONObject();
                        o.put("partner", d.partnerServerId);
                        o.put("seq", seq);
                        items.put(o);
                    } catch (JSONException ignore) {}
                }
                PowerManager pm = (PowerManager) appContext.getSystemService(Context.POWER_SERVICE);
                PowerManager.WakeLock wl = pm == null ? null
                        : pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "paranoia:msgpoll");
                if (wl != null) { wl.setReferenceCounted(false); wl.acquire(30_000L); }
                String litJson = null;
                try {
                    litJson = paranoiaServiceNotifyMultiWait(
                            profile.serverUrl, profile.reserveUrlsJson, profile.signingKeyB64,
                            profile.senderServerId, items.toString(), (int) MSG_LONG_POLL_MS);
                } catch (Throwable t) {
                    // stale-процесс после апдейта без нового нативного символа — пропускаем.
                    Log.w(TAG, "notify_multi_wait native unavailable — skipping message poll", t);
                } finally {
                    if (wl != null && wl.isHeld()) wl.release();
                    MSG_INFLIGHT.remove(key);
                }
                boolean anyLit = false;
                if (litJson != null) {
                    try {
                        JSONArray arr = new JSONArray(litJson);
                        for (int i = 0; i < arr.length(); i++) {
                            JSONObject o = arr.getJSONObject(i);
                            String partner = o.optString("partner", "");
                            long n = o.optLong("n", 0L);
                            if (partner.isEmpty() || n <= 0) continue;
                            anyLit = true;
                            // Сдвигаем высшую seq за посчитанные → следующий long-poll ждёт
                            // ГЕНУИННО новые (без tight-loop при непрочитанных).
                            Long base = polled.get(partner);
                            MSG_SEEN_SEQ.put(profile.senderServerId + "|" + partner,
                                    (base != null ? base : 0L) + n);
                        }
                    } catch (JSONException e) {
                        Log.w(TAG, "bad notify_multi_wait json", e);
                    }
                }
                if (anyLit) {
                    // Итог-уведомление считает pollNotifications от реальной snapshot.seq.
                    PollResult r = pollNotifications(appContext);
                    processPollResult(appContext, r);
                }
                // Перезапуск, пока в фоне. Лёгкая пауза ТОЛЬКО если опрос вернулся
                // подозрительно быстро (ошибка/сеть/сервер не держал long-poll).
                if (isApplicationForeground(appContext) || uiOwnsCallPolling(appContext)) return;
                Snapshot s = SNAPSHOT.get();
                if (s == null || s.isEmpty()) return;
                long elapsed = android.os.SystemClock.elapsedRealtime() - startedAt;
                if (litJson == null || elapsed < 3_000L) {
                    try { Thread.sleep(5_000L); } catch (InterruptedException ignore) { return; }
                    if (isApplicationForeground(appContext) || uiOwnsCallPolling(appContext)) return;
                }
                // Перечитываем профиль из свежего snapshot (диалоги могли измениться,
                // напр. лениво добавился корп-диалог) → новые диалоги попадают в poll ≤ цикл.
                ProfileHint fresh = findProfile(SNAPSHOT.get(), profile.senderServerId);
                if (fresh != null && !fresh.dialogs.isEmpty()) spawnProfileLongPoll(appContext, fresh);
            }
        });
    }

    private static void processPollResult(Context context, PollResult result) {
        if (!result.hasTargets) {
            // НЕ останавливаем сервис на ВРЕМЕННЫХ условиях (app foreground, нет сети,
            // native не загрузился, snapshot ещё не пришёл после рестарта процесса) —
            // раньше это валило сервис навсегда (+ сбрасывало service_requested). Стоп
            // ТОЛЬКО при осознанном logout/clear из UI.
            if (snapshotExplicitlyCleared) {
                Log.i(TAG, "poll: snapshot explicitly cleared (logout) — stopping service");
                stop(context);
            } else {
                Log.i(TAG, "poll skipped (transient: foreground/no-net/native/empty-after-restart) — keeping service alive");
            }
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
        int dialogCount = 0;
        // ОДИН multi-notify на профиль вместо N одиночных (батарея). Сервер по форме
        // запроса различает режим; зажжённые (n>0) возвращаются списком.
        for (ProfileHint profile : snapshot.profiles) {
            if (profile.dialogs.isEmpty()) continue;
            dialogCount += profile.dialogs.size();
            String itemsJson = buildItemsJson(profile, false); // периодика: курсор = snapshot.seq
            String litJson = null;
            try {
                litJson = paranoiaServiceNotifyMultiWait(
                        profile.serverUrl, profile.reserveUrlsJson, profile.signingKeyB64,
                        profile.senderServerId, itemsJson, 0);
            } catch (Throwable t) {
                // stale-процесс после апдейта без нового нативного символа — пропускаем.
                Log.w(TAG, "notify_multi native unavailable — skipping snapshot poll", t);
            }
            if (litJson == null) {
                Log.w(TAG, "service notify_multi failed: " + paranoiaLastError());
                continue;
            }
            result.anySuccess = true;
            try {
                JSONArray arr = new JSONArray(litJson);
                for (int i = 0; i < arr.length(); i++) {
                    JSONObject o = arr.getJSONObject(i);
                    long n = o.optLong("n", 0L);
                    if (n > 0) { result.total += n; result.pendingPeers++; }
                }
            } catch (JSONException e) {
                Log.w(TAG, "bad notify_multi json", e);
            }
        }
        Log.i(TAG, "snapshot poll finished: total=" + result.total
                + " pendingPeers=" + result.pendingPeers + " dialogs=" + dialogCount);
        return result;
    }

    // Stateless опрос входящих звонков по snapshot'у. На каждый НОВЫЙ оффер (kind 0)
    // показываем баннер «Входящий вызов» с кнопками. Сам звонок поднимается в
    // приложении (фон-процесс без Qt/WebRTC) — баннер будит и открывает UI.
    private static void pollCalls(Context context, Snapshot snapshot) {
        for (ProfileHint profile : snapshot.profiles) {
            if (profile.peerKeysJson == null || profile.peerKeysJson.length() <= 2) continue; // "[]"
            // Long-poll 12с (back-to-back чейн = непрерывное покрытие). КОРОЧЕ 30с
            // СОЗНАТЕЛЬНО: при переходе приложения в foreground/звонок in-app
            // забирает опрос (uiOwns), но НАШ in-flight poll нельзя прервать — он
            // ещё до ~30с конкурировал с in-app за drain-эндпоинт и мог «увести»
            // Answer/Hangup активного звонка. 12с укорачивает это окно «угона» ~2.5×
            // ценой умеренного роста реконнектов (battery-optimization и так должна
            // быть выключена для фон-звонков). Остаток окна добивают backstop'ы в
            // CallController (media-loss → hangup; media-flow → running).
            String json;
            try {
                json = paranoiaServiceCallPoll(
                        profile.serverUrl, profile.reserveUrlsJson, profile.signingKeyB64,
                        profile.senderServerId, profile.peerKeysJson, 12000);
            } catch (Throwable t) {
                // UnsatisfiedLinkError и т.п.: УСТАРЕВШИЙ процесс :notifications после
                // апдейта держит в памяти СТАРУЮ libParanoiaService без этого символа.
                // НЕ роняем сервис (был FATAL-краш) — пропускаем опрос звонков (опрос
                // сообщений на старой .so ещё работает). Системный установщик при
                // апдейте APK убивает процессы → свежий поднимется с новой .so;
                // артефакт только у dev-инкрементальной установки (adb), не в проде.
                Log.w(TAG, "call_poll native unavailable (stale process after update?) — skipping calls", t);
                return;
            }
            if (json == null) {
                Log.w(TAG, "service call_poll failed: " + paranoiaLastError());
                continue;
            }
            try {
                JSONArray arr = new JSONArray(json);
                for (int i = 0; i < arr.length(); i++) {
                    JSONObject env = arr.optJSONObject(i);
                    if (env == null) continue;
                    int kind = env.optInt("kind", -1);
                    String sender = env.optString("sender").trim();
                    String callId = "";
                    boolean accept = true;
                    try {
                        JSONObject pl = new JSONObject(env.optString("payload_json"));
                        callId = pl.optString("call_id").trim();
                        accept = pl.optBoolean("accept", true);
                    } catch (JSONException ignore) {}
                    if (callId.isEmpty()) callId = sender + ":" + env.optLong("ts_ms", 0L);

                    if (kind == 0) {
                        // Offer.
                        if (SEEN_CALL_IDS.size() > 500) SEEN_CALL_IDS.clear();
                        if (!SEEN_CALL_IDS.add(callId)) continue; // уже звенел
                        Log.i(TAG, "incoming call from " + sender + " call_id=" + callId);
                        // Сохраняем расшифрованный конверт (cross-process) — UI заберёт при
                        // открытии и поднимет звонок (сервер уже drain'нул оффер).
                        prefs(context).edit()
                                .putString(PREF_CALL_OFFER, env.toString())
                                .putLong(PREF_CALL_OFFER_TS, android.os.SystemClock.elapsedRealtime())
                                .putString(PREF_CALL_OFFER_CALLID, callId)
                                .apply();
                        showIncomingCall(context, sender, callId, env.toString());
                    } else if (kind == 2 || (kind == 1 && !accept)) {
                        // Hangup (звонящий отменил) / decline. Если это про ПОКАЗАННЫЙ
                        // нами оффер — гасим баннер и стираем сохранённый конверт, иначе
                        // на входе в приложение поднимется экран уже отменённого звонка.
                        String storedCid = prefs(context).getString(PREF_CALL_OFFER_CALLID, "");
                        if (!callId.isEmpty() && callId.equals(storedCid)) {
                            prefs(context).edit()
                                    .remove(PREF_CALL_OFFER).remove(PREF_CALL_OFFER_TS)
                                    .remove(PREF_CALL_OFFER_CALLID).apply();
                            NotificationManager m = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
                            if (m != null) m.cancel(CALL_NOTIFICATION_ID);
                            Log.i(TAG, "incoming call cancelled by remote (hangup) call_id=" + callId);
                        }
                    }
                }
            } catch (JSONException e) {
                Log.w(TAG, "Cannot parse call_poll JSON", e);
            }
        }
    }

    // Точка входа для UI-процесса (#6, гонка перехода в фон): in-app сигналинг
    // сдрейнил оффер из long-poll'а уже ПОСЛЕ ухода в фон (фон-сервис его не
    // получит). Показываем баннер тем же путём, что и фон-сервис, чтобы звонок
    // не потерялся (тап → handoff → экран/авто-приём). force=true: foreground-skip
    // НЕ применяем (UI сам решил, что в фоне — иначе бы показал экран).
    public static void showIncomingCallFromUi(Context context, String envelopeJson) {
        if (envelopeJson == null || envelopeJson.isEmpty()) return;
        try {
            JSONObject env = new JSONObject(envelopeJson);
            if (env.optInt("kind", -1) != 0) return; // только Offer
            String sender = env.optString("sender").trim();
            String callId = "";
            try {
                JSONObject pl = new JSONObject(env.optString("payload_json"));
                callId = pl.optString("call_id").trim();
            } catch (JSONException ignore) {}
            if (callId.isEmpty()) callId = sender + ":" + env.optLong("ts_ms", 0L);
            if (SEEN_CALL_IDS.size() > 500) SEEN_CALL_IDS.clear();
            if (!SEEN_CALL_IDS.add(callId)) return; // уже показывали
            Log.i(TAG, "incoming call (handed off from UI) from " + sender + " call_id=" + callId);
            prefs(context).edit()
                    .putString(PREF_CALL_OFFER, envelopeJson)
                    .putLong(PREF_CALL_OFFER_TS, android.os.SystemClock.elapsedRealtime())
                    .apply();
            showIncomingCall(context, sender, callId, envelopeJson, /*force=*/true);
        } catch (JSONException e) {
            Log.w(TAG, "showIncomingCallFromUi: bad envelope", e);
        }
    }

    // Баннер входящего вызова: тап/«Ответить» открывают приложение (там штатный
    // экран звонка подхватывает ещё-висящий оффер); «Сбросить» гасит уведомление.
    private static void showIncomingCall(Context context, String sender, String callId, String offerJson) {
        showIncomingCall(context, sender, callId, offerJson, /*force=*/false);
    }

    private static void showIncomingCall(Context context, String sender, String callId, String offerJson,
                                         boolean force) {
        if (!force && isApplicationForeground(context)) return; // на переднем плане звонок ведёт само приложение
        requestPostNotificationsIfNeeded(context);
        if (!notificationsAllowed(context)) return;
        ensureChannels(context);
        NotificationManager manager = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
        if (manager == null) return;

        // Оффер кладём в intent (надёжный cross-process канал) — UI заберёт его и
        // поднимет экран вызова (инъекция в CallSignaling, сервер оффер drain'нул).
        // ДВА разных PendingIntent'а (разные requestCode, иначе FLAG_UPDATE_CURRENT
        // их склеит): «Ответить» несёт флаг авто-приёма (после PIN примем сразу),
        // тап по телу баннера — просто открывает экран вызова с кнопками.
        PendingIntent answer = openAppIntent(context, CALL_NOTIFICATION_ID, null, null, offerJson, true);
        PendingIntent openBody = openAppIntent(context, CALL_NOTIFICATION_ID + 2, null, null, offerJson, false);
        int piFlags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) piFlags |= PendingIntent.FLAG_IMMUTABLE;
        // «Сбросить» — broadcast в PollAlarmReceiver (не getService: запуск сервиса из
        // background-action на Android 12+ может блокироваться, broadcast проходит).
        Intent dismiss = new Intent(context, PollAlarmReceiver.class)
                .setAction(ACTION_CALL_DISMISS)
                .setPackage(context.getPackageName())
                .putExtra(EXTRA_CALL_ID, callId);
        PendingIntent dismissPi = PendingIntent.getBroadcast(context, CALL_NOTIFICATION_ID + 1, dismiss, piFlags);

        Notification.Builder builder = notificationBuilder(context, CALL_CHANNEL_ID)
                .setContentTitle("Входящий вызов")
                .setContentText("Нажмите «Ответить», чтобы принять")
                .setSmallIcon(context.getApplicationInfo().icon)
                .setContentIntent(openBody)
                .setAutoCancel(true)
                .addAction(0, "Ответить", answer)
                .addAction(0, "Сбросить", dismissPi);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            builder.setCategory(Notification.CATEGORY_CALL);
            builder.setPriority(Notification.PRIORITY_HIGH); // heads-up на pre-O
        }
        try {
            manager.notify(CALL_NOTIFICATION_ID, buildNotification(builder));
        } catch (RuntimeException e) {
            Log.w(TAG, "Cannot show incoming-call notification", e);
        }
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

                JSONArray peerKeys = p.optJSONArray("peerMasterKeys");
                String peerKeysJson = peerKeys != null ? peerKeys.toString() : "[]";

                profiles.add(new ProfileHint(server, reservesJson, signingKey, sender, dialogs, peerKeysJson));
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
            // НЕ латчим неудачу навсегда: dlopen может разово упасть (например, OOM
            // при линковке/нехватка адресного пространства) — тогда следующий poll
            // повторит. Спам в лог ограничен интервалом будильника (60с). Логируем
            // «недоступна» только один раз, чтобы не засорять.
            final boolean firstAttempt = !nativeLibraryLoadAttempted;
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
            if (firstAttempt) {
                Log.w(TAG, "ParanoiaService native library is not available for background polling");
            }
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
        SharedPreferences p = prefs(context);
        boolean fg = p.getBoolean(PREF_APP_FOREGROUND, appForeground);
        long until = p.getLong(PREF_APP_FOREGROUND_UNTIL, 0L);
        // Флаг истёк (UI давно не присылал heartbeat — вероятно процесс мёртв) ⇒
        // трактуем как background, чтобы фоновый опрос возобновился.
        fg = fg && until != 0L && android.os.SystemClock.elapsedRealtime() < until;
        appForeground = fg;
        return fg;
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

        NotificationChannel calls = new NotificationChannel(
                CALL_CHANNEL_ID,
                "Paranoia calls",
                NotificationManager.IMPORTANCE_HIGH);
        calls.setDescription("Входящие вызовы");
        calls.enableVibration(true);
        manager.createNotificationChannel(calls);
    }

    // Уведомление открывает QtActivity напрямую — тем же интентом, что и иконка
    // лаунчера (ACTION_MAIN + CATEGORY_LAUNCHER + NEW_TASK). Никакого activity-
    // trampoline'а: отдельная LaunchActivity роняла QtActivity в собственную
    // task, а Qt — singleton на процесс и второй QtActivity-инстанс приводил к
    // зависанию. EXTRA_OPEN_* кладём в интент: при холодном старте QtActivity
    // их видно через getIntent() (см. takeOpenTarget).
    private static PendingIntent openAppIntent(Context context, int requestCode, String profileId, String peer) {
        return openAppIntent(context, requestCode, profileId, peer, null, false);
    }

    private static PendingIntent openAppIntent(Context context, int requestCode, String profileId, String peer,
                                               String callOfferJson) {
        return openAppIntent(context, requestCode, profileId, peer, callOfferJson, false);
    }

    private static PendingIntent openAppIntent(Context context, int requestCode, String profileId, String peer,
                                               String callOfferJson, boolean answerIntent) {
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
        if (callOfferJson != null && !callOfferJson.isEmpty()) {
            launchIntent.putExtra(EXTRA_CALL_OFFER, callOfferJson);
        }
        if (answerIntent) {
            launchIntent.putExtra(EXTRA_CALL_ANSWER, true);
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

    // Забрать (и очистить) отложенный конверт входящего звонка (#6 handoff).
    // UI-процесс зовёт при открытии; возвращает JSON конверта или "".
    public static String takePendingCallOffer(Context context) {
        // Сперва из intent открывшей Activity (надёжный cross-process канал).
        if (context instanceof Activity) {
            Intent intent = ((Activity) context).getIntent();
            if (intent != null) {
                String fromIntent = intent.getStringExtra(EXTRA_CALL_OFFER);
                if (fromIntent != null && !fromIntent.isEmpty()) {
                    intent.removeExtra(EXTRA_CALL_OFFER);
                    // подчистим и prefs, чтобы не выстрелил повторно
                    prefs(context).edit().remove(PREF_CALL_OFFER).remove(PREF_CALL_OFFER_TS).remove(PREF_CALL_OFFER_CALLID).apply();
                    // intent-канал = пользователь только что тапнул → оффер свежий.
                    return fromIntent;
                }
            }
        }
        SharedPreferences prefs = prefs(context);
        String offer = prefs.getString(PREF_CALL_OFFER, "");
        long ts = prefs.getLong(PREF_CALL_OFFER_TS, 0L);
        if (offer != null && !offer.isEmpty()) {
            prefs.edit().remove(PREF_CALL_OFFER).remove(PREF_CALL_OFFER_TS).remove(PREF_CALL_OFFER_CALLID).apply();
            // Протухший оффер (звонок давно не звенит) НЕ инжектим — иначе занял бы
            // состояние звонка мёртвым вызовом и реальные входящие отбивались BUSY.
            long age = android.os.SystemClock.elapsedRealtime() - ts;
            if (ts == 0L || age > CALL_OFFER_TTL_MS) {
                Log.i(TAG, "pending call offer is stale (age " + age + "ms) — discarding");
                return "";
            }
        }
        return valueOrEmpty(offer);
    }

    // UI-процесс сообщает, что САМ опрашивает звонки (его in-app сигналинг активен:
    // foreground или идёт звонок). Доставляем ИНТЕНТОМ — фон-сервис запишет флаг в
    // своём процессе (cross-process prefs ненадёжны). Пока флаг свеж — фон-сервис не
    // лезет в call_poll (и не чейнит), отдавая звонки in-app клиенту.
    public static void heartbeatUiCallPolling(Context context) {
        sendUiCallPolling(context, true);
    }

    // UI ушёл в фон без активного звонка — отдаём опрос звонков фон-сервису СРАЗУ.
    public static void clearUiCallPolling(Context context) {
        sendUiCallPolling(context, false);
    }

    private static void sendUiCallPolling(Context context, boolean active) {
        if (!serviceRequested(context)) {
            // Сервис не запрашивали (например, ещё не залогинились) — запускать его
            // только ради этого флага не нужно; локально хватает (нечего опрашивать).
            return;
        }
        Intent intent = new Intent(context, ParanoiaForegroundService.class);
        intent.setAction(ACTION_SET_UI_CALL_POLLING);
        intent.putExtra(EXTRA_UI_CALL_POLLING, active);
        try {
            startServiceCompat(context, intent);
        } catch (RuntimeException e) {
            Log.w(TAG, "Cannot send UI call-polling state", e);
        }
    }

    private static boolean uiOwnsCallPolling(Context context) {
        long until = prefs(context).getLong(PREF_UI_CALL_POLLING_UNTIL, 0L);
        return until != 0L && android.os.SystemClock.elapsedRealtime() < until;
    }

    // Нажал ли пользователь «Ответить» в баннере (intent-only — если флаг потерян,
    // деградируем в ручной приём, что безопасно). Зовётся UI при открытии.
    public static boolean takePendingCallAnswerIntent(Context context) {
        if (context instanceof Activity) {
            Intent intent = ((Activity) context).getIntent();
            if (intent != null && intent.getBooleanExtra(EXTRA_CALL_ANSWER, false)) {
                intent.removeExtra(EXTRA_CALL_ANSWER);
                return true;
            }
        }
        return false;
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
