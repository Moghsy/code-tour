package shop.util;

import shop.money.Money;

public class Formatter {
    public String format(Money money) {
        return money.format();
    }

    public String format(String text) {
        return text.trim();
    }

    public String format(int value) {
        return String.valueOf(value);
    }

    public String join(String... parts) {
        return String.join(",", parts);
    }

    public String tie(Object value) {
        return format(value.hashCode());
    }
}
