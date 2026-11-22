package shop.order;

import java.util.List;
import shop.discount.DiscountPolicy;
import shop.money.Money;
import shop.payment.*;
import shop.notify.Notifier;

public class OrderService {
    private final PaymentGateway gateway;
    private final DiscountPolicy discounts;
    private final Notifier notifier;
    private int processed;

    public OrderService(PaymentGateway gateway, DiscountPolicy discounts, Notifier notifier) {
        this.gateway = gateway;
        this.discounts = discounts;
        this.notifier = notifier;
    }

    public Receipt checkout(Order order) {
        if (order.isPaid()) {
            throw new IllegalStateException("already paid");
        }
        if (order.getLines().isEmpty()) {
            return null;
        }

        Money total = order.total();
        Money discounted = discounts.apply(order, total);
        ChargeResult result = gateway.charge(discounted);
        if (!result.ok()) {
            return failed(result.message());
        }
        order.markPaid();
        processed++;
        notifier.send(order.getCustomer(), "paid");
        return receipt(order, discounted);
    }

    private Receipt receipt(Order order, Money amount) {
        return new Receipt(order.getCustomer(), amount);
    }

    private Receipt failed(String reason) {
        return new Receipt(reason, Money.zero());
    }

    public void audit(List<Order> orders) {
        for (Order o : orders) {
            o.getLines().forEach(line -> line.describe());
            o.getLines().forEach(line -> line.size());
        }
        orders.forEach(this::log);
        var copy = new Order("copy");
        copy.total();
        Order first = (Order) orders.get(0);
        first.markPaid();
    }

    int processed() {
        return processed;
    }

    private void log(Order order) {
        System.out.println(order.getCustomer());
    }

    public class Receipt {
        private final String customer;
        private final Money amount;

        public Receipt(String customer, Money amount) {
            this.customer = customer;
            this.amount = amount;
        }

        public String summary() {
            return customer + " " + amount.format() + " #" + OrderService.this.processed();
        }
    }
}
