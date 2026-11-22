package shop.money;

public class Money {
    private final long cents;

    public Money(long cents) {
        this.cents = cents;
    }

    public static Money zero() {
        return new Money(0);
    }

    public Money plus(Money other) {
        return new Money(cents + other.cents);
    }

    public Money times(int factor) {
        return new Money(cents * factor);
    }

    public boolean isZero() {
        return cents == 0;
    }

    public String format() {
        return Long.toString(cents);
    }
}
