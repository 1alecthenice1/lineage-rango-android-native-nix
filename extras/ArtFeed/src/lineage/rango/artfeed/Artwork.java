package lineage.rango.artfeed;

/** One public-domain artwork as shown in the feed. */
final class Artwork {
    final String key;        // museum + object id, for de-duplication
    final String title;
    final String artist;     // may be empty
    final String date;       // may be empty
    final String origin;     // culture / department, may be empty
    final String medium;     // may be empty
    final String museum;     // credit line
    final String imageUrl;
    final String pageUrl;    // museum's object page

    Artwork(String key, String title, String artist, String date, String origin,
            String medium, String museum, String imageUrl, String pageUrl) {
        this.key = key;
        this.title = title.isEmpty() ? "Untitled" : title;
        this.artist = artist;
        this.date = date;
        this.origin = origin;
        this.medium = medium;
        this.museum = museum;
        this.imageUrl = imageUrl;
        this.pageUrl = pageUrl;
    }

    /** "artist · date" (whatever is known) */
    String byline() {
        return join(" · ", artist, date);
    }

    static String join(String sep, String... parts) {
        StringBuilder b = new StringBuilder();
        for (String p : parts) {
            if (p == null || p.isEmpty()) continue;
            if (b.length() > 0) b.append(sep);
            b.append(p);
        }
        return b.toString();
    }
}
