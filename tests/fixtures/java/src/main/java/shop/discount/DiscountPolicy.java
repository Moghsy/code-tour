package shop.discount;

import shop.money.Money;
import shop.order.Order;
import shop.util.Formatter;
import static shop.util.Stats.max;

public class DiscountPolicy {
    private final Formatter formatter = new Formatter();

    public Money apply(Order order, Money total) {
        int count = order.getLines().size();
        int best = max(count, 3);
        int capped = Math.max(best, 10);
        formatter.format(total);
        formatter.format("count");
        formatter.format(capped);
        formatter.format(order.getCustomer());
        return total.times(100 - best);
    }
}
