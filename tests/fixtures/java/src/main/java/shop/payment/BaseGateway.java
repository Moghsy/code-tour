package shop.payment;

public abstract class BaseGateway {
    protected void log(String message) {
        System.err.println(message);
    }

    protected String name() {
        return "base";
    }
}
