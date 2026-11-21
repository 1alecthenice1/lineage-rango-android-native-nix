package lineage.rango.artfeed;

import android.app.Service;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.net.http.HttpResponseCache;
import android.os.Binder;
import android.os.Bundle;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.Parcel;
import android.os.Process;
import android.util.Log;
import android.view.WindowManager;

import java.io.File;
import java.io.IOException;

/**
 * Launcher overlay service ("minus one" page). Protocol = the launcher client in
 * Launcher3's libs/libGoogleFeed.jar, read from its bytecode (2026-11-21):
 * interface com.google.android.libraries.launcherclient.ILauncherOverlay, all calls
 * one-way except 11–13 and 17. Without a "service.api.version" meta-data the client
 * uses API 1: windowAttached (4) + onPause/onResume (7/8).
 * Callback interface ILauncherOverlayCallback: 1 overlayScrollChanged(float),
 * 2 overlayStatusChanged(int: bit 0 = overlay attached, bit 1 = hotword).
 * Only the current home app (and this app's own preview) may bind.
 */
public class OverlayService extends Service {
    static final String TAG = "ArtFeed";

    @Override
    public void onCreate() {
        super.onCreate();
        try {
            if (HttpResponseCache.getInstalled() == null) {
                HttpResponseCache.install(new File(getCacheDir(), "http"), 64L * 1024 * 1024);
            }
        } catch (IOException e) {
            Log.w(TAG, "no HTTP cache", e);
        }
    }

    @Override
    public IBinder onBind(Intent intent) {
        return new OverlayBinder();
    }

    private boolean callerAllowed(int uid) {
        if (uid == Process.myUid()) return true;
        PackageManager pm = getPackageManager();
        ResolveInfo home = pm.resolveActivity(
                new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME),
                PackageManager.MATCH_DEFAULT_ONLY);
        if (home == null || home.activityInfo == null) return false;
        String[] pkgs = pm.getPackagesForUid(uid);
        if (pkgs == null) return false;
        for (String p : pkgs) if (p.equals(home.activityInfo.packageName)) return true;
        return false;
    }

    private final class OverlayBinder extends Binder {
        static final String DESCRIPTOR = "com.google.android.libraries.launcherclient.ILauncherOverlay";
        private final Handler main = new Handler(Looper.getMainLooper());
        private final OverlayController controller = new OverlayController(OverlayService.this);

        @Override
        protected boolean onTransact(int code, Parcel data, Parcel reply, int flags)
                throws android.os.RemoteException {
            if (code == INTERFACE_TRANSACTION) {
                reply.writeString(DESCRIPTOR);
                return true;
            }
            if (code < FIRST_CALL_TRANSACTION || code > LAST_CALL_TRANSACTION) {
                return super.onTransact(code, data, reply, flags);
            }
            if (!callerAllowed(Binder.getCallingUid())) {
                Log.w(TAG, "refusing overlay call " + code + " from uid " + Binder.getCallingUid());
                throw new SecurityException("not the home app");
            }
            data.enforceInterface(DESCRIPTOR);
            switch (code) {
                case 1: main.post(controller::startScroll); break;
                case 2: { float p = data.readFloat(); main.post(() -> controller.onScroll(p)); break; }
                case 3: main.post(controller::endScroll); break;
                case 4: {
                    WindowManager.LayoutParams lp = data.readInt() != 0
                            ? WindowManager.LayoutParams.CREATOR.createFromParcel(data) : null;
                    IBinder cb = data.readStrongBinder();
                    int options = data.readInt();
                    main.post(() -> controller.attach(lp, cb, options));
                    break;
                }
                case 5: { boolean changing = data.readInt() != 0; main.post(() -> controller.detach(changing)); break; }
                case 6: { int o = data.readInt(); main.post(() -> controller.close(o)); break; }
                case 7: main.post(controller::onPause); break;
                case 8: main.post(controller::onResume); break;
                case 9: { int o = data.readInt(); main.post(() -> controller.open(o)); break; }
                case 11: reply.writeNoException(); reply.writeString(null); break;  // voice search language
                case 12: reply.writeNoException(); reply.writeInt(0); break;        // voice detection running
                case 13: reply.writeNoException(); reply.writeInt(1); break;        // has overlay content
                case 14: {   // windowAttached2 (API 3+), not used by API 1 clients
                    Bundle b = data.readInt() != 0 ? Bundle.CREATOR.createFromParcel(data) : null;
                    IBinder cb = data.readStrongBinder();
                    if (b != null) {
                        b.setClassLoader(WindowManager.LayoutParams.class.getClassLoader());
                        WindowManager.LayoutParams lp = b.getParcelable("layout_params",
                                WindowManager.LayoutParams.class);
                        int options = b.getInt("client_options", 1);
                        main.post(() -> controller.attach(lp, cb, options));
                    }
                    break;
                }
                case 17: reply.writeNoException(); reply.writeInt(0); break;        // startSearch
                default: break;   // 10 voice detection, 15, 16 activity state, 18–20 bundles
            }
            return true;
        }
    }
}
