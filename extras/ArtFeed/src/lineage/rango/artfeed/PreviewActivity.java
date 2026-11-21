package lineage.rango.artfeed;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Intent;
import android.content.ServiceConnection;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.Binder;
import android.os.Bundle;
import android.os.IBinder;
import android.os.Parcel;
import android.os.Process;
import android.os.RemoteException;
import android.util.Log;
import android.view.Gravity;
import android.view.MotionEvent;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * Test client for the overlay protocol: binds OverlayService exactly like the
 * launcher's LauncherClient (same intent, same parcels), passes this activity's
 * window as the parent, and forwards a rightward swipe as startScroll / onScroll /
 * endScroll. Shows what the service reports back (status, scroll progress).
 *   adb shell am start -n lineage.rango.artfeed/.PreviewActivity
 */
public class PreviewActivity extends Activity {
    private static final String TAG = OverlayService.TAG;
    private static final String OVERLAY = "com.google.android.libraries.launcherclient.ILauncherOverlay";
    private static final String CALLBACK = "com.google.android.libraries.launcherclient.ILauncherOverlayCallback";

    private IBinder overlay;
    private TextView info;
    private float downX;
    private boolean dragging;
    private int status = -1;
    private float lastScroll;

    private final Binder callback = new Binder() {
        @Override
        protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) {
            if (code == INTERFACE_TRANSACTION) { reply.writeString(CALLBACK); return true; }
            data.enforceInterface(CALLBACK);
            if (code == 1) lastScroll = data.readFloat();
            else if (code == 2) status = data.readInt();
            runOnUiThread(PreviewActivity.this::showInfo);
            return true;
        }
    };

    private final ServiceConnection conn = new ServiceConnection() {
        @Override
        public void onServiceConnected(ComponentName n, IBinder b) {
            overlay = b;
            info.post(() -> attach());
        }
        @Override
        public void onServiceDisconnected(ComponentName n) { overlay = null; showInfo(); }
    };

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout l = new LinearLayout(this);
        l.setOrientation(LinearLayout.VERTICAL);
        l.setGravity(Gravity.CENTER);
        l.setBackgroundColor(0xFF232A2E);
        TextView title = new TextView(this);
        title.setText("Art feed — overlay test");
        title.setTextColor(FeedView.FG);
        title.setTextSize(22);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        info = new TextView(this);
        info.setTextColor(FeedView.GREY);
        info.setTextSize(15);
        info.setGravity(Gravity.CENTER);
        info.setPadding(48, 32, 48, 32);
        TextView open = new TextView(this);
        open.setText("Open feed");
        open.setTextColor(FeedView.BG);
        open.setTextSize(17);
        open.setPadding(48, 24, 48, 24);
        open.setBackgroundColor(FeedView.GREEN);
        open.setOnClickListener(v -> call(9, 1));
        l.addView(title);
        l.addView(info);
        l.addView(open);
        setContentView(l);
        showInfo();
        Intent i = new Intent("com.android.launcher3.WINDOW_OVERLAY")
                .setPackage(getPackageName())
                .setData(Uri.parse("app://" + getPackageName() + ":" + Process.myUid() + "?v=9&cv=14"));
        bindService(i, conn, BIND_AUTO_CREATE);
    }

    private void attach() {
        if (overlay == null || getWindow().getAttributes().token == null) {
            info.postDelayed(this::attach, 100);
            return;
        }
        Parcel d = Parcel.obtain();
        try {
            d.writeInterfaceToken(OVERLAY);
            d.writeInt(1);
            getWindow().getAttributes().writeToParcel(d, 0);
            d.writeStrongBinder(callback);
            d.writeInt(7);   // overlay enabled | hotword | prewarm, like the launcher
            overlay.transact(4, d, null, IBinder.FLAG_ONEWAY);
        } catch (RemoteException e) {
            Log.w(TAG, "attach", e);
        } finally {
            d.recycle();
        }
        call(8, null);   // onResume
    }

    private void call(int code, Object arg) {
        if (overlay == null) return;
        Parcel d = Parcel.obtain();
        try {
            d.writeInterfaceToken(OVERLAY);
            if (arg instanceof Float) d.writeFloat((Float) arg);
            else if (arg instanceof Integer) d.writeInt((Integer) arg);
            overlay.transact(code, d, null, IBinder.FLAG_ONEWAY);
        } catch (RemoteException e) {
            Log.w(TAG, "call " + code, e);
        } finally {
            d.recycle();
        }
    }

    private void showInfo() {
        info.setText("Swipe right anywhere to pull the feed in, like on the home screen.\n\n"
                + "service: " + (overlay == null ? "not bound" : "bound")
                + "   status: " + status + "   scroll: " + String.format("%.2f", lastScroll));
    }

    @Override
    public boolean onTouchEvent(MotionEvent ev) {
        float w = getWindow().getDecorView().getWidth();
        switch (ev.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
                downX = ev.getX();
                dragging = false;
                return true;
            case MotionEvent.ACTION_MOVE:
                float dx = ev.getX() - downX;
                if (!dragging && dx > 24) { dragging = true; call(1, null); }
                if (dragging && w > 0) call(2, Math.min(1f, dx / w));
                return true;
            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_CANCEL:
                if (dragging) call(3, null);
                dragging = false;
                return true;
        }
        return super.onTouchEvent(ev);
    }

    @Override
    protected void onPause() {
        call(7, null);
        super.onPause();
    }

    @Override
    protected void onResume() {
        super.onResume();
        call(8, null);
    }

    @Override
    protected void onDestroy() {
        call(5, 0);   // windowDetached(false)
        unbindService(conn);
        super.onDestroy();
    }
}
