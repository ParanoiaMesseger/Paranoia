package org.rustls.platformverifier;

public final class VerificationResult {
    public final int code;
    public final String message;

    public VerificationResult(int code, String message) {
        this.code = code;
        this.message = message;
    }

    public static VerificationResult ok() {
        return new VerificationResult(StatusCode.OK, null);
    }
}
