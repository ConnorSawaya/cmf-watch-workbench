package app.cmfworkbench;

import static app.cmfworkbench.protocol.Bytes.require;

import android.util.Xml;
import java.io.StringReader;
import java.nio.charset.StandardCharsets;
import java.util.*;
import org.json.*;
import org.xmlpull.v1.XmlPullParser;

final class BookmarkFiles {
  private BookmarkFiles() {}

  static WatchController.SavedPlace point(String name, double latitude, double longitude) {
    require(
        Double.isFinite(latitude)
            && Double.isFinite(longitude)
            && Math.abs(latitude) <= 85
            && Math.abs(longitude) <= 180,
        "Invalid bookmark coordinates");
    String label = name.trim();
    require(!label.isEmpty() && label.length() <= 256, "Invalid bookmark name");
    return new WatchController.SavedPlace(
        label,
        Math.toRadians(longitude) * 6378137,
        -6378137 * Math.log(Math.tan(Math.PI / 4 + Math.toRadians(latitude) / 2)));
  }

  static List<WatchController.SavedPlace> read(byte[] data) throws Exception {
    require(data.length <= 5_000_000, "Bookmark file exceeds 5 MB");
    String text = new String(data, StandardCharsets.UTF_8).trim();
    List<WatchController.SavedPlace> out = new ArrayList<>();
    if (text.startsWith("{")) {
      JSONObject root = new JSONObject(text);
      JSONArray features = root.optJSONArray("features");
      if (features == null) features = new JSONArray().put(root);
      for (int i = 0; i < features.length(); i++) {
        JSONObject feature = features.getJSONObject(i), g = feature.optJSONObject("geometry");
        if (g == null || !g.optString("type").equals("Point")) continue;
        JSONArray c = g.getJSONArray("coordinates");
        JSONObject p = feature.optJSONObject("properties");
        String name = p == null ? "Saved place" : p.optString("name", "Saved place");
        out.add(point(name, c.getDouble(1), c.getDouble(0)));
        require(out.size() <= 1000, "At most 1,000 point bookmarks can be imported");
      }
    } else {
      XmlPullParser parser = Xml.newPullParser();
      parser.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, true);
      parser.setInput(new StringReader(text));
      Double lat = null, lon = null;
      String name = "Saved place";
      boolean waypoint = false;
      for (int event = parser.getEventType();
          event != XmlPullParser.END_DOCUMENT;
          event = parser.nextToken()) {
        require(
            event != XmlPullParser.DOCDECL && event != XmlPullParser.ENTITY_REF,
            "XML entities are not supported");
        if (event == XmlPullParser.START_TAG) {
          String tag = parser.getName();
          if (tag.equals("wpt")) {
            waypoint = true;
            lat = Double.parseDouble(parser.getAttributeValue(null, "lat"));
            lon = Double.parseDouble(parser.getAttributeValue(null, "lon"));
            name = "Saved place";
          } else if (waypoint && tag.equals("name")) {
            name = parser.nextText();
          }
        } else if (event == XmlPullParser.END_TAG && parser.getName().equals("wpt") && waypoint) {
          out.add(point(name, lat, lon));
          require(out.size() <= 1000, "At most 1,000 point bookmarks can be imported");
          waypoint = false;
        }
      }
    }
    return new ArrayList<>(new LinkedHashSet<>(out));
  }

  static double latitude(double y) {
    return Math.toDegrees(2 * Math.atan(Math.exp(-y / 6378137)) - Math.PI / 2);
  }

  static double longitude(double x) {
    return Math.toDegrees(x / 6378137);
  }

  private static String escape(String s) {
    return s.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("\"", "&quot;")
        .replace("'", "&apos;");
  }

  static byte[] export(List<WatchController.SavedPlace> places) {
    StringBuilder out =
        new StringBuilder(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><gpx version=\"1.1\" creator=\"CMF"
                + " Workbench\" xmlns=\"http://www.topografix.com/GPX/1/1\">");
    for (var p : places)
      out.append(
          String.format(
              Locale.ROOT,
              "<wpt lat=\"%.7f\" lon=\"%.7f\"><name>%s</name></wpt>",
              latitude(p.y()),
              longitude(p.x()),
              escape(p.name())));
    return out.append("</gpx>").toString().getBytes(StandardCharsets.UTF_8);
  }
}
