package shop.payment;

import shop.money.Money;

public interface PaymentGateway {
    ChargeResult charge(Money amount);

    default void log(String message) {
        System.out.println(message);
    }
}
