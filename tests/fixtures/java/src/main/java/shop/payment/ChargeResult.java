package shop.payment;

public record ChargeResult(boolean ok, String message) {
    public String message() {
        return message == null ? "" : message;
    }
}
