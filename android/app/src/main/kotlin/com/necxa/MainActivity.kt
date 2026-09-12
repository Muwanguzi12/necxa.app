package com.necxa

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Signature
import java.util.Base64
import java.math.BigInteger

class MainActivity : FlutterFragmentActivity() {
  private val channelName = "com.necxa/liveness_keystore"
  private val alias = "necxa_liveness_p256"
  private val b64 = Base64.getUrlEncoder().withoutPadding()

  override fun configureFlutterEngine(engine: FlutterEngine) {
    super.configureFlutterEngine(engine)
    MethodChannel(engine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
      try {
        when (call.method) {
          "getKeyInfo" -> result.success(keyInfo())
          "sign" -> result.success(sign(call.argument<String>("payload") ?: ""))
          else -> result.notImplemented()
        }
      } catch (error: Exception) {
        result.error("KEYSTORE_ERROR", error.message, null)
      }
    }
  }

  private fun keyStore(): KeyStore = KeyStore.getInstance("AndroidKeyStore").also { it.load(null) }
  private fun ensureKey() {
    if (keyStore().containsAlias(alias)) return
    val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
    generator.initialize(KeyGenParameterSpec.Builder(
      alias, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY
    ).setAlgorithmParameterSpec(java.security.spec.ECGenParameterSpec("secp256r1"))
      .setDigests(KeyProperties.DIGEST_SHA256)
      .setAttestationChallenge("necxa-sp2-liveness".toByteArray())
      .build())
    generator.generateKeyPair()
  }
  private fun keyInfo(): Map<String, Any> {
    ensureKey()
    val entry = keyStore().getEntry(alias, null) as KeyStore.PrivateKeyEntry
    val point = (entry.certificate.publicKey as java.security.interfaces.ECPublicKey).w
    fun coordinate(value: BigInteger) = b64.encode(value.toByteArray().let { bytes ->
      if (bytes.size == 32) bytes else if (bytes.size > 32) bytes.copyOfRange(bytes.size - 32, bytes.size) else ByteArray(32 - bytes.size) { 0 } + bytes
    }).toString()
    val certificates = (entry.certificateChain ?: arrayOf(entry.certificate)).map { b64.encode(it.encoded).toString() }
    return mapOf("keyId" to alias, "publicKeyJwk" to mapOf("kty" to "EC", "crv" to "P-256", "x" to coordinate(point.affineX), "y" to coordinate(point.affineY)), "attestationCertificates" to certificates)
  }
  private fun sign(payload: String): String {
    ensureKey()
    val signature = Signature.getInstance("SHA256withECDSA")
    signature.initSign((keyStore().getEntry(alias, null) as KeyStore.PrivateKeyEntry).privateKey)
    signature.update(Base64.getUrlDecoder().decode(payload))
    val der = signature.sign()
    // WebCrypto verifies the IEEE-P1363 (r || s) form, while Android's
    // Signature API returns ASN.1 DER.
    var offset = 2
    if (der[offset].toInt() and 0x80 != 0) offset += (der[offset].toInt() and 0x7f) + 1
    val rLength = der[offset + 1].toInt()
    val r = der.copyOfRange(offset + 2, offset + 2 + rLength)
    offset += rLength + 2
    val sLength = der[offset + 1].toInt()
    val s = der.copyOfRange(offset + 2, offset + 2 + sLength)
    fun pad(value: ByteArray) = ByteArray(32).also { out ->
      val source = if (value.size > 32) value.copyOfRange(value.size - 32, value.size) else value
      source.copyInto(out, 32 - source.size)
    }
    return b64.encode(pad(r) + pad(s)).toString()
  }
}
