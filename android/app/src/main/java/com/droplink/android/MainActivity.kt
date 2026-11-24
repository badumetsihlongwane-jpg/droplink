package com.droplink.android

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import com.droplink.android.state.DropLinkManager
import com.droplink.android.ui.DropLinkHomeScaffold
import com.droplink.android.ui.DropLinkTheme
import com.droplink.android.ui.QRScannerScreen

class MainActivity : ComponentActivity() {
    private lateinit var manager: DropLinkManager

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        manager = DropLinkManager.getInstance(this)
        handleShareIntent(intent)

        setContent {
            DropLinkTheme {
                val state by manager.uiState.collectAsState()
                var showScanner by rememberSaveable { mutableStateOf(false) }

                val notifPermissionLauncher = rememberLauncherForActivityResult(
                    contract = ActivityResultContracts.RequestPermission()
                ) {}

                val legacyStoragePermissionLauncher = rememberLauncherForActivityResult(
                    contract = ActivityResultContracts.RequestPermission()
                ) {}

                LaunchedEffect(Unit) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                        ContextCompat.checkSelfPermission(this@MainActivity, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                    ) {
                        notifPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                    }
                    if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.P &&
                        ContextCompat.checkSelfPermission(this@MainActivity, Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED
                    ) {
                        legacyStoragePermissionLauncher.launch(Manifest.permission.WRITE_EXTERNAL_STORAGE)
                    }
                }

                val pickMediaLauncher = rememberLauncherForActivityResult(
                    contract = ActivityResultContracts.PickMultipleVisualMedia()
                ) { uris ->
                    if (uris.isNotEmpty()) manager.sendUris(uris)
                }

                val pickFilesLauncher = rememberLauncherForActivityResult(
                    contract = ActivityResultContracts.OpenMultipleDocuments()
                ) { uris ->
                    if (uris.isNotEmpty()) manager.sendUris(uris)
                }

                if (showScanner) {
                    QRScannerScreen(
                        onQrScanned = { qr ->
                            showScanner = false
                            manager.pairWithQrUri(qr)
                        },
                        onClose = { showScanner = false }
                    )
                } else {
                    DropLinkHomeScaffold(
                        state = state,
                        onOpenScanner = { showScanner = true },
                        onPickPhotos = {
                            pickMediaLauncher.launch(
                                PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo)
                            )
                        },
                        onPickFiles = {
                            pickFilesLauncher.launch(arrayOf("*/*"))
                        },
                        onDisconnect = { manager.disconnect() },
                        onReconnect = { manager.reconnectNow() },
                        onCancelTransfer = { manager.cancelTransfer(it) },
                        onRetryTransfer = { manager.retryTransfer(it) },
                        canRetryTransfer = { manager.canRetry(it) },
                        onClearHistory = { manager.clearFinishedHistory() },
                        onUpdateDeviceName = { manager.updateDeviceName(it) },
                        onDismissBanner = { manager.dismissBanner() }
                    )
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleShareIntent(intent)
    }

    @Suppress("DEPRECATION")
    private fun handleShareIntent(intent: Intent?) {
        if (intent == null) return
        when (intent.action) {
            Intent.ACTION_SEND -> {
                val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM)
                }
                if (uri != null) manager.sendUris(listOf(uri))
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val uris = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
                }
                if (!uris.isNullOrEmpty()) manager.sendUris(uris)
            }
        }
    }
}
