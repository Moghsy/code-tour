package shop.order;

import java.util.ArrayList;
import java.util.List;
import shop.money.Money;

public class Order {
    private final String customer;
    private final List<Line> lines = new ArrayList<>();
    private boolean paid;

    public Order(String customer) {
        this.customer = customer;
    }

    public Money total() {
        Money sum = Money.zero();
        for (Line line : lines) {
            sum = sum.plus(line.subtotal());
        }
        return sum;
    }

    public boolean isPaid() {
        return paid;
    }

    public void markPaid() {
        this.paid = true;
    }

    public List<Line> getLines() {
        return lines;
    }

    public String getCustomer() {
        return customer;
    }

    public String summary() {
        return total().format();
    }
}
