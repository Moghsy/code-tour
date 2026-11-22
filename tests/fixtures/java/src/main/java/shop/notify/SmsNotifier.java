package shop.notify;

public class SmsNotifier implements Notifier {
    @Override
    public void send(String to, String text) {
        System.out.println("sms " + to + ": " + text);
    }
}
