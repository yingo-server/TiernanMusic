package com.tiernan.music

import android.content.Context
import android.os.Build
import java.io.BufferedInputStream
import java.io.ByteArrayInputStream
import java.io.IOException
import java.security.GeneralSecurityException
import java.security.KeyStore
import java.security.cert.Certificate
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

/**
 * B-4：Android 5.1 (API 22) 系统证书库不含 ISRG Root X1/X2（Let's Encrypt 2021 后签发），
 * 导致 LE 证书的 HTTPS 站点握手失败。
 *
 * 方案：从 res/raw 加载 ISRG Root X1/X2 PEM，与系统信任库合并，构造自定义 SSLContext，
 * 经 HttpsURLConnection.setDefaultSSLSocketFactory 全局生效。
 *
 * 注意：network_security_config 仅 API 24+ 生效，API 22-23 必须走此 Kotlin 方案。
 * ExoPlayer (just_audio) 与 dio 的底层 HttpURLConnection 均受其影响。
 */
object TlsCompat {

    private const val TAG = "TlsCompat"

    /** 已安装标记，避免重复 install 重建 SSLContext */
    @Volatile
    private var installed = false

    /**
     * 加载 raw 资源中的 PEM 根证书 + 系统默认信任库，合并为一个 TrustManager，
     * 设置为全局默认 SSLSocketFactory。幂等，重复调用安全。
     */
    @Synchronized
    fun install(context: Context) {
        if (installed) return
        try {
            val customCerts = loadRawCertificates(context)

            // 系统默认信任锚
            val systemTmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
            systemTmf.init(null as KeyStore?)
            val systemTrustManager = systemTmf.trustManagers.filterIsInstance<X509TrustManager>().firstOrNull()
                ?: throw GeneralSecurityException("no system X509TrustManager")

            val mergedTm = MergedTrustManager(systemTrustManager, customCerts)

            val sslContext = SSLContext.getInstance("TLS")
            sslContext.init(null, arrayOf(mergedTm), null)

            // 全局生效：dio(OkHttp/HttpURLConnection 栈) 与 ExoPlayer 的 DefaultHttpDataSource
            // 均读取 HttpsURLConnection 默认 SSLSocketFactory
            HttpsURLConnection.setDefaultSSLSocketFactory(sslContext.socketFactory)
            installed = true
            android.util.Log.i(TAG, "TLS compat installed: ${customCerts.size} custom roots merged")
        } catch (e: Exception) {
            // 安装失败不阻断启动：API 22 上只是 LE 域名握手可能失败，系统证书域名不受影响
            android.util.Log.w(TAG, "TLS compat install failed", e)
        }
    }

    /** 从 res/raw/isrg_root_x1.pem / isrg_root_x2.pem 解析 PEM 证书 */
    private fun loadRawCertificates(context: Context): List<Certificate> {
        val cf = CertificateFactory.getInstance("X.509")
        val certs = mutableListOf<Certificate>()
        val res = context.resources
        val names = listOf("isrg_root_x1", "isrg_root_x2")
        for (name in names) {
            val id = res.getIdentifier(name, "raw", context.packageName)
            if (id == 0) {
                android.util.Log.w(TAG, "raw resource $name not found, skip")
                continue
            }
            BufferedInputStream(res.openRawResource(id)).use { input ->
                certs.addAll(cf.generateCertificates(input))
            }
        }
        return certs
    }

    /**
     * 合并信任管理器：先走系统信任库，失败则回退到自定义根证书集合。
     * 未通过两者任一的链才抛出异常（保持标准校验语义，不放开校验）。
     */
    private class MergedTrustManager(
        private val system: X509TrustManager,
        private val customRoots: List<Certificate>
    ) : X509TrustManager {

        private val customTm: X509TrustManager by lazy {
            val ks = KeyStore.getInstance(KeyStore.getDefaultType())
            ks.load(null, null)
            customRoots.forEachIndexed { i, cert ->
                val alias = "isrg-custom-$i"
                ks.setCertificateEntry(alias, cert)
                // 让自定义根能正确匹配链中 issuer（保持 X509 完整校验）
            }
            val tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
            tmf.init(ks)
            tmf.trustManagers.filterIsInstance<X509TrustManager>().first()
        }

        override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) {
            // 本应用为客户端，客户端信任场景极少触发；委托系统
            system.checkClientTrusted(chain, authType)
        }

        override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
            try {
                system.checkServerTrusted(chain, authType)
            } catch (e: java.security.cert.CertificateException) {
                // 系统信任库不认 → 用自定义 LE 根重试（API 22 缺 ISRG Root 的场景）
                customTm.checkServerTrusted(chain, authType)
            }
        }

        override fun getAcceptedIssuers(): Array<X509Certificate> =
            system.acceptedIssuers + customTm.acceptedIssuers
    }
}
