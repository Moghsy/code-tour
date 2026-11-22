package shop.route;

public class Upper implements Step {
    @Override
    public String apply(String value) {
        String upper = value.toUpperCase();
        return upper + "?";
    }
}
