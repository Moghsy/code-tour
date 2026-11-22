package shop.catalog;

import com.vendor.Money;
import shop.util.Formatter;

public class Catalog {
    private final Formatter formatter = new Formatter();

    public String price(Money price) {
        return formatter.join(price.render(), "EUR");
    }

    public int depth(Category category) {
        if (category.parent() == null) {
            return 0;
        }
        return 1 + depth(category.parent());
    }

    public int combos(int n) {
        return Stats.factorial(n);
    }

    public record Category(String name, Category parent) {
    }
}
