package lineage.rango.artfeed;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Random;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Future;

/**
 * Open-access museum collections (public domain / CC0, no API key):
 * - The Met: collectionapi.metmuseum.org (search v1.1 — v1 was retired 2026-10-01)
 * - Cleveland Museum of Art: openaccess-api.clevelandart.org
 * Variety: every department of both museums is a "slot"; slots are dealt from a
 * shuffled deck, a few works per slot and a random offset each time, so the feed
 * moves between cultures, eras and media instead of staying with one collection.
 * Not used (2026-11-21, tested from a shared VPN address): Art Institute of Chicago
 * (Cloudflare challenge for shared VPN addresses), SMK Copenhagen (image server
 * unreachable).
 */
final class Sources {
    static final String USER_AGENT = "ArtFeed/1.0 (LineageOS home-screen feed)";
    private static final int PER_SLOT = 3;

    interface Slot {
        List<Artwork> fetch(int n, Random rnd) throws IOException, JSONException;
    }

    private final List<Slot> deck = new ArrayList<>();
    private final List<Slot> slots = new ArrayList<>();
    private final Random rnd = new Random();
    private final ExecutorService slotPool;   // one task per slot
    private final ExecutorService io;         // object requests made by a slot (separate: no deadlock)

    Sources(ExecutorService slotPool, ExecutorService io) {
        this.slotPool = slotPool;
        this.io = io;
        // Met departments with public-domain images (ids from /v1/departments)
        int[] met = {1, 3, 4, 5, 6, 8, 9, 10, 11, 12, 13, 14, 15, 17, 19, 21};
        for (int d : met) slots.add(new MetSlot(d));
        String[] cma = {"African Art", "American Painting and Sculpture", "Art of the Americas",
                "Chinese Art", "Decorative Art and Design", "Drawings",
                "Egyptian and Ancient Near Eastern Art", "European Painting and Sculpture",
                "Greek and Roman Art", "Indian and Southeast Asian Art", "Islamic Art",
                "Japanese Art", "Korean Art", "Medieval Art",
                "Modern European Painting and Sculpture", "Oceania", "Photography", "Prints",
                "Textiles"};
        for (String d : cma) slots.add(new ClevelandSlot(d));
    }

    /** Next batch: {@code slotCount} slots in parallel, interleaved so neighbours differ. */
    List<Artwork> next(int slotCount) throws IOException {
        List<Future<List<Artwork>>> jobs = new ArrayList<>();
        for (int i = 0; i < slotCount; i++) {
            Slot s = deal();
            jobs.add(slotPool.submit(() -> s.fetch(PER_SLOT, rnd)));
        }
        List<List<Artwork>> got = new ArrayList<>();
        IOException last = null;
        for (Future<List<Artwork>> f : jobs) {
            try {
                got.add(f.get());
            } catch (Exception e) {
                last = new IOException(e.getCause() != null ? e.getCause() : e);
            }
        }
        List<Artwork> out = new ArrayList<>();
        for (int i = 0; i < PER_SLOT; i++) {
            for (List<Artwork> l : got) if (i < l.size()) out.add(l.get(i));
        }
        if (out.isEmpty() && last != null) throw last;
        return out;
    }

    private synchronized Slot deal() {
        if (deck.isEmpty()) {
            deck.addAll(slots);
            Collections.shuffle(deck, rnd);
        }
        return deck.remove(deck.size() - 1);
    }

    // ── The Met ──
    private final class MetSlot implements Slot {
        private final int department;
        private int total = -1;

        MetSlot(int department) { this.department = department; }

        @Override
        public List<Artwork> fetch(int n, Random rnd) throws IOException, JSONException {
            String base = "https://collectionapi.metmuseum.org/public/collection/v1.1/search"
                    + "?departmentId=" + department + "&hasImages=true&isPublicDomain=true&q=*";
            if (total < 0) total = getJson(base + "&limit=1").optInt("total", 0);
            if (total == 0) return Collections.emptyList();
            int want = n * 3;   // the filters are approximate: check each object
            int offset = rnd.nextInt(Math.max(1, total - want));
            JSONArray ids = getJson(base + "&offset=" + offset + "&limit=" + want)
                    .optJSONArray("objectIDs");
            if (ids == null) return Collections.emptyList();
            List<Future<JSONObject>> objs = new ArrayList<>();
            for (int i = 0; i < ids.length(); i++) {
                String u = "https://collectionapi.metmuseum.org/public/collection/v1/objects/"
                        + ids.getLong(i);
                objs.add(io.submit(() -> getJson(u)));
            }
            List<Artwork> out = new ArrayList<>();
            for (Future<JSONObject> f : objs) {
                if (out.size() >= n) { f.cancel(true); continue; }
                JSONObject o;
                try { o = f.get(); } catch (Exception e) { continue; }
                String img = o.optString("primaryImageSmall");
                if (!o.optBoolean("isPublicDomain") || img.isEmpty()) continue;
                out.add(new Artwork("met:" + o.optLong("objectID"),
                        o.optString("title"),
                        o.optString("artistDisplayName"),
                        o.optString("objectDate"),
                        Artwork.join(" · ", o.optString("culture"), o.optString("department")),
                        o.optString("medium"),
                        "The Metropolitan Museum of Art",
                        img, o.optString("objectURL")));
            }
            return out;
        }
    }

    // ── Cleveland Museum of Art ──
    private final class ClevelandSlot implements Slot {
        private final String department;
        private int total = -1;

        ClevelandSlot(String department) { this.department = department; }

        @Override
        public List<Artwork> fetch(int n, Random rnd) throws IOException, JSONException {
            String base = "https://openaccess-api.clevelandart.org/api/artworks/?cc0=1&has_image=1"
                    + "&department=" + URLEncoder.encode(department, "UTF-8");
            if (total < 0) {
                total = getJson(base + "&limit=1").getJSONObject("info").optInt("total", 0);
            }
            if (total == 0) return Collections.emptyList();
            int skip = rnd.nextInt(Math.max(1, total - n));
            JSONArray data = getJson(base + "&limit=" + n + "&skip=" + skip).getJSONArray("data");
            List<Artwork> out = new ArrayList<>();
            for (int i = 0; i < data.length(); i++) {
                JSONObject a = data.getJSONObject(i);
                JSONObject web = a.optJSONObject("images") == null ? null
                        : a.getJSONObject("images").optJSONObject("web");
                if (web == null || web.optString("url").isEmpty()) continue;
                JSONArray creators = a.optJSONArray("creators");
                String artist = creators != null && creators.length() > 0
                        ? creators.getJSONObject(0).optString("description") : "";
                JSONArray culture = a.optJSONArray("culture");
                String origin = culture != null && culture.length() > 0
                        ? culture.optString(0) : a.optString("department");
                out.add(new Artwork("cma:" + a.optLong("id"),
                        a.optString("title"), artist, a.optString("creation_date"),
                        origin, a.optString("technique"),
                        "Cleveland Museum of Art",
                        web.optString("url"), a.optString("url")));
            }
            return out;
        }
    }

    // ── HTTP ──
    static JSONObject getJson(String url) throws IOException, JSONException {
        return new JSONObject(new String(get(url), StandardCharsets.UTF_8));
    }

    static byte[] get(String url) throws IOException {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        c.setConnectTimeout(15000);
        c.setReadTimeout(20000);
        c.setRequestProperty("User-Agent", USER_AGENT);
        try {
            int code = c.getResponseCode();
            if (code != 200) throw new IOException("HTTP " + code + " for " + url);
            try (InputStream in = c.getInputStream()) {
                ByteArrayOutputStream b = new ByteArrayOutputStream();
                byte[] buf = new byte[16384];
                for (int r; (r = in.read(buf)) > 0; ) b.write(buf, 0, r);
                return b.toByteArray();
            }
        } finally {
            c.disconnect();
        }
    }
}
