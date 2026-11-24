package com.droplink.android.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.InsertDriveFile
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.DeleteSweep
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material.icons.filled.LaptopMac
import androidx.compose.material.icons.filled.LinkOff
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.droplink.android.protocol.FileUtils
import com.droplink.android.protocol.TransferDirection
import com.droplink.android.protocol.TransferRecord
import com.droplink.android.protocol.TransferStatus
import com.droplink.android.state.ConnectionState
import com.droplink.android.state.DropLinkUiState

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DropLinkHomeScaffold(
    state: DropLinkUiState,
    onOpenScanner: () -> Unit,
    onPickPhotos: () -> Unit,
    onPickFiles: () -> Unit,
    onDisconnect: () -> Unit,
    onReconnect: () -> Unit,
    onCancelTransfer: (String) -> Unit,
    onRetryTransfer: (String) -> Unit,
    canRetryTransfer: (String) -> Boolean,
    onClearHistory: () -> Unit,
    onUpdateDeviceName: (String) -> Unit,
    onDismissBanner: () -> Unit
) {
    var selectedTab by rememberSaveable { mutableIntStateOf(0) }
    val snackbarHostState = remember { SnackbarHostState() }

    val activeCount = state.transfers.count {
        it.status == TransferStatus.PENDING ||
            it.status == TransferStatus.TRANSFERRING ||
            it.status == TransferStatus.VERIFYING
    }

    LaunchedEffect(state.statusBanner) {
        val msg = state.statusBanner
        if (!msg.isNullOrBlank()) {
            snackbarHostState.showSnackbar(msg)
            onDismissBanner()
        }
    }

    Scaffold(
        snackbarHost = { SnackbarHost(snackbarHostState) },
        topBar = {
            TopAppBar(
                title = {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(
                            text = when (selectedTab) {
                                0 -> "DropLink"
                                1 -> "Transfers"
                                else -> "Settings"
                            },
                            fontWeight = FontWeight.Bold
                        )
                    }
                },
                actions = {
                    if (selectedTab == 1 && state.transfers.any { it.status == TransferStatus.COMPLETED || it.status == TransferStatus.FAILED || it.status == TransferStatus.CANCELLED }) {
                        IconButton(onClick = onClearHistory) {
                            Icon(Icons.Default.DeleteSweep, contentDescription = "Clear History")
                        }
                    }
                }
            )
        },
        bottomBar = {
            NavigationBar {
                NavigationBarItem(
                    selected = selectedTab == 0,
                    onClick = { selectedTab = 0 },
                    icon = { Icon(Icons.Default.QrCodeScanner, contentDescription = "Connect") },
                    label = { Text("Connect") }
                )
                NavigationBarItem(
                    selected = selectedTab == 1,
                    onClick = { selectedTab = 1 },
                    icon = {
                        BadgedBox(badge = {
                            if (activeCount > 0) Badge { Text("$activeCount") }
                        }) {
                            Icon(Icons.Default.SwapVert, contentDescription = "Transfers")
                        }
                    },
                    label = { Text("Transfers") }
                )
                NavigationBarItem(
                    selected = selectedTab == 2,
                    onClick = { selectedTab = 2 },
                    icon = { Icon(Icons.Default.Settings, contentDescription = "Settings") },
                    label = { Text("Settings") }
                )
            }
        }
    ) { innerPadding ->
        Box(modifier = Modifier.fillMaxSize().padding(innerPadding)) {
            when (selectedTab) {
                0 -> ConnectTab(
                    state = state,
                    activeCount = activeCount,
                    onOpenScanner = onOpenScanner,
                    onPickPhotos = onPickPhotos,
                    onPickFiles = onPickFiles,
                    onDisconnect = onDisconnect,
                    onReconnect = onReconnect,
                    onViewTransfers = { selectedTab = 1 }
                )
                1 -> TransfersTab(
                    transfers = state.transfers,
                    onCancel = onCancelTransfer,
                    onRetry = onRetryTransfer,
                    canRetry = canRetryTransfer
                )
                else -> SettingsTab(
                    deviceName = state.deviceName,
                    onUpdateDeviceName = onUpdateDeviceName,
                    onClearHistory = onClearHistory
                )
            }
        }
    }
}

@Composable
private fun ConnectTab(
    state: DropLinkUiState,
    activeCount: Int,
    onOpenScanner: () -> Unit,
    onPickPhotos: () -> Unit,
    onPickFiles: () -> Unit,
    onDisconnect: () -> Unit,
    onReconnect: () -> Unit,
    onViewTransfers: () -> Unit
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        if (!state.wifiConnected) {
            item {
                Card(
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer),
                    shape = RoundedCornerShape(16.dp)
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        Icon(Icons.Default.WifiOff, contentDescription = null, tint = MaterialTheme.colorScheme.onErrorContainer)
                        Text(
                            "Wi-Fi is disconnected. Connect to the same Wi-Fi network as your Mac.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onErrorContainer
                        )
                    }
                }
            }
        }

        // Connection Status Hero Card
        item {
            ElevatedCard(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(24.dp)
            ) {
                Column(
                    modifier = Modifier.fillMaxWidth().padding(22.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp)
                ) {
                    when (val conn = state.connectionState) {
                        is ConnectionState.Connected -> {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(14.dp)
                            ) {
                                Box(
                                    modifier = Modifier
                                        .size(52.dp)
                                        .clip(RoundedCornerShape(16.dp))
                                        .background(Color(0xFF16A34A).copy(alpha = 0.14f)),
                                    contentAlignment = Alignment.Center
                                ) {
                                    Icon(Icons.Default.LaptopMac, contentDescription = null, tint = Color(0xFF16A34A), modifier = Modifier.size(28.dp))
                                }
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(conn.macName, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                        Icon(Icons.Default.Lock, contentDescription = null, modifier = Modifier.size(14.dp), tint = Color(0xFF16A34A))
                                        val lat = conn.latencyMs?.let { " • ${it} ms" } ?: ""
                                        Text(
                                            "Encrypted LAN • ${conn.host}$lat",
                                            style = MaterialTheme.typography.bodySmall,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant
                                        )
                                    }
                                }
                            }
                            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                                OutlinedButton(onClick = onDisconnect, modifier = Modifier.weight(1f)) {
                                    Icon(Icons.Default.LinkOff, contentDescription = null, modifier = Modifier.size(18.dp))
                                    Spacer(Modifier.width(6.dp))
                                    Text("Disconnect")
                                }
                                FilledTonalButton(onClick = onOpenScanner, modifier = Modifier.weight(1f)) {
                                    Icon(Icons.Default.QrCodeScanner, contentDescription = null, modifier = Modifier.size(18.dp))
                                    Spacer(Modifier.width(6.dp))
                                    Text("Switch Mac")
                                }
                            }
                        }

                        is ConnectionState.Connecting -> {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                                CircularProgressIndicator(modifier = Modifier.size(32.dp), strokeWidth = 3.dp)
                                Column {
                                    Text("Pairing with ${conn.targetName}…", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                                    Text("Performing ECDH P-256 + AES-256-GCM handshake", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }
                        }

                        is ConnectionState.Reconnecting -> {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                                CircularProgressIndicator(modifier = Modifier.size(32.dp), strokeWidth = 3.dp)
                                Column(modifier = Modifier.weight(1f)) {
                                    Text("Reconnecting to ${conn.macName}…", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                                    Text("Attempt ${conn.attempt} using encrypted session token", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }
                            OutlinedButton(onClick = onDisconnect, modifier = Modifier.fillMaxWidth()) {
                                Text("Cancel Reconnect")
                            }
                        }

                        is ConnectionState.Error -> {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                Icon(Icons.Default.ErrorOutline, contentDescription = null, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(28.dp))
                                Text(conn.message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.error)
                            }
                            Button(
                                onClick = onOpenScanner,
                                modifier = Modifier.fillMaxWidth().height(54.dp),
                                shape = RoundedCornerShape(16.dp)
                            ) {
                                Icon(Icons.Default.QrCodeScanner, contentDescription = null)
                                Spacer(Modifier.width(10.dp))
                                Text("Scan Mac QR Code", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                            }
                        }

                        ConnectionState.Disconnected -> {
                            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                Text("Fast, Private Local Transfer", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                                Text(
                                    "Open DropLink on your Mac and scan its QR code to send photos, videos, and files directly over Wi-Fi.",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            Button(
                                onClick = onOpenScanner,
                                modifier = Modifier.fillMaxWidth().height(56.dp),
                                shape = RoundedCornerShape(16.dp)
                            ) {
                                Icon(Icons.Default.QrCodeScanner, contentDescription = null)
                                Spacer(Modifier.width(10.dp))
                                Text("Scan Mac", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                            }
                            if (state.canManualReconnect) {
                                OutlinedButton(onClick = onReconnect, modifier = Modifier.fillMaxWidth()) {
                                    Icon(Icons.Default.Refresh, contentDescription = null, modifier = Modifier.size(18.dp))
                                    Spacer(Modifier.width(8.dp))
                                    Text("Reconnect Previous Session")
                                }
                            }
                        }
                    }
                }
            }
        }

        // Send Actions (when connected)
        if (state.connectionState is ConnectionState.Connected) {
            item {
                Text("Send to Mac", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(10.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
                    ActionTile(
                        modifier = Modifier.weight(1f),
                        icon = Icons.Default.PhotoLibrary,
                        title = "Photos & Videos",
                        subtitle = "Multi-select gallery",
                        containerColor = MaterialTheme.colorScheme.primaryContainer,
                        contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                        onClick = onPickPhotos
                    )
                    ActionTile(
                        modifier = Modifier.weight(1f),
                        icon = Icons.Default.FolderOpen,
                        title = "Files & Docs",
                        subtitle = "Any file type",
                        containerColor = MaterialTheme.colorScheme.secondaryContainer,
                        contentColor = MaterialTheme.colorScheme.onSecondaryContainer,
                        onClick = onPickFiles
                    )
                }
            }
        }

        // Active transfer summary pill
        if (activeCount > 0) {
            item {
                Card(
                    onClick = onViewTransfers,
                    shape = RoundedCornerShape(18.dp),
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.6f))
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Column {
                            Text("$activeCount active transfer${if (activeCount == 1) "" else "s"}", fontWeight = FontWeight.SemiBold)
                            val speed = state.transfers.filter { it.status == TransferStatus.TRANSFERRING }.sumOf { it.bytesPerSecond }
                            Text(FileUtils.formatSpeed(speed), style = MaterialTheme.typography.bodySmall)
                        }
                        Text("View Queue →", fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.primary)
                    }
                }
            }
        }

        // Security Guarantee Footer Card
        item {
            Surface(
                shape = RoundedCornerShape(18.dp),
                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(16.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(Icons.Default.Lock, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                    Column {
                        Text("Direct Wi-Fi • End-to-End Encrypted", style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold)
                        Text(
                            "Zero cloud storage, no accounts, streaming SHA-256 verified transfers.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ActionTile(
    modifier: Modifier,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    subtitle: String,
    containerColor: Color,
    contentColor: Color,
    onClick: () -> Unit
) {
    Card(
        onClick = onClick,
        modifier = modifier,
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(containerColor = containerColor)
    ) {
        Column(
            modifier = Modifier.padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Icon(icon, contentDescription = null, tint = contentColor, modifier = Modifier.size(30.dp))
            Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold, color = contentColor)
            Text(subtitle, style = MaterialTheme.typography.bodySmall, color = contentColor.copy(alpha = 0.8f))
        }
    }
}

@Composable
private fun TransfersTab(
    transfers: List<TransferRecord>,
    onCancel: (String) -> Unit,
    onRetry: (String) -> Unit,
    canRetry: (String) -> Boolean
) {
    var filter by rememberSaveable { mutableIntStateOf(0) } // 0=All, 1=Sending, 2=Receiving
    val filtered = remember(transfers, filter) {
        when (filter) {
            1 -> transfers.filter { it.direction == TransferDirection.OUTGOING }
            2 -> transfers.filter { it.direction == TransferDirection.INCOMING }
            else -> transfers
        }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            FilterChip(selected = filter == 0, onClick = { filter = 0 }, label = { Text("All") })
            FilterChip(selected = filter == 1, onClick = { filter = 1 }, label = { Text("Outgoing") })
            FilterChip(selected = filter == 2, onClick = { filter = 2 }, label = { Text("Incoming") })
        }

        if (filtered.isEmpty()) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(Icons.Default.SwapVert, contentDescription = null, modifier = Modifier.size(48.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f))
                    Text("No transfers yet", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text("Incoming files are saved to Downloads/DropLink", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        } else {
            LazyColumn(
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                items(filtered, key = { it.id }) { item ->
                    TransferItemCard(
                        record = item,
                        onCancel = { onCancel(item.id) },
                        onRetry = { onRetry(item.id) },
                        showRetry = item.status == TransferStatus.FAILED && canRetry(item.id)
                    )
                }
            }
        }
    }
}

@Composable
private fun TransferItemCard(
    record: TransferRecord,
    onCancel: () -> Unit,
    onRetry: () -> Unit,
    showRetry: Boolean
) {
    val context = LocalContext.current
    val isIncoming = record.direction == TransferDirection.INCOMING

    ElevatedCard(
        shape = RoundedCornerShape(18.dp),
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(
                    modifier = Modifier
                        .size(42.dp)
                        .clip(CircleShape)
                        .background(
                            if (isIncoming) MaterialTheme.colorScheme.primaryContainer
                            else MaterialTheme.colorScheme.secondaryContainer
                        ),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        if (isIncoming) Icons.Default.ArrowDownward else Icons.Default.ArrowUpward,
                        contentDescription = null,
                        tint = if (isIncoming) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onSecondaryContainer
                    )
                }

                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = record.savedFilename ?: record.filename,
                        style = MaterialTheme.typography.bodyLarge,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    val subtitle = buildString {
                        append("${FileUtils.formatBytes(record.transferredBytes)} / ${FileUtils.formatBytes(record.totalBytes)}")
                        if (record.status == TransferStatus.TRANSFERRING && record.bytesPerSecond > 0) {
                            append(" • ${FileUtils.formatSpeed(record.bytesPerSecond)}")
                        }
                        if (record.resumedFromBytes > 0) {
                            append(" • Resumed")
                        }
                    }
                    Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }

                when (record.status) {
                    TransferStatus.PENDING, TransferStatus.TRANSFERRING -> {
                        IconButton(onClick = onCancel) {
                            Icon(Icons.Default.Close, contentDescription = "Cancel")
                        }
                    }
                    TransferStatus.COMPLETED -> {
                        if (isIncoming && !record.savedUriString.isNullOrBlank()) {
                            TextButton(onClick = {
                                runCatching {
                                    val intent = Intent(Intent.ACTION_VIEW).apply {
                                        setDataAndType(Uri.parse(record.savedUriString), "*/*")
                                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    }
                                    context.startActivity(Intent.createChooser(intent, "Open file"))
                                }
                            }) {
                                Text("Open")
                            }
                        } else {
                            Icon(Icons.Default.CheckCircle, contentDescription = "Verified", tint = Color(0xFF16A34A))
                        }
                    }
                    TransferStatus.FAILED -> {
                        if (showRetry) {
                            TextButton(onClick = onRetry) { Text("Resume") }
                        } else {
                            Icon(Icons.Default.ErrorOutline, contentDescription = "Failed", tint = MaterialTheme.colorScheme.error)
                        }
                    }
                    else -> {
                        Icon(Icons.AutoMirrored.Filled.InsertDriveFile, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }

            if (record.status == TransferStatus.TRANSFERRING || record.status == TransferStatus.VERIFYING || record.status == TransferStatus.PENDING) {
                LinearProgressIndicator(
                    progress = { record.progress },
                    modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(4.dp))
                )
            }

            if (record.status == TransferStatus.COMPLETED && record.verified) {
                Text(
                    "SHA-256 integrity verified",
                    style = MaterialTheme.typography.labelSmall,
                    color = Color(0xFF16A34A)
                )
            } else if (!record.errorMessage.isNullOrBlank()) {
                Text(
                    record.errorMessage,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.error
                )
            }
        }
    }
}

@Composable
private fun SettingsTab(
    deviceName: String,
    onUpdateDeviceName: (String) -> Unit,
    onClearHistory: () -> Unit
) {
    var editedName by remember(deviceName) { mutableStateOf(deviceName) }

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        item {
            ElevatedCard(shape = RoundedCornerShape(20.dp), modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("Device Identity", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                    OutlinedTextField(
                        value = editedName,
                        onValueChange = { editedName = it },
                        label = { Text("Display Name on Mac") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                    Button(
                        onClick = { onUpdateDeviceName(editedName) },
                        enabled = editedName.trim().isNotEmpty() && editedName.trim() != deviceName
                    ) {
                        Text("Save Name")
                    }
                }
            }
        }

        item {
            ElevatedCard(shape = RoundedCornerShape(20.dp), modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("Storage & Security", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                    Text("Received Files Location", style = MaterialTheme.typography.labelLarge)
                    Text("Downloads/DropLink (via Android MediaStore)", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    HorizontalDivider()
                    Text("Protocol & Encryption", style = MaterialTheme.typography.labelLarge)
                    Text("DLSP/1 • Direct Local TCP • ECDH P-256 + 256-bit QR PSK + AES-256-GCM • SHA-256 Verified", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    HorizontalDivider()
                    OutlinedButton(onClick = onClearHistory) {
                        Text("Clear Transfer History")
                    }
                }
            }
        }

        item {
            Text(
                "DropLink for Android v1.0.0",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 4.dp)
            )
        }
    }
}
