package shop.route;

public interface Store {
    String load(String key);

    void save(String key, String value);
}
