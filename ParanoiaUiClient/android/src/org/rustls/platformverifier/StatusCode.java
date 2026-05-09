package org.rustls.platformverifier;

public final class StatusCode {
    public static final int OK = 0;
    public static final int UNAVAILABLE = 1;
    public static final int EXPIRED = 2;
    public static final int UNKNOWN_CERT = 3;
    public static final int REVOKED = 4;
    public static final int INVALID_ENCODING = 5;
    public static final int INVALID_EXTENSION = 6;

    private StatusCode() {}
}
