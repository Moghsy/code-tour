package shop.route;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.Executor;

public class Pipeline {
    private final Store store;
    private final Executor executor;
    private final Step fallback;
    private final Step shaper = new Trim();
    private int runs;

    public Pipeline(Store store, Executor executor, Step fallback) {
        this.store = store;
        this.executor = executor;
        this.fallback = fallback;
    }

    public String run(String input) {
        if (input == null) {
            throw new IllegalArgumentException("input");
        }
        String clean = normalize(input);
        Step step = new Upper();
        String shaped = step.apply(clean);
        runs++;
        audit(shaped);
        return decide(shaped.length(), shaped);
    }

    private String normalize(String input) {
        String trimmed = input.trim();
        String lower = trimmed.toLowerCase();
        return lower.replace(' ', '-');
    }

    private void audit(String value) {
        int size = value.length();
        if (size > 10) {
            System.out.println("long " + value);
        }
    }

    String decide(int size, String value) {
        if (isInvalid(size)) {
            return reject(value);
        } else {
            return accept(value);
        }
    }

    private boolean isInvalid(int size) {
        return size <= 0;
    }

    private String reject(String value) {
        String reason = "rejected " + value;
        System.err.println(reason);
        return reason;
    }

    private String accept(String value) {
        String result = value + "!";
        System.out.println(result);
        return result;
    }

    public String pick(int code, String value) {
        switch (code) {
            case 0:
                return "zero";
            case 1:
                return accept(normalize(value));
            default:
                return reject(value);
        }
    }

    public String guarded(Path path, String text) {
        try {
            write(path, text);
            return "written";
        } catch (RuntimeException e) {
            return reject(text);
        }
    }

    private void write(Path path, String text) {
        byte[] bytes = text.getBytes();
        Files.write(path, bytes);
    }

    public void later(String value) {
        executor.execute(() -> accept(value));
    }

    public void persist(String value) {
        String key = normalize(value);
        store.save(key, value);
    }

    public String shapeBoth(String value) {
        return fallback.apply(value) + shaper.apply(value);
    }

    public String viaParam(String value) {
        return shapeWith(new Upper(), value);
    }

    private String shapeWith(Step with, String value) {
        String out = with.apply(value);
        return out + "~";
    }
}
