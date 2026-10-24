package ai.futurepath.pairdesk

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PushRegistrationConfigTest {
    @Test fun tokenRefreshRequiresAnAuthenticatedInstallation() {
        assertNull(PushRegistrationConfig.from("https://api.example.test", null, "device-1"))
        assertNull(PushRegistrationConfig.from("https://api.example.test", "session", null))
        assertNull(PushRegistrationConfig.from(" ", "session", "device-1"))
    }

    @Test fun tokenRefreshUsesTheSavedServerSessionAndStableDeviceId() {
        assertEquals(
            PushRegistrationConfig("https://api.example.test", "session", "device-1"),
            PushRegistrationConfig.from(" https://api.example.test/ ", " session ", " device-1 "),
        )
    }
}
