package lineage.rango.artfeed;

import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * The feed's items, shared by every overlay window of the process (the launcher
 * re-attaches the overlay on fold/unfold and rotation; the feed and its scroll
 * position survive that). Loading runs only while someone is looking: the first
 * open, the end of the list, or "shuffle".
 */
final class FeedStore {
    interface Listener { void onFeedChanged(); }

    private static final String TAG = "ArtFeed";
    private static final int SLOTS_PER_BATCH = 4;           // × 3 works = up to 12 per batch
    private static final long STALE_MS = 6 * 3600 * 1000L;  // reshuffle on open after 6 h

    private static FeedStore instance;

    static synchronized FeedStore get() {
        if (instance == null) instance = new FeedStore();
        return instance;
    }

    final List<Artwork> items = new ArrayList<>();
    boolean loading;
    String error;          // last failure, shown with a retry row

    private final Set<String> seen = new HashSet<>();
    private final List<Listener> listeners = new ArrayList<>();
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService batches = Executors.newSingleThreadExecutor();
    private final Sources sources = new Sources(Executors.newFixedThreadPool(SLOTS_PER_BATCH),
            Executors.newFixedThreadPool(8));
    private long loadedAt;
    private int generation;   // bumped by shuffle: drops results of older loads

    void addListener(Listener l) { listeners.add(l); }
    void removeListener(Listener l) { listeners.remove(l); }

    /** Called when the overlay opens. */
    void onOpened() {
        if (items.isEmpty() || SystemClock.elapsedRealtime() - loadedAt > STALE_MS) {
            shuffle();
        }
    }

    void shuffle() {
        generation++;
        items.clear();
        error = null;
        loading = false;
        loadMore();
    }

    void loadMore() {
        if (loading) return;
        loading = true;
        error = null;
        notifyChanged();
        int gen = generation;
        batches.execute(() -> {
            List<Artwork> got = null;
            String err = null;
            try {
                got = sources.next(SLOTS_PER_BATCH);
            } catch (Exception e) {
                Log.w(TAG, "loading failed", e);
                err = "Couldn't reach the museums";
            }
            List<Artwork> fGot = got;
            String fErr = err;
            main.post(() -> {
                if (gen != generation) return;
                loading = false;
                if (fGot != null) {
                    for (Artwork a : fGot) if (seen.add(a.key)) items.add(a);
                    loadedAt = SystemClock.elapsedRealtime();
                }
                error = fErr;
                notifyChanged();
            });
        });
    }

    private void notifyChanged() {
        for (Listener l : new ArrayList<>(listeners)) l.onFeedChanged();
    }
}
