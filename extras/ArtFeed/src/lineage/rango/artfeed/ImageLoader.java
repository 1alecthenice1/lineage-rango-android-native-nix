package lineage.rango.artfeed;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Handler;
import android.os.Looper;
import android.util.LruCache;
import android.widget.ImageView;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Downloads and decodes artwork images, scaled down to the column width.
 * Memory: an LRU of decoded bitmaps (1/8 of the app heap); disk: the
 * HttpResponseCache installed by OverlayService.
 */
final class ImageLoader {
    private static ImageLoader instance;

    static synchronized ImageLoader get() {
        if (instance == null) instance = new ImageLoader();
        return instance;
    }

    private final ExecutorService pool = Executors.newFixedThreadPool(4);
    private final Handler main = new Handler(Looper.getMainLooper());
    private final LruCache<String, Bitmap> cache = new LruCache<String, Bitmap>(
            (int) (Runtime.getRuntime().maxMemory() / 8)) {
        @Override
        protected int sizeOf(String key, Bitmap b) {
            return b.getAllocationByteCount();
        }
    };

    /** Loads {@code url} into {@code view} unless the view has been recycled for another URL. */
    void load(String url, ImageView view, int targetWidth) {
        view.setTag(url);
        Bitmap hit = cache.get(url);
        if (hit != null) {
            view.setImageBitmap(hit);
            return;
        }
        view.setImageDrawable(null);
        pool.execute(() -> {
            Bitmap b = null;
            try {
                byte[] data = Sources.get(url);
                BitmapFactory.Options o = new BitmapFactory.Options();
                o.inJustDecodeBounds = true;
                BitmapFactory.decodeByteArray(data, 0, data.length, o);
                int sample = 1;
                while (o.outWidth / (sample * 2) >= targetWidth) sample *= 2;
                o = new BitmapFactory.Options();
                o.inSampleSize = sample;
                b = BitmapFactory.decodeByteArray(data, 0, data.length, o);
            } catch (Exception | OutOfMemoryError ignored) {
                // leave the placeholder; the row keeps its text
            }
            Bitmap fb = b;
            main.post(() -> {
                if (fb == null) return;
                cache.put(url, fb);
                if (url.equals(view.getTag())) view.setImageBitmap(fb);
            });
        });
    }
}
