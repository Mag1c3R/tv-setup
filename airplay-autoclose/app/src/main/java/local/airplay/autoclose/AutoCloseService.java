package local.airplay.autoclose;

import android.accessibilityservice.AccessibilityService;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;

import java.util.ArrayDeque;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Closes the AirPlay receiver (io.github.jqssun.airplay) once the last iPhone disconnects.
 *
 * The receiver opens itself on connect (its "Open this application on connect" setting plus the
 * Display over other apps permission), but on disconnect it only leaves fullscreen and stays on its
 * "0 connected" screen. Events come only from that one package (accessibility_config.xml), so the
 * service sleeps the rest of the time.
 *
 * Armed once "N connected" shows N > 0, or when the receiver came to the front and 2.5 s later shows
 * anything but "0 connected" (the fullscreen mirror). When "0 connected" shows up while armed, Back
 * returns to whatever was on screen before; Home if the receiver is somehow still in front. Opened by
 * hand, it shows "0 connected" and stays unarmed, so it never closes on the user.
 */
public class AutoCloseService extends AccessibilityService {
    private static final String TAG = "AirPlayAutoClose";
    private static final String AIRPLAY = "io.github.jqssun.airplay";
    private static final Pattern COUNT = Pattern.compile("^(\\d+) connected$");

    private final Handler handler = new Handler(Looper.getMainLooper());
    private boolean armed;

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        if (event == null || !AIRPLAY.contentEquals(String.valueOf(event.getPackageName()))) return;
        if (event.getEventType() == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED
                && event.getContentChangeTypes() == 0) {
            // Came to the front: by hand, or by itself for a sender. "1 connected" lasts a moment before
            // the fullscreen mirror hides it (and a resumed screen can first show a stale 0), and the
            // active window can still be the previous app, so look once it has settled.
            armed = false;
            handler.removeCallbacks(settleCheck);
            handler.postDelayed(settleCheck, 2500);
            return;
        }
        AccessibilityNodeInfo root = getRootInActiveWindow();
        if (root == null || !AIRPLAY.contentEquals(String.valueOf(root.getPackageName()))) return;

        int count = connectedCount(root);
        if (count > 0) {
            if (!armed) Log.d(TAG, "armed, count=" + count);
            armed = true;
        } else if (count == 0 && armed) {
            armed = false;
            Log.d(TAG, "last sender gone, closing");
            performGlobalAction(GLOBAL_ACTION_BACK);
            handler.postDelayed(this::homeIfStillInFront, 800);
        }
    }

    /** 2.5 s after the receiver came to the front: "0 connected" means opened by hand, anything else a sender. */
    private final Runnable settleCheck = () -> {
        AccessibilityNodeInfo root = getRootInActiveWindow();
        if (root == null || !AIRPLAY.contentEquals(String.valueOf(root.getPackageName()))) return;
        int count = connectedCount(root);
        armed = count != 0;
        Log.d(TAG, "settled, count=" + count + (armed ? ", armed" : ", opened by hand"));
    };

    private void homeIfStillInFront() {
        AccessibilityNodeInfo root = getRootInActiveWindow();
        if (root != null && AIRPLAY.contentEquals(String.valueOf(root.getPackageName()))) {
            performGlobalAction(GLOBAL_ACTION_HOME);
        }
    }

    /**
     * The N of the "N connected" line, or -1 when it is not on screen (fullscreen mirror). Walks the tree:
     * the receiver is Jetpack Compose, which answers findAccessibilityNodeInfosByText with nothing.
     */
    private static int connectedCount(AccessibilityNodeInfo root) {
        ArrayDeque<AccessibilityNodeInfo> queue = new ArrayDeque<>();
        queue.add(root);
        for (int seen = 0; !queue.isEmpty() && seen < 400; seen++) {
            AccessibilityNodeInfo node = queue.poll();
            CharSequence text = node.getText();
            if (text != null) {
                Matcher m = COUNT.matcher(text.toString().trim());
                if (m.matches()) return Integer.parseInt(m.group(1));
            }
            for (int i = 0; i < node.getChildCount(); i++) {
                AccessibilityNodeInfo child = node.getChild(i);
                if (child != null) queue.add(child);
            }
        }
        return -1;
    }

    @Override
    public void onInterrupt() {
    }
}
