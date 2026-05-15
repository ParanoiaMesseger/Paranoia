package app.paranoia.client;

import android.Manifest;
import android.app.Activity;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.util.Log;

public final class ParanoiaForegroundService extends Service {
    private static final String CHANNEL_ID = "paranoia_polling";
    private static final String MESSAGE_CHANNEL_ID = "paranoia_messages";
    private static final String EXTRA_OPEN_PROFILE_ID = "app.paranoia.client.OPEN_PROFILE_ID";
    private static final String EXTRA_OPEN_PEER = "app.paranoia.client.OPEN_PEER";
    private static final String TAG = "ParanoiaService";
    private static final int FOREGROUND_NOTIFICATION_ID = 1001;
    private static final int MESSAGE_NOTIFICATION_ID = 1002;
    private static final long POLL_INTERVAL_MS = 60_000L;
    private static volatile boolean started = false;

    private static volatile boolean nativeLibraryWarningLogged = false;

    private final Handler pollHandler = new Handler(Looper.getMainLooper());
    private final Runnable pollRunnable = new Runnable() {
        @Override
        public void run() {
            Log.i(TAG, "poll tick: calling native callback");
            try {
                triggerBackgroundPollNative();
            } catch (UnsatisfiedLinkError ignored) {
                if (!nativeLibraryWarningLogged) {
                    nativeLibraryWarningLogged = true;
                    Log.i(TAG, "poll tick: native library is not loaded");
                }
            } catch (Throwable t) {
                Log.w(TAG, "Background poll callback failed", t);
            }
            pollHandler.postDelayed(this, POLL_INTERVAL_MS);
        }
    };

    private static native void triggerBackgroundPollNative();

    public static void initialize(Context context) {
        ensureChannels(context);
        requestPostNotificationsIfNeeded(context);
    }

    public static void start(Context context) {
        Log.i(TAG, "start requested");
        ensureChannels(context);
        requestPostNotificationsIfNeeded(context);
        if (started) {
            return;
        }
        Intent intent = new Intent(context, ParanoiaForegroundService.class);
        try {
            started = true;
            Log.i(TAG, "startForegroundService requested");
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent);
            } else {
                context.startService(intent);
            }
        } catch (RuntimeException e) {
            started = false;
            Log.w(TAG, "Cannot start foreground service", e);
        }
    }

    public static void stop(Context context) {
        started = false;
        context.stopService(new Intent(context, ParanoiaForegroundService.class));
    }

    public static void showNewMessages(Context context, long count, String profileId, String peer) {
        Log.i(TAG, "showNewMessages requested: count=" + count);
        if (count <= 0) {
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
                .setContentText("Новых сообщений: " + count)
                .setSmallIcon(context.getApplicationInfo().icon)
                .setContentIntent(openAppIntent(context, MESSAGE_NOTIFICATION_ID, profileId, peer))
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
        Log.i(TAG, "onStartCommand");
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
            startPollLoop();
        } catch (RuntimeException e) {
            started = false;
            Log.w(TAG, "Cannot enter foreground", e);
            stopSelf();
            return START_NOT_STICKY;
        }
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        stopPollLoop();
        started = false;
        stopForeground(true);
        super.onDestroy();
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

    private void startPollLoop() {
        pollHandler.removeCallbacks(pollRunnable);
        Log.i(TAG, "poll loop scheduled: intervalMs=" + POLL_INTERVAL_MS);
        pollHandler.postDelayed(pollRunnable, POLL_INTERVAL_MS);
    }

    private void stopPollLoop() {
        pollHandler.removeCallbacks(pollRunnable);
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

    private static PendingIntent openAppIntent(Context context, int requestCode, String profileId, String peer) {
        Intent launchIntent = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
        if (launchIntent == null) {
            launchIntent = new Intent();
        }
        launchIntent.setAction(Intent.ACTION_MAIN);
        launchIntent.addCategory(Intent.CATEGORY_LAUNCHER);
        launchIntent.setPackage(context.getPackageName());
        launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP |
                Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
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
        if (!(context instanceof Activity)) {
            return "";
        }
        Intent intent = ((Activity) context).getIntent();
        if (intent == null) {
            return "";
        }
        String profileId = intent.getStringExtra(EXTRA_OPEN_PROFILE_ID);
        String peer = intent.getStringExtra(EXTRA_OPEN_PEER);
        intent.removeExtra(EXTRA_OPEN_PROFILE_ID);
        intent.removeExtra(EXTRA_OPEN_PEER);
        if (peer == null || peer.isEmpty()) {
            return "";
        }
        return (profileId == null ? "" : profileId) + "\n" + peer;
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
}
