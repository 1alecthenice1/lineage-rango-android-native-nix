package lineage.rango.artfeed;

import android.content.Context;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.widget.AbsListView;
import android.widget.BaseAdapter;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.TextView;

import java.util.HashSet;
import java.util.Set;

/**
 * The feed: a header, one card per artwork (image, title, artist · date; a tap
 * shows origin, medium, credit and a link), a status row at the end. Endless:
 * the next batch loads a few cards before the end. Everforest dark colours, like
 * the system palette of this build.
 */
final class FeedView extends FrameLayout implements FeedStore.Listener {
    interface Host { void openUrl(String url); }

    static final int BG = 0xFF2D353B, BG_CARD = 0xFF343F44, BG_IMAGE = 0xFF3D484D,
            FG = 0xFFD3C6AA, GREY = 0xFF859289, GREEN = 0xFFA7C080;
    private static final int MAX_COLUMN_DP = 620;

    private final FeedStore store = FeedStore.get();
    private final Host host;
    private final ListView list;
    private final Adapter adapter = new Adapter();
    private final Set<String> expanded = new HashSet<>();
    private final TextView status;
    private int columnWidth;

    FeedView(Context context, Host host) {
        super(context);
        this.host = host;
        setBackgroundColor(BG);

        list = new ListView(context);
        list.setDivider(null);
        list.setSelector(new ColorDrawable(Color.TRANSPARENT));
        list.setClipToPadding(false);
        list.setVerticalScrollBarEnabled(false);
        list.addHeaderView(header(), null, false);
        status = text(15, GREY, Typeface.NORMAL);
        status.setGravity(Gravity.CENTER);
        status.setPadding(0, dp(24), 0, dp(32));
        status.setOnClickListener(v -> { if (store.error != null) store.loadMore(); });
        list.addFooterView(status, null, false);
        list.setAdapter(adapter);
        list.setOnScrollListener(new AbsListView.OnScrollListener() {
            @Override public void onScrollStateChanged(AbsListView v, int state) { }
            @Override
            public void onScroll(AbsListView v, int first, int visible, int total) {
                if (!store.items.isEmpty() && store.error == null && first + visible >= total - 4) {
                    store.loadMore();
                }
            }
        });
        addView(list, new LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT));
        updateStatus();
    }

    @Override
    protected void onAttachedToWindow() {
        super.onAttachedToWindow();
        store.addListener(this);
        adapter.notifyDataSetChanged();
        updateStatus();
    }

    @Override
    protected void onDetachedFromWindow() {
        store.removeListener(this);
        super.onDetachedFromWindow();
    }

    @Override
    public void onFeedChanged() {
        adapter.notifyDataSetChanged();
        updateStatus();
    }

    void scrollToTop() { list.setSelection(0); }

    @Override
    public WindowInsets onApplyWindowInsets(WindowInsets insets) {
        android.graphics.Insets bars = insets.getInsets(
                WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
        list.setPadding(list.getPaddingLeft(), bars.top, list.getPaddingRight(), bars.bottom);
        return insets;
    }

    @Override
    protected void onSizeChanged(int w, int h, int oldw, int oldh) {
        super.onSizeChanged(w, h, oldw, oldh);
        int side = Math.max(dp(12), (w - dp(MAX_COLUMN_DP)) / 2);
        columnWidth = w - 2 * side;
        list.setPadding(side, list.getPaddingTop(), side, list.getPaddingBottom());
    }

    private void updateStatus() {
        if (store.loading) status.setText("Loading…");
        else if (store.error != null) status.setText(store.error + " — tap to retry");
        else status.setText(store.items.isEmpty() ? "" : "Loading more as you scroll");
    }

    private View header() {
        LinearLayout h = new LinearLayout(getContext());
        h.setOrientation(LinearLayout.HORIZONTAL);
        h.setGravity(Gravity.CENTER_VERTICAL);
        h.setPadding(dp(4), dp(20), dp(4), dp(16));
        LinearLayout titles = new LinearLayout(getContext());
        titles.setOrientation(LinearLayout.VERTICAL);
        TextView title = text(30, FG, Typeface.BOLD);
        title.setText("Art");
        TextView sub = text(13, GREY, Typeface.NORMAL);
        sub.setText("Public domain works from The Met and the Cleveland Museum of Art");
        titles.addView(title);
        titles.addView(sub);
        h.addView(titles, new LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1));
        TextView shuffle = text(15, BG, Typeface.BOLD);
        shuffle.setText("Shuffle");
        shuffle.setPadding(dp(16), dp(8), dp(16), dp(8));
        shuffle.setBackground(round(GREEN, dp(18)));
        shuffle.setOnClickListener(v -> { expanded.clear(); store.shuffle(); scrollToTop(); });
        h.addView(shuffle);
        return h;
    }

    private final class Adapter extends BaseAdapter {
        @Override public int getCount() { return store.items.size(); }
        @Override public Artwork getItem(int i) { return store.items.get(i); }
        @Override public long getItemId(int i) { return i; }
        @Override public boolean hasStableIds() { return false; }

        @Override
        public View getView(int i, View convert, ViewGroup parent) {
            Card c = convert instanceof Card ? (Card) convert : new Card(getContext());
            c.bind(getItem(i));
            return c;
        }
    }

    /** One artwork. */
    private final class Card extends LinearLayout {
        private final ArtImage image;
        private final TextView title, byline, details, link;
        private Artwork art;

        Card(Context ctx) {
            super(ctx);
            setOrientation(VERTICAL);
            setPadding(0, 0, 0, dp(12));
            LinearLayout box = new LinearLayout(ctx);
            box.setOrientation(VERTICAL);
            box.setBackground(round(BG_CARD, dp(16)));
            box.setClipToOutline(true);
            image = new ArtImage(ctx);
            box.addView(image, new LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT));
            LinearLayout texts = new LinearLayout(ctx);
            texts.setOrientation(VERTICAL);
            texts.setPadding(dp(16), dp(12), dp(16), dp(14));
            title = text(17, FG, Typeface.BOLD);
            title.setMaxLines(3);
            title.setEllipsize(TextUtils.TruncateAt.END);
            byline = text(14, GREY, Typeface.NORMAL);
            details = text(14, FG, Typeface.NORMAL);
            details.setPadding(0, dp(8), 0, 0);
            link = text(14, GREEN, Typeface.BOLD);
            link.setPadding(0, dp(10), 0, 0);
            link.setText("Open on the museum's site");
            link.setOnClickListener(v -> { if (art != null) host.openUrl(art.pageUrl); });
            texts.addView(title);
            texts.addView(byline);
            texts.addView(details);
            texts.addView(link);
            box.addView(texts);
            addView(box);
            box.setOnClickListener(v -> {
                if (art == null) return;
                if (!expanded.remove(art.key)) expanded.add(art.key);
                bindDetails();
            });
        }

        void bind(Artwork a) {
            art = a;
            title.setText(a.title);
            String by = a.byline();
            byline.setText(by);
            byline.setVisibility(by.isEmpty() ? GONE : VISIBLE);
            bindDetails();
            ImageLoader.get().load(a.imageUrl, image, columnWidth > 0 ? columnWidth : dp(400));
        }

        private void bindDetails() {
            boolean open = expanded.contains(art.key);
            details.setText(Artwork.join("\n", art.origin, art.medium,
                    art.museum + " · public domain"));
            details.setVisibility(open ? VISIBLE : GONE);
            link.setVisibility(open && !art.pageUrl.isEmpty() ? VISIBLE : GONE);
        }
    }

    /** Full column width, height from the image's aspect ratio; a placeholder while loading. */
    private final class ArtImage extends ImageView {
        ArtImage(Context ctx) {
            super(ctx);
            setScaleType(ScaleType.FIT_CENTER);
            setBackgroundColor(BG_IMAGE);
        }

        @Override
        protected void onMeasure(int wSpec, int hSpec) {
            int w = MeasureSpec.getSize(wSpec);
            Drawable d = getDrawable();
            int h = dp(260);
            if (d != null && d.getIntrinsicWidth() > 0) {
                h = (int) ((long) w * d.getIntrinsicHeight() / d.getIntrinsicWidth());
                h = Math.min(h, (int) (w * 1.6f));   // very tall works: cap, fit inside
            }
            setMeasuredDimension(w, h);
        }
    }

    // ── helpers ──
    private TextView text(float sp, int color, int style) {
        TextView t = new TextView(getContext());
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        t.setTextColor(color);
        t.setTypeface(Typeface.create(Typeface.DEFAULT, style));
        return t;
    }

    private static GradientDrawable round(int color, float radius) {
        GradientDrawable g = new GradientDrawable();
        g.setColor(color);
        g.setCornerRadius(radius);
        return g;
    }

    private int dp(float v) {
        return (int) (v * getResources().getDisplayMetrics().density + 0.5f);
    }
}
