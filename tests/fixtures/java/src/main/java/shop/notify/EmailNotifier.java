package shop.notify;

public class EmailNotifier implements Notifier {
    @Override
    public void send(String to, String text) {
        System.out.println("mail " + to + ": " + text);
    }
}
