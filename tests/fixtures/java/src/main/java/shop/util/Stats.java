package shop.util;

public final class Stats {
    private Stats() {
    }

    public static int max(int a, int b) {
        return a > b ? a : b;
    }

    public static <T extends Comparable<T>> T larger(T a, T b) {
        return a.compareTo(b) > 0 ? a : b;
    }

    public static int factorial(int n) {
        if (n <= 1) {
            return 1;
        }
        return n * factorial(n - 1);
    }
}
