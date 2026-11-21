package lineage.rango.artfeed;

import android.animation.Animator;
import android.animation.AnimatorListenerAdapter;
import android.animation.ValueAnimator;
import android.app.Dialog;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.graphics.drawable.ColorDrawable;
import android.net.Uri;
import android.os.IBinder;
import android.os.Parcel;
import android.os.RemoteException;
import android.util.Log;
import android.view.ContextThemeWrapper;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.VelocityTracker;
import android.view.ViewConfiguration;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.view.animation.DecelerateInterpolator;
import android.widget.FrameLayout;

/**
 * One overlay window, attached to the launcher's activity window (its token) and
 * slid in from the left by the launcher's scroll progress: 0 = home screen,
 * 1 = feed fully open. Every progress change goes back to the launcher
 * (overlayScrollChanged), which moves its workspace along. A swipe to the left
 * inside the feed or Back closes it. While closed the window is hidden, so it
 * never takes touches meant for the home screen.
 */
final class OverlayController implements FeedView.Host {
    private static final String TAG = OverlayService.TAG;
    private static final String CALLBACK =
            "com.google.android.libraries.launcherclient.ILauncherOverlayCallback";
    private static final float OPEN_THRESHOLD = 0.3f;    // launcher drag released beyond this → open
    private static final float CLOSE_THRESHOLD = 0.7f;   // feed drag released below this → close
    private static final int DURATION_MS = 280;

    private final Context ctx;
    private Dialog dialog;
    private SwipeFrame root;
    private IBinder callback;
    private float progress;
    private boolean scrolling, shown;
    private ValueAnimator anim;

    OverlayController(Context ctx) {
        this.ctx = ctx;
    }

    // ── protocol ──
    void attach(WindowManager.LayoutParams lp, IBinder cb, int options) {
        detach(false);
        callback = cb;
        if (lp == null || lp.token == null || (options & 1) == 0) {   // bit 0: overlay enabled
            status(0);
            return;
        }
        Context themed = new ContextThemeWrapper(ctx, android.R.style.Theme_DeviceDefault_NoActionBar);
        dialog = new Dialog(themed, android.R.style.Theme_DeviceDefault_NoActionBar) {
            @Override
            public void onBackPressed() {   // also reached from the predictive-back callback
                close(1);
            }
        };
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
        root = new SwipeFrame(themed);
        root.addView(new FeedView(themed, this), new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        dialog.setContentView(root, new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        Window w = dialog.getWindow();
        w.setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
        w.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
        w.setDecorFitsSystemWindows(false);
        w.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
        w.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS
                | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN);
        w.setStatusBarColor(Color.TRANSPARENT);
        w.setNavigationBarColor(Color.TRANSPARENT);
        WindowManager.LayoutParams a = w.getAttributes();
        a.token = lp.token;                                   // child of the launcher's activity
        a.type = WindowManager.LayoutParams.TYPE_APPLICATION;
        a.gravity = Gravity.START | Gravity.TOP;
        a.windowAnimations = 0;                               // we animate ourselves
        a.format = PixelFormat.TRANSLUCENT;
        a.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS;
        w.setAttributes(a);

        progress = 0;
        applyProgress();
        try {
            dialog.show();
        } catch (WindowManager.BadTokenException | WindowManager.InvalidDisplayException e) {
            Log.w(TAG, "cannot attach to the launcher window", e);
            dialog = null;
            root = null;
            status(0);
            return;
        }
        WindowInsetsController ic = w.getInsetsController();
        if (ic != null) {   // light icons on the dark feed
            ic.setSystemBarsAppearance(0, WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS
                    | WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS);
        }
        dialog.hide();
        shown = false;
        status(1);   // attached: the launcher now forwards its swipes to us
    }

    void detach(boolean changingConfigurations) {
        cancelAnim();
        if (dialog != null) {
            try {
                dialog.dismiss();
            } catch (RuntimeException e) {
                Log.w(TAG, "dismiss", e);   // the launcher window may already be gone
            }
        }
        dialog = null;
        root = null;
        shown = false;
        scrolling = false;
        progress = 0;
    }

    void startScroll() {
        if (dialog == null) return;
        cancelAnim();
        scrolling = true;
        ensureShown();
    }

    void onScroll(float p) {
        if (dialog == null) return;
        ensureShown();
        setProgress(p);
    }

    void endScroll() {
        if (dialog == null) return;
        scrolling = false;
        animateTo(progress > OPEN_THRESHOLD ? 1 : 0, DURATION_MS);
    }

    void open(int options) {
        if (dialog == null) return;
        ensureShown();
        animateTo(1, duration(options));
    }

    void close(int options) {
        if (dialog == null) return;
        animateTo(0, duration(options));
    }

    void onPause() { }

    void onResume() { }

    /** options: bit 0 = animate, bits 2+ = duration in ms (LauncherClient.r) */
    private static int duration(int options) {
        if ((options & 1) == 0) return 0;
        int d = options >> 2;
        return d > 0 ? d : DURATION_MS;
    }

    // ── FeedView.Host ──
    @Override
    public void openUrl(String url) {
        try {
            ctx.startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        } catch (RuntimeException e) {
            Log.w(TAG, "no browser for " + url, e);
        }
    }

    // ── window and progress ──
    private void ensureShown() {
        if (dialog != null && !shown) {
            applyProgress();
            dialog.show();
            shown = true;
            FeedStore.get().onOpened();
        }
    }

    private void setProgress(float p) {
        progress = Math.max(0f, Math.min(1f, p));
        applyProgress();
        sendScroll(progress);
        if (progress == 0f && !scrolling && anim == null) hideWindow();
    }

    private void applyProgress() {
        if (root == null) return;
        int w = root.getWidth() > 0 ? root.getWidth() : ctx.getResources().getDisplayMetrics().widthPixels;
        root.setTranslationX(-(1f - progress) * w);
    }

    private void hideWindow() {
        if (dialog != null && shown) {
            dialog.hide();
            shown = false;
        }
    }

    private void animateTo(float target, int durationMs) {
        cancelAnim();
        if (durationMs <= 0 || progress == target) {
            setProgress(target);
            if (target == 0f) hideWindow();
            return;
        }
        ValueAnimator va = ValueAnimator.ofFloat(progress, target);
        va.setDuration(Math.max(120, (long) (durationMs * Math.abs(target - progress))));
        va.setInterpolator(new DecelerateInterpolator(1.5f));
        va.addUpdateListener(v -> setProgress((float) v.getAnimatedValue()));
        va.addListener(new AnimatorListenerAdapter() {
            private boolean cancelled;
            @Override public void onAnimationCancel(Animator a) { cancelled = true; }
            @Override
            public void onAnimationEnd(Animator a) {
                if (anim == va) anim = null;
                if (!cancelled && target == 0f) hideWindow();
            }
        });
        anim = va;
        va.start();
    }

    private void cancelAnim() {
        if (anim != null) {
            ValueAnimator a = anim;
            anim = null;
            a.cancel();
        }
    }

    // ── callbacks to the launcher ──
    private void sendScroll(float p) {
        transact(1, p, 0);
    }

    private void status(int s) {
        transact(2, 0, s);
    }

    private void transact(int code, float f, int i) {
        if (callback == null) return;
        Parcel d = Parcel.obtain();
        try {
            d.writeInterfaceToken(CALLBACK);
            if (code == 1) d.writeFloat(f); else d.writeInt(i);
            callback.transact(code, d, null, IBinder.FLAG_ONEWAY);
        } catch (RemoteException e) {
            Log.w(TAG, "launcher gone", e);
            callback = null;
        } finally {
            d.recycle();
        }
    }

    /** Takes over leftward horizontal drags (closing the feed); vertical ones stay with the list. */
    private final class SwipeFrame extends FrameLayout {
        private final int slop;
        private final float flingVelocity;
        private float downX, downY, startX;
        private boolean dragging;
        private VelocityTracker vt;

        SwipeFrame(Context c) {
            super(c);
            ViewConfiguration vc = ViewConfiguration.get(c);
            slop = vc.getScaledTouchSlop();
            flingVelocity = vc.getScaledMinimumFlingVelocity() * 4f;
        }

        @Override
        public boolean onInterceptTouchEvent(MotionEvent ev) {
            track(ev);
            switch (ev.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                    downX = ev.getX();
                    downY = ev.getY();
                    dragging = false;
                    break;
                case MotionEvent.ACTION_MOVE:
                    float dx = ev.getX() - downX, dy = ev.getY() - downY;
                    if (!dragging && dx < -slop && Math.abs(dx) > Math.abs(dy) * 1.2f) {
                        dragging = true;
                        startX = ev.getX();
                        cancelAnim();
                        scrolling = true;
                    }
                    break;
                case MotionEvent.ACTION_UP:
                case MotionEvent.ACTION_CANCEL:
                    recycle();
                    break;
            }
            return dragging;
        }

        @Override
        public boolean onTouchEvent(MotionEvent ev) {
            track(ev);
            switch (ev.getActionMasked()) {
                case MotionEvent.ACTION_MOVE:
                    if (dragging && getWidth() > 0) {
                        setProgress(1f + Math.min(0f, ev.getX() - startX) / getWidth());
                    }
                    return true;
                case MotionEvent.ACTION_UP:
                case MotionEvent.ACTION_CANCEL:
                    float vx = 0;
                    if (vt != null) {
                        vt.computeCurrentVelocity(1000);
                        vx = vt.getXVelocity();
                    }
                    recycle();
                    if (dragging) {
                        dragging = false;
                        scrolling = false;
                        boolean close = vx < -flingVelocity
                                || (progress < CLOSE_THRESHOLD && vx < flingVelocity);
                        animateTo(close ? 0 : 1, DURATION_MS);
                    }
                    return true;
            }
            return dragging;
        }

        private void track(MotionEvent ev) {
            if (vt == null) vt = VelocityTracker.obtain();
            vt.addMovement(ev);
        }

        private void recycle() {
            if (vt != null) {
                vt.recycle();
                vt = null;
            }
        }
    }
}
