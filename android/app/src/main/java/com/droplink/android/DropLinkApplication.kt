package com.droplink.android

import android.app.Application
import com.droplink.android.state.DropLinkManager

class DropLinkApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        DropLinkManager.getInstance(this)
    }
}
