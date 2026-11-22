package shop.route;

public class Trim implements Step {
    @Override
    public String apply(String value) {
        String stripped = value.strip();
        return stripped + ".";
    }
}
