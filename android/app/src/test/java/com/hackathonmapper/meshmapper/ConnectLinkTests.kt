package com.hackathonmapper.meshmapper

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The dashboard's QR link, as MeshModel.applyConnectLink reads it. */
class ConnectLinkTests {
    @Test
    fun encodedTunnelLink() {
        val parsed = ConnectLink.parse("meshmapper://gateway?url=https%3A%2F%2Fabc-def.trycloudflare.com&token=s3cr%2Bet")
        assertEquals(ConnectLink.Parsed("https://abc-def.trycloudflare.com", "s3cr+et"), parsed)
    }

    @Test
    fun unencodedLanLinkWithoutToken() {
        val parsed = ConnectLink.parse("MeshMapper://Gateway?url=http://192.168.1.20:3000")
        assertEquals(ConnectLink.Parsed("http://192.168.1.20:3000", ""), parsed)
    }

    @Test
    fun plusStaysAPlusAndUrlIsTrimmed() {
        val parsed = ConnectLink.parse("meshmapper://gateway?url=%20http%3A%2F%2Flaptop.local%3A3000%20&token=a+b")
        assertEquals(ConnectLink.Parsed("http://laptop.local:3000", "a+b"), parsed)
    }

    @Test
    fun rejectsOtherLinks() {
        assertNull(ConnectLink.parse("https://gateway?url=http://192.168.1.20:3000"))
        assertNull(ConnectLink.parse("meshmapper://settings?url=http://192.168.1.20:3000"))
        assertNull(ConnectLink.parse("meshmapper://gateway?url=ftp://192.168.1.20"))
        assertNull(ConnectLink.parse("meshmapper://gateway?url=192.168.1.20:3000"))
        assertNull(ConnectLink.parse("meshmapper://gateway?token=abc"))
        assertNull(ConnectLink.parse("not a link"))
    }

    @Test
    fun hostOfTunnelUrl() {
        assertEquals("abc.trycloudflare.com", ConnectLink.host("https://abc.trycloudflare.com"))
        assertNull(ConnectLink.host("::"))
    }
}
