package shop.payment;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import shop.money.Money;

public class CardGateway extends BaseGateway implements PaymentGateway {
    private final HttpClient http;

    public CardGateway(HttpClient http) {
        super();
        this.http = http;
    }

    public CardGateway() {
        this(HttpClient.newHttpClient());
    }

    @Override
    public ChargeResult charge(Money amount) {
        this.log("charging " + amount.format());
        if (amount.isZero()) {
            return new ChargeResult(true, "nothing to charge");
        }
        HttpRequest request = HttpRequest.newBuilder(URI.create("https://pay.example/charge")).build();
        http.send(request, HttpResponse.BodyHandlers.discarding());
        return new ChargeResult(true, "ok");
    }

    public String label() {
        return super.name();
    }
}
