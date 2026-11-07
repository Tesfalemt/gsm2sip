package com.callagent.gateway.sip

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SipMessageTest {

    private fun msg(vararg headerLines: String, body: String = ""): String =
        (headerLines.joinToString("\r\n") + "\r\n\r\n" + body)

    /** Shaped like the INVITE Telnyx sends once compact headers are on. */
    private val compactInvite = msg(
        "INVITE sip:gw@10.0.0.209:55292;transport=tls SIP/2.0",
        "v: SIP/2.0/TLS 192.76.120.10:5061;branch=z9hG4bKa1",
        "v: SIP/2.0/UDP 10.255.0.1:5060;branch=z9hG4bKb2;rport",
        "f: \"Dehay\" <sip:+15550100@sip.telnyx.com>;tag=abc",
        "t: <sip:gw@sip.telnyx.com>",
        "i: 4f2c-call@telnyx",
        "CSeq: 1 INVITE",
        "m: <sip:+15550100@192.76.120.10:5061;transport=tls>",
        "X-GSM-Forward: +15550199",
        "c: application/sdp",
        "l: 3",
        body = "v=0"
    )

    @Test
    fun compactHeadersAreReadUnderTheirFullNames() {
        val m = SipMessage.parse(compactInvite)
        assertNotNull(m)
        m!!
        assertEquals("INVITE", m.method)
        assertEquals("4f2c-call@telnyx", m.callId)
        assertEquals("abc", m.fromTag)
        assertEquals("+15550100", m.callerNumber)
        assertEquals("<sip:gw@sip.telnyx.com>", m.to)
        assertEquals("sip:+15550100@192.76.120.10:5061;transport=tls", m.contactUri)
        assertEquals("application/sdp", m.contentType)
        assertEquals("3", m.header("content-length"))
        assertEquals("+15550199", m.gsmForwardNumber)
    }

    @Test
    fun repeatedViaLinesAreKeptInOrder() {
        val m = SipMessage.parse(compactInvite)!!
        assertEquals(
            "SIP/2.0/TLS 192.76.120.10:5061;branch=z9hG4bKa1, " +
                "SIP/2.0/UDP 10.255.0.1:5060;branch=z9hG4bKb2;rport",
            m.via
        )
    }

    @Test
    fun responsesEchoEveryViaHop() {
        val m = SipMessage.parse(compactInvite)!!
        val trying = SipBuilder.trying100(m)
        assertTrue(trying.contains("branch=z9hG4bKa1"))
        assertTrue(trying.contains("branch=z9hG4bKb2"))
        assertTrue(trying.contains("Call-ID: 4f2c-call@telnyx\r\n"))
        val reject = SipBuilder.reject(m, 488, "Not Acceptable Here")
        assertTrue(reject.startsWith("SIP/2.0 488 Not Acceptable Here\r\n"))
        assertTrue(reject.contains("Call-ID: 4f2c-call@telnyx\r\n"))
    }

    @Test
    fun fullHeaderNamesStillWork() {
        val m = SipMessage.parse(
            msg(
                "SIP/2.0 200 OK",
                "Via: SIP/2.0/TLS 10.0.0.209:55292;branch=z9hG4bK1;rport=55292",
                "From: <sip:gw@10.0.0.209>;tag=gw1",
                "To: <sip:gw@sip.telnyx.com>;tag=t9",
                "Call-ID: reg-1",
                "CSeq: 2 REGISTER",
                "Content-Length: 0"
            )
        )!!
        assertEquals(200, m.statusCode)
        assertEquals("reg-1", m.callId)
        assertEquals("2 REGISTER", m.cseq)
        assertEquals("t9", m.toTag)
    }

    @Test
    fun repeatedNonListHeadersKeepTheLastValue() {
        // Two challenges are two values; joining them would hand SipAuth a
        // string that is neither.  Behaviour unchanged from before.
        val m = SipMessage.parse(
            msg(
                "SIP/2.0 401 Unauthorized",
                "Call-ID: reg-2",
                "CSeq: 1 REGISTER",
                "WWW-Authenticate: Digest realm=\"sip.telnyx.com\", nonce=\"a\", algorithm=SHA-256",
                "WWW-Authenticate: Digest realm=\"sip.telnyx.com\", nonce=\"b\", algorithm=MD5",
                "Content-Length: 0"
            )
        )!!
        assertEquals(
            "Digest realm=\"sip.telnyx.com\", nonce=\"b\", algorithm=MD5",
            m.header("www-authenticate")
        )
    }
}
