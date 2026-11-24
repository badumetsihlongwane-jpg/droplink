package com.droplink.android.state

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.Uri
import android.os.Build
import com.droplink.android.protocol.ConnectSessionInfo
import com.droplink.android.protocol.DropLinkPeerClient
import com.droplink.android.protocol.HandshakeRejectedException
import com.droplink.android.protocol.PairingPayload
import com.droplink.android.protocol.PeerClientListener
import com.droplink.android.protocol.TransferRecord
import com.droplink.android.protocol.TransferStatus
import com.droplink.android.service.TransferForegroundService
import com.droplink.android.storage.AndroidMediaStoreCommitter
import com.droplink.android.storage.ContentUriFileSource
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

sealed class ConnectionState {
    data object Disconnected : ConnectionState()
    data class Connecting(val targetName: String) : ConnectionState()
    data class Connected(val macName: String, val host: String, val port: Int, val latencyMs: Int? = null) : ConnectionState()
    data class Reconnecting(val macName: String, val attempt: Int) : ConnectionState()
    data class Error(val message: String) : ConnectionState()
}

data class DropLinkUiState(
    val connectionState: ConnectionState = ConnectionState.Disconnected,
    val transfers: List<TransferRecord> = emptyList(),
    val deviceName: String = Build.MODEL ?: "Android",
    val wifiConnected: Boolean = true,
    val statusBanner: String? = null,
    val canManualReconnect: Boolean = false
)

private data class SavedSession(
    val hosts: List<String>,
    val port: Int,
    val sessionId: String,
    val macName: String,
    val reconnectToken: String,
    val reconnectKey: ByteArray
)

class DropLinkManager private constructor(private val context: Context) {
    private val prefs = context.getSharedPreferences("droplink_prefs", Context.MODE_PRIVATE)
    private val gson = Gson()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val deviceId: String = prefs.getString("device_id", null) ?: UUID.randomUUID().toString().also {
        prefs.edit().putString("device_id", it).apply()
    }

    private val _uiState = MutableStateFlow(
        DropLinkUiState(
            transfers = loadHistory(),
            deviceName = prefs.getString("device_name", null) ?: defaultDeviceName()
        )
    )
    val uiState: StateFlow<DropLinkUiState> = _uiState.asStateFlow()

    @Volatile private var activeClient: DropLinkPeerClient? = null
    @Volatile private var lastSession: SavedSession? = null
    @Volatile private var userInitiatedDisconnect = false
    private var reconnectJob: Job? = null

    // Keep source URIs by transferId for seamless one-tap retry/resume within the session
    private val retrySources = ConcurrentHashMap<String, Uri>()

    init {
        registerNetworkCallback()
    }

    private fun defaultDeviceName(): String {
        val manufacturer = Build.MANUFACTURER?.replaceFirstChar { it.uppercase() } ?: ""
        val model = Build.MODEL ?: "Android"
        return if (model.startsWith(manufacturer, ignoreCase = true)) model else "$manufacturer $model".trim()
    }

    fun updateDeviceName(newName: String) {
        val cleaned = newName.trim().ifEmpty { defaultDeviceName() }
        prefs.edit().putString("device_name", cleaned).apply()
        _uiState.update { it.copy(deviceName = cleaned) }
    }

    fun pairWithQrUri(uriString: String) {
        val payload = PairingPayload.parse(uriString)
        if (payload == null) {
            _uiState.update { it.copy(connectionState = ConnectionState.Error("Invalid DropLink QR code")) }
            return
        }
        val nowSec = System.currentTimeMillis() / 1000L
        if (nowSec > payload.expiresAt) {
            _uiState.update { it.copy(connectionState = ConnectionState.Error("QR code expired — tap Refresh QR on your Mac")) }
            return
        }

        reconnectJob?.cancel()
        userInitiatedDisconnect = false
        disconnectInternal(notifyPeer = true)

        _uiState.update { it.copy(connectionState = ConnectionState.Connecting(payload.deviceName), statusBanner = null) }
        TransferForegroundService.start(context)

        scope.launch {
            try {
                val info = DropLinkPeerClient.connect(
                    hosts = payload.hosts,
                    port = payload.port,
                    sessionId = payload.sessionId,
                    authKey = payload.pairingSecret,
                    mode = "pair",
                    deviceId = deviceId,
                    deviceName = _uiState.value.deviceName,
                    stagingDir = File(context.cacheDir, "droplink_staging"),
                    committer = AndroidMediaStoreCommitter(context)
                )
                onSessionConnected(info, payload.hosts, payload.port, payload.sessionId)
            } catch (e: HandshakeRejectedException) {
                TransferForegroundService.stop(context)
                _uiState.update { it.copy(connectionState = ConnectionState.Error(e.message ?: "Pairing rejected")) }
            } catch (e: Exception) {
                TransferForegroundService.stop(context)
                _uiState.update {
                    it.copy(
                        connectionState = ConnectionState.Error(
                            "Could not connect to ${payload.deviceName}. Check both devices are on the same Wi-Fi.\n(${e.message})"
                        )
                    )
                }
            }
        }
    }

    fun reconnectNow() {
        val saved = lastSession ?: return
        userInitiatedDisconnect = false
        reconnectJob?.cancel()
        attemptReconnect(saved, maxAttempts = 4)
    }

    fun disconnect() {
        userInitiatedDisconnect = true
        reconnectJob?.cancel()
        lastSession = null
        disconnectInternal(notifyPeer = true)
        TransferForegroundService.stop(context)
        _uiState.update {
            it.copy(
                connectionState = ConnectionState.Disconnected,
                canManualReconnect = false,
                statusBanner = "Disconnected from Mac"
            )
        }
    }

    fun sendUris(uris: List<Uri>) {
        val client = activeClient
        if (client == null) {
            _uiState.update { it.copy(statusBanner = "Connect to your Mac first before sending files") }
            return
        }
        scope.launch {
            for (uri in uris) {
                runCatching {
                    val source = ContentUriFileSource(context, uri)
                    val id = UUID.randomUUID().toString().lowercase()
                    retrySources[id] = uri
                    client.sendFile(source, transferId = id)
                }.onFailure { err ->
                    _uiState.update { it.copy(statusBanner = "Skipped unreadable file: ${err.message}") }
                }
            }
        }
    }

    fun retryTransfer(transferId: String) {
        val client = activeClient ?: return
        val uri = retrySources[transferId] ?: return
        scope.launch {
            runCatching {
                val source = ContentUriFileSource(context, uri)
                client.sendFile(source, transferId = transferId)
            }
        }
    }

    fun canRetry(transferId: String): Boolean = retrySources.containsKey(transferId) && activeClient != null

    fun cancelTransfer(transferId: String) {
        activeClient?.cancelTransfer(transferId)
    }

    fun clearFinishedHistory() {
        _uiState.update { state ->
            val kept = state.transfers.filter {
                it.status == TransferStatus.PENDING ||
                    it.status == TransferStatus.TRANSFERRING ||
                    it.status == TransferStatus.VERIFYING
            }
            saveHistory(kept)
            state.copy(transfers = kept)
        }
    }

    fun dismissBanner() {
        _uiState.update { it.copy(statusBanner = null) }
    }

    private fun onSessionConnected(info: ConnectSessionInfo, hosts: List<String>, port: Int, sessionId: String) {
        activeClient = info.client
        lastSession = SavedSession(
            hosts = listOf(info.connectedHost) + hosts.filter { it != info.connectedHost },
            port = port,
            sessionId = sessionId,
            macName = info.serverName,
            reconnectToken = info.reconnectToken,
            reconnectKey = info.reconnectKey
        )

        info.client.listener = object : PeerClientListener {
            override fun onTransferUpdated(record: TransferRecord) {
                _uiState.update { state ->
                    val list = state.transfers.toMutableList()
                    val idx = list.indexOfFirst { it.id == record.id }
                    if (idx >= 0) {
                        list[idx] = record
                    } else {
                        list.add(0, record)
                    }
                    if (record.status == TransferStatus.COMPLETED || record.status == TransferStatus.FAILED || record.status == TransferStatus.CANCELLED) {
                        saveHistory(list)
                    }
                    state.copy(transfers = list)
                }
            }

            override fun onLatencyUpdated(latencyMs: Int) {
                _uiState.update { state ->
                    val curr = state.connectionState
                    if (curr is ConnectionState.Connected) {
                        state.copy(connectionState = curr.copy(latencyMs = latencyMs))
                    } else state
                }
            }

            override fun onDisconnected(reason: String?) {
                if (activeClient !== info.client) return
                activeClient = null
                val saved = lastSession
                val hostStopped = reason?.contains("Session stopped", ignoreCase = true) == true ||
                    reason?.contains("Disconnected by host", ignoreCase = true) == true
                if (!userInitiatedDisconnect && !hostStopped && saved != null) {
                    attemptReconnect(saved, maxAttempts = 5)
                } else {
                    TransferForegroundService.stop(context)
                    _uiState.update {
                        it.copy(
                            connectionState = ConnectionState.Disconnected,
                            canManualReconnect = saved != null && !hostStopped,
                            statusBanner = reason ?: "Disconnected"
                        )
                    }
                }
            }
        }

        info.client.start()
        _uiState.update {
            it.copy(
                connectionState = ConnectionState.Connected(info.serverName, info.connectedHost, port),
                canManualReconnect = false,
                statusBanner = "Connected to ${info.serverName}"
            )
        }
    }

    private fun attemptReconnect(saved: SavedSession, maxAttempts: Int) {
        reconnectJob?.cancel()
        reconnectJob = scope.launch {
            var backoffMs = 1500L
            for (attempt in 1..maxAttempts) {
                if (userInitiatedDisconnect) return@launch
                _uiState.update { it.copy(connectionState = ConnectionState.Reconnecting(saved.macName, attempt)) }
                try {
                    val info = DropLinkPeerClient.connect(
                        hosts = saved.hosts,
                        port = saved.port,
                        sessionId = saved.sessionId,
                        authKey = saved.reconnectKey,
                        mode = "reconnect",
                        reconnectToken = saved.reconnectToken,
                        deviceId = deviceId,
                        deviceName = _uiState.value.deviceName,
                        stagingDir = File(context.cacheDir, "droplink_staging"),
                        committer = AndroidMediaStoreCommitter(context)
                    )
                    onSessionConnected(info, saved.hosts, saved.port, saved.sessionId)
                    return@launch
                } catch (e: HandshakeRejectedException) {
                    // Session ended or revoked on Mac — stop retrying
                    lastSession = null
                    TransferForegroundService.stop(context)
                    _uiState.update {
                        it.copy(
                            connectionState = ConnectionState.Error("Mac session ended — scan a new QR code"),
                            canManualReconnect = false
                        )
                    }
                    return@launch
                } catch (_: Exception) {
                    delay(backoffMs)
                    backoffMs = (backoffMs * 2).coerceAtMost(8000L)
                }
            }
            TransferForegroundService.stop(context)
            _uiState.update {
                it.copy(
                    connectionState = ConnectionState.Disconnected,
                    canManualReconnect = true,
                    statusBanner = "Connection lost — tap Reconnect or scan QR again"
                )
            }
        }
    }

    private fun disconnectInternal(notifyPeer: Boolean) {
        val current = activeClient
        activeClient = null
        current?.close(reason = "Disconnected by user", notifyPeer = notifyPeer)
    }

    private fun registerNetworkCallback() {
        runCatching {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val req = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .build()
            cm.registerNetworkCallback(req, object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    _uiState.update { it.copy(wifiConnected = true) }
                    val saved = lastSession
                    if (activeClient == null && saved != null && !userInitiatedDisconnect &&
                        _uiState.value.connectionState !is ConnectionState.Reconnecting
                    ) {
                        attemptReconnect(saved, maxAttempts = 3)
                    }
                }

                override fun onLost(network: Network) {
                    _uiState.update { it.copy(wifiConnected = false) }
                }
            })
        }
    }

    private fun saveHistory(records: List<TransferRecord>) {
        runCatching {
            val trimmed = records.take(60)
            prefs.edit().putString("transfer_history", gson.toJson(trimmed)).apply()
        }
    }

    private fun loadHistory(): List<TransferRecord> {
        return runCatching {
            val raw = prefs.getString("transfer_history", null) ?: return emptyList()
            val type = object : TypeToken<List<TransferRecord>>() {}.type
            val loaded: List<TransferRecord> = gson.fromJson(raw, type) ?: emptyList()
            // Any stale in-progress items from a previous app kill should display as interrupted
            loaded.map {
                if (it.status == TransferStatus.PENDING || it.status == TransferStatus.TRANSFERRING || it.status == TransferStatus.VERIFYING) {
                    it.copy(status = TransferStatus.FAILED, errorMessage = "Interrupted before completion", bytesPerSecond = 0.0)
                } else it
            }
        }.getOrDefault(emptyList())
    }

    companion object {
        @Volatile private var instance: DropLinkManager? = null
        fun getInstance(context: Context): DropLinkManager {
            return instance ?: synchronized(this) {
                instance ?: DropLinkManager(context.applicationContext).also { instance = it }
            }
        }
    }
}
