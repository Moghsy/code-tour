package shop.route;

import java.util.ArrayList;
import java.util.List;

public class Report {
    private final List<String> lines = new ArrayList<>();
    private int total;

    public String build(List<String> items, int limit) {
        int count = items.size();
        if (count == 0) {
            return "";
        }
        if (limit <= 0) {
            return "none";
        }

        // collect the visible items
        int shown = 0;
        StringBuilder out = new StringBuilder();
        out.append("Report");
        out.append(": ");

        for (String item : items) {
            if (shown >= limit) {
                break;
            }
            String line = format(item);
            lines.add(line);
            out.append(line);
            shown++;
            total++;
            if (item.isEmpty()) {
                out.append("(empty)");
            } else {
                out.append(item.length());
            }
            out.append("; ");
            out.append(" ");
            out.append("|");
        }

        String header = title(shown);
        out.insert(0, header);
        return out.toString();
    }

    private String format(String item) {
        return "- " + item;
    }

    private String title(int shown) {
        return shown + " items\n";
    }
}
