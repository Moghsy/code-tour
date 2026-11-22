package shop.order;

import shop.money.Money;

public record Line(String item, int quantity, Money price) {
    public Money subtotal() {
        return price.times(quantity());
    }

    public String describe() {
        return item() + " x" + quantity;
    }
}
