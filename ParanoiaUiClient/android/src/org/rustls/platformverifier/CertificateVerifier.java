package org.rustls.platformverifier;

import android.content.Context;
import android.net.http.X509TrustManagerExtensions;

import java.io.ByteArrayInputStream;
import java.security.GeneralSecurityException;
import java.security.KeyStore;
import java.security.cert.CertificateException;
import java.security.cert.CertificateExpiredException;
import java.security.cert.CertificateFactory;
import java.security.cert.CertificateNotYetValidException;
import java.security.cert.CertificateParsingException;
import java.security.cert.X509Certificate;
import java.util.Arrays;
import java.util.Date;
import java.util.List;

import javax.net.ssl.TrustManager;
import javax.net.ssl.TrustManagerFactory;
import javax.net.ssl.X509TrustManager;

public final class CertificateVerifier {
    private static final CertificateFactory CERTIFICATE_FACTORY = createCertificateFactory();

    private CertificateVerifier() {}

    public static VerificationResult verifyCertificateChain(
            Context context,
            String serverName,
            String authMethod,
            String[] allowedEkus,
            byte[] ocspResponse,
            long time,
            byte[][] certChain) {
        if (context == null || serverName == null || authMethod == null || certChain == null || certChain.length == 0) {
            return new VerificationResult(StatusCode.INVALID_ENCODING, "invalid verifier input");
        }

        final X509Certificate[] chain;
        try {
            chain = decodeCertificateChain(certChain);
            checkValidity(chain, new Date(time));
            if (!hasAllowedServerEku(chain[0], allowedEkus)) {
                return new VerificationResult(StatusCode.INVALID_EXTENSION, "certificate is not valid for server auth");
            }
        } catch (CertificateExpiredException | CertificateNotYetValidException e) {
            return new VerificationResult(StatusCode.EXPIRED, e.getMessage());
        } catch (CertificateParsingException e) {
            return new VerificationResult(StatusCode.INVALID_EXTENSION, e.getMessage());
        } catch (CertificateException e) {
            return new VerificationResult(StatusCode.INVALID_ENCODING, e.getMessage());
        }

        try {
            X509TrustManagerExtensions trustManager = new X509TrustManagerExtensions(defaultTrustManager());
            trustManager.checkServerTrusted(chain, authMethod, serverName);
            return VerificationResult.ok();
        } catch (CertificateException e) {
            if (hasCause(e, CertificateExpiredException.class) || hasCause(e, CertificateNotYetValidException.class)) {
                return new VerificationResult(StatusCode.EXPIRED, e.getMessage());
            }
            return new VerificationResult(StatusCode.UNKNOWN_CERT, e.getMessage());
        } catch (GeneralSecurityException | RuntimeException e) {
            return new VerificationResult(StatusCode.UNAVAILABLE, e.getMessage());
        }
    }

    private static CertificateFactory createCertificateFactory() {
        try {
            return CertificateFactory.getInstance("X.509");
        } catch (CertificateException e) {
            throw new ExceptionInInitializerError(e);
        }
    }

    private static X509Certificate[] decodeCertificateChain(byte[][] certChain) throws CertificateException {
        X509Certificate[] chain = new X509Certificate[certChain.length];
        for (int i = 0; i < certChain.length; ++i) {
            if (certChain[i] == null) {
                throw new CertificateException("null certificate");
            }
            chain[i] = (X509Certificate) CERTIFICATE_FACTORY.generateCertificate(new ByteArrayInputStream(certChain[i]));
        }
        return chain;
    }

    private static void checkValidity(X509Certificate[] chain, Date time)
            throws CertificateExpiredException, CertificateNotYetValidException {
        for (X509Certificate certificate : chain) {
            certificate.checkValidity(time);
        }
    }

    private static boolean hasAllowedServerEku(X509Certificate certificate, String[] allowedEkus)
            throws CertificateParsingException {
        List<String> certificateEkus = certificate.getExtendedKeyUsage();
        if (certificateEkus == null || certificateEkus.isEmpty()) {
            return true;
        }
        if (allowedEkus == null || allowedEkus.length == 0) {
            return false;
        }
        List<String> allowed = Arrays.asList(allowedEkus);
        for (String eku : certificateEkus) {
            if (allowed.contains(eku)) {
                return true;
            }
        }
        return false;
    }

    private static X509TrustManager defaultTrustManager() throws GeneralSecurityException {
        TrustManagerFactory factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
        factory.init((KeyStore) null);
        for (TrustManager manager : factory.getTrustManagers()) {
            if (manager instanceof X509TrustManager) {
                return (X509TrustManager) manager;
            }
        }
        throw new GeneralSecurityException("no X509 trust manager available");
    }

    private static boolean hasCause(Throwable error, Class<? extends Throwable> causeType) {
        Throwable current = error;
        while (current != null) {
            if (causeType.isInstance(current)) {
                return true;
            }
            current = current.getCause();
        }
        return false;
    }
}
