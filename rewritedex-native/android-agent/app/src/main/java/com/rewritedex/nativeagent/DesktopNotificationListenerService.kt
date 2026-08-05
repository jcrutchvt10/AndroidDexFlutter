package com.rewritedex.nativeagent

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

class DesktopNotificationListenerService : NotificationListenerService() {
    override fun onNotificationPosted(notification: StatusBarNotification) {
        val item = NotificationStore.fromStatusBarNotification(notification)
        val preferences = getSharedPreferences(NotificationStore.PREFERENCES, MODE_PRIVATE)
        NotificationStore.push(preferences, item)
        DexAgentService.instance?.publishHostEvent(
            "notification-posted",
            NotificationStore.eventPayload(item),
        )
    }
}
