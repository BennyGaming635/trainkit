package com.damrob.trainkit

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import kotlin.math.abs

class MainActivity : ComponentActivity() {
    private lateinit var manager: SBrickManager
    private val permissionLauncher = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {}

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        manager = SBrickManager(applicationContext)
        requestBluetoothPermissions()
        setContent { MaterialTheme(colorScheme = lightColorScheme(primary = Color(0xff1565c0))) { TrainKitApp(manager) } }
    }

    override fun onStop() { manager.emergencyStop(); super.onStop() }

    private fun requestBluetoothPermissions() {
        val permissions = if (Build.VERSION.SDK_INT >= 31) arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        if (permissions.any { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }) permissionLauncher.launch(permissions)
    }
}

private enum class AppScreen { HOME, PROFILES, ABOUT }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TrainKitApp(manager: SBrickManager) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val repository = remember { SettingsRepository(context) }
    val profiles = remember { mutableStateMapOf<String, DeviceProfile>().apply { putAll(repository.loadProfiles()) } }
    val consists = remember { mutableStateListOf<ConsistProfile>().apply { addAll(repository.loadConsists()) } }
    var screen by remember { mutableStateOf(AppScreen.HOME) }
    var showWhatsNew by remember { mutableStateOf(!repository.hasSeenWhatsNew()) }
    var activeConsistId by remember { mutableStateOf<String?>(null) }
    var throttle by remember { mutableFloatStateOf(0f) }
    var globalLights by remember { mutableStateOf(true) }

    fun saveProfiles() = repository.saveProfiles(profiles)
    fun saveConsists() = repository.saveConsists(consists)
    fun deviceName(id: String) = profiles[id]?.name ?: manager.sessions.firstOrNull { it.id == id }?.advertisedName ?: "SBrick"
    val activeConsist = consists.firstOrNull { it.id == activeConsistId }

    fun sendThrottle(value: Float, consist: ConsistProfile?) {
        manager.sessions.filter { manager.selectedIds[it.id] == true }.forEach { session ->
            val profile = profiles[session.id] ?: DeviceProfile(session.id, session.advertisedName, session.advertisedName)
            val lights = consist?.lightsEnabledFor(session.id) ?: globalLights
            MotorPort.entries.forEach { port ->
                val config = profile.ports[port] ?: PortSettings("Motor ${port.name}")
                val direction = if (config.reversed) -1f else 1f
                val output = when (config.function) {
                    PortFunction.MOTOR -> value * config.maximumPower * direction
                    PortFunction.FORWARD_LIGHT -> if (lights && value > 0) config.maximumPower * direction else 0f
                    PortFunction.REVERSE_LIGHT -> if (lights && value < 0) config.maximumPower * direction else 0f
                    PortFunction.UNUSED -> 0f
                }
                manager.setSpeed(session, port, output)
            }
        }
    }
    fun applyThrottle(value: Float) { throttle = value; sendThrottle(value, activeConsist) }

    Scaffold(topBar = {
        TopAppBar(
            title = { Text(if (screen == AppScreen.HOME) "TrainKit" else if (screen == AppScreen.PROFILES) "Profiles" else "About") },
            navigationIcon = { if (screen != AppScreen.HOME) IconButton(onClick = { screen = AppScreen.HOME }) { Icon(Icons.Default.ArrowBack, "Back") } },
            actions = {
                if (screen == AppScreen.HOME) {
                    IconButton(onClick = { screen = AppScreen.PROFILES }) { Icon(Icons.Default.Tune, "Profiles") }
                    IconButton(onClick = { screen = AppScreen.ABOUT }) { Icon(Icons.Default.Info, "About") }
                }
            }
        )
    }) { padding ->
        when (screen) {
            AppScreen.HOME -> HomeScreen(manager, profiles, consists, activeConsistId, throttle, globalLights,
                onConnect = { found ->
                    val existing = profiles[found.id]
                    if (existing == null) { profiles[found.id] = DeviceProfile(found.id, found.name, found.name); saveProfiles() }
                    manager.connect(found, profiles[found.id])
                },
                onToggleSession = { applyThrottle(0f); activeConsistId = null; manager.toggle(it) },
                onSelectConsist = { consist -> applyThrottle(0f); activeConsistId = consist.id; manager.select(consist.memberIds.toSet()) },
                onThrottle = ::applyThrottle,
                onGlobalLights = { globalLights = it; applyThrottle(throttle) },
                onMemberLights = { id, enabled ->
                    val index = consists.indexOfFirst { it.id == activeConsistId }
                    if (index >= 0) {
                        val updated = consists[index].copy(lightsEnabled = consists[index].lightsEnabled + (id to enabled))
                        consists[index] = updated; saveConsists(); sendThrottle(throttle, updated)
                    }
                }, modifier = Modifier.padding(padding), deviceName = ::deviceName)
            AppScreen.PROFILES -> ProfilesScreen(manager, profiles, consists,
                updateProfile = { profile -> profiles[profile.id] = profile; saveProfiles(); manager.sessions.firstOrNull { it.id == profile.id }?.let { manager.setLossPolicy(it, profile.connectionLossPolicy) } },
                updateConsist = { value -> val i = consists.indexOfFirst { it.id == value.id }; if (i >= 0) consists[i] = value else consists.add(value); saveConsists() },
                deleteConsist = { consists.removeAll { item -> item.id == it }; saveConsists() },
                modifier = Modifier.padding(padding), deviceName = ::deviceName)
            AppScreen.ABOUT -> AboutScreen(
                reset = {
                    manager.emergencyStop(); manager.sessions.toList().forEach(manager::disconnect)
                    profiles.clear(); consists.clear(); repository.reset(); showWhatsNew = true; screen = AppScreen.HOME
                }, modifier = Modifier.padding(padding))
        }
    }

    if (showWhatsNew) WhatsNewDialog {
        repository.setHasSeenWhatsNew(true); showWhatsNew = false
    }
}

@Composable
private fun HomeScreen(
    manager: SBrickManager,
    profiles: Map<String, DeviceProfile>,
    consists: List<ConsistProfile>,
    activeConsistId: String?,
    throttle: Float,
    globalLights: Boolean,
    onConnect: (FoundSBrick) -> Unit,
    onToggleSession: (SBrickSession) -> Unit,
    onSelectConsist: (ConsistProfile) -> Unit,
    onThrottle: (Float) -> Unit,
    onGlobalLights: (Boolean) -> Unit,
    onMemberLights: (String, Boolean) -> Unit,
    modifier: Modifier,
    deviceName: (String) -> String,
) {
    val active = consists.firstOrNull { it.id == activeConsistId }
    LazyColumn(modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (manager.sessions.isEmpty()) {
            item {
                Button(onClick = { if (manager.scanning) manager.stopScan() else manager.startScan() }, modifier = Modifier.fillMaxWidth()) {
                    Icon(if (manager.scanning) Icons.Default.Stop else Icons.Default.BluetoothSearching, null)
                    Spacer(Modifier.width(8.dp)); Text(if (manager.scanning) "Stop scanning" else "Scan for SBricks")
                }
            }
            items(manager.devices, key = { it.id }) { found ->
                ListItem(headlineContent = { Text(found.name) }, supportingContent = { Text("Signal ${found.rssi} dBm") },
                    leadingContent = { Icon(Icons.Default.Inventory2, null) },
                    modifier = Modifier.clickable { onConnect(found) })
                HorizontalDivider()
            }
        } else {
            if (consists.isNotEmpty()) {
                item { Text("Consists", style = MaterialTheme.typography.titleMedium) }
                items(consists, key = { it.id }) { consist ->
                    ListItem(headlineContent = { Text(consist.name) }, supportingContent = { Text("Lead: ${deviceName(consist.masterId)} · ${consist.slaveIds.size} appended") },
                        leadingContent = { RadioButton(selected = activeConsistId == consist.id, onClick = { onSelectConsist(consist) }) },
                        modifier = Modifier.clickable { onSelectConsist(consist) })
                }
            }
            item { Text("Locomotives", style = MaterialTheme.typography.titleMedium) }
            items(manager.sessions, key = { it.id }) { session ->
                ListItem(headlineContent = { Text(deviceName(session.id)) }, supportingContent = { Text("${session.phase.name.lowercase().replaceFirstChar(Char::uppercase)} · ${session.id.takeLast(5)}") },
                    leadingContent = { Checkbox(manager.selectedIds[session.id] == true, onCheckedChange = { onToggleSession(session) }) },
                    trailingContent = { session.batteryVoltage?.let { Text("%.1f V".format(it)) } })
            }
            item { HorizontalDivider(); Text("Power: ${if (throttle == 0f) "Stopped" else "${(abs(throttle) * 100).toInt()}% ${if (throttle < 0) "reverse" else "forward"}"}") }
            item { Slider(value = throttle, onValueChange = onThrottle, valueRange = -1f..1f) }
            item { OutlinedButton(onClick = { onThrottle(0f) }, modifier = Modifier.fillMaxWidth()) { Icon(Icons.Default.Stop, null); Text(" Stop") } }
            if (active != null) items(active.memberIds, key = { it }) { id ->
                ListItem(headlineContent = { Text("${deviceName(id)} lights") }, trailingContent = {
                    Switch(active.lightsEnabledFor(id), onCheckedChange = { onMemberLights(id, it) })
                })
            } else item { ListItem(headlineContent = { Text("Directional lights") }, trailingContent = { Switch(globalLights, onCheckedChange = onGlobalLights) }) }
            item { Button(onClick = manager::emergencyStop, colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error), modifier = Modifier.fillMaxWidth()) { Icon(Icons.Default.Report, null); Text(" Emergency stop all") } }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ProfilesScreen(
    manager: SBrickManager,
    profiles: Map<String, DeviceProfile>,
    consists: List<ConsistProfile>,
    updateProfile: (DeviceProfile) -> Unit,
    updateConsist: (ConsistProfile) -> Unit,
    deleteConsist: (String) -> Unit,
    modifier: Modifier,
    deviceName: (String) -> String,
) {
    var expandedDevice by remember { mutableStateOf<String?>(null) }
    var expandedConsist by remember { mutableStateOf<String?>(null) }
    LazyColumn(modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item { Text("Consists", style = MaterialTheme.typography.titleMedium) }
        items(consists, key = { it.id }) { consist ->
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(consist.name, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                        IconButton(onClick = { expandedConsist = if (expandedConsist == consist.id) null else consist.id }) { Icon(Icons.Default.Edit, "Edit") }
                    }
                    if (expandedConsist == consist.id) {
                        OutlinedTextField(consist.name, { updateConsist(consist.copy(name = it)) }, label = { Text("Consist name") }, modifier = Modifier.fillMaxWidth())
                        Text("Lead locomotive", fontWeight = FontWeight.Medium)
                        manager.sessions.forEach { session ->
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                RadioButton(consist.masterId == session.id, onClick = {
                                    updateConsist(consist.copy(masterId = session.id, slaveIds = (listOf(consist.masterId) + consist.slaveIds).filter { it != session.id }.distinct()))
                                }); Text(deviceName(session.id))
                            }
                        }
                        Text("Appended locomotives", fontWeight = FontWeight.Medium)
                        manager.sessions.filter { it.id != consist.masterId }.forEach { session ->
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Checkbox(session.id in consist.slaveIds, onCheckedChange = { included ->
                                    updateConsist(consist.copy(slaveIds = if (included) (consist.slaveIds + session.id).distinct() else consist.slaveIds - session.id))
                                }); Text(deviceName(session.id))
                            }
                        }
                        Text("Lights", fontWeight = FontWeight.Medium)
                        consist.memberIds.forEach { id ->
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(deviceName(id), Modifier.weight(1f)); Switch(consist.lightsEnabledFor(id), onCheckedChange = {
                                    updateConsist(consist.copy(lightsEnabled = consist.lightsEnabled + (id to it)))
                                })
                            }
                        }
                        TextButton(onClick = { deleteConsist(consist.id) }, colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) { Text("Delete consist") }
                    }
                }
            }
        }
        if (manager.sessions.size >= 2) item {
            OutlinedButton(onClick = {
                val selected = manager.sessions.filter { manager.selectedIds[it.id] == true }.ifEmpty { manager.sessions }
                if (selected.size >= 2) updateConsist(ConsistProfile(masterId = selected.first().id, slaveIds = selected.drop(1).map { it.id }))
            }, modifier = Modifier.fillMaxWidth()) { Icon(Icons.Default.Add, null); Text(" New consist") }
        }

        item { Spacer(Modifier.height(8.dp)); Text("SBricks", style = MaterialTheme.typography.titleMedium) }
        items(manager.sessions, key = { it.id }) { session ->
            val profile = profiles[session.id] ?: DeviceProfile(session.id, session.advertisedName, session.advertisedName)
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(profile.name, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                        IconButton(onClick = { expandedDevice = if (expandedDevice == session.id) null else session.id }) { Icon(Icons.Default.Edit, "Edit") }
                    }
                    if (expandedDevice == session.id) {
                        OutlinedTextField(profile.name, { updateProfile(profile.copy(name = it)) }, label = { Text("SBrick name") }, modifier = Modifier.fillMaxWidth())
                        Text("ID ${session.id}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text("Connection loss", fontWeight = FontWeight.Medium)
                        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                            ConnectionLossPolicy.entries.forEachIndexed { index, policy ->
                                SegmentedButton(selected = profile.connectionLossPolicy == policy, onClick = { manager.emergencyStop(); updateProfile(profile.copy(connectionLossPolicy = policy)) },
                                    shape = SegmentedButtonDefaults.itemShape(index, ConnectionLossPolicy.entries.size)) { Text(if (policy == ConnectionLossPolicy.EMERGENCY_STOP) "Stop" else "Keep output") }
                            }
                        }
                        Text("Port preset", fontWeight = FontWeight.Medium)
                        PortPreset.entries.forEach { preset -> TextButton(onClick = { manager.emergencyStop(); updateProfile(profile.copy(ports = preset.ports())) }) { Text(preset.title) } }
                        MotorPort.entries.forEach { port -> PortEditor(manager, session, port, profile.ports[port] ?: PortSettings("Motor ${port.name}")) { value ->
                            updateProfile(profile.copy(ports = profile.ports + (port to value)))
                        } }
                    }
                }
            }
        }
    }
}

@Composable
private fun PortEditor(manager: SBrickManager, session: SBrickSession, port: MotorPort, settings: PortSettings, update: (PortSettings) -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        HorizontalDivider(); Text("Port ${port.name}", fontWeight = FontWeight.Medium)
        Box {
            OutlinedButton(onClick = { menu = true }) { Text(settings.function.name.lowercase().replace('_', ' ').replaceFirstChar(Char::uppercase)) }
            DropdownMenu(menu, onDismissRequest = { menu = false }) {
                PortFunction.entries.forEach { function -> DropdownMenuItem(text = { Text(function.name.lowercase().replace('_', ' ').replaceFirstChar(Char::uppercase)) }, onClick = { update(settings.copy(function = function)); menu = false }) }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) { Text("Reverse", Modifier.weight(1f)); Switch(settings.reversed, onCheckedChange = { update(settings.copy(reversed = it)) }) }
        Text("Maximum output ${(settings.maximumPower * 100).toInt()}%", style = MaterialTheme.typography.bodySmall)
        Slider(settings.maximumPower, onValueChange = { update(settings.copy(maximumPower = it)) }, valueRange = .1f..1f)
        Text("Port test", style = MaterialTheme.typography.bodySmall)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf("Reverse" to -0.25f, "Forward" to 0.25f).forEach { (label, speed) ->
                OutlinedButton(onClick = {}, modifier = Modifier.weight(1f).pointerInput(settings.reversed) {
                    detectTapGestures(onPress = {
                        manager.emergencyStop()
                        manager.setSpeed(session, port, speed * if (settings.reversed) -1f else 1f)
                        tryAwaitRelease()
                        manager.stop(session, port)
                    })
                }) { Text(label) }
            }
        }
    }
}

@Composable
private fun AboutScreen(reset: () -> Unit, modifier: Modifier) {
    var taps by remember { mutableIntStateOf(0) }
    var lastTap by remember { mutableLongStateOf(0L) }
    var confirmReset by remember { mutableStateOf(false) }
    LazyColumn(modifier.fillMaxSize(), contentPadding = PaddingValues(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item {
            Image(painterResource(R.drawable.app_icon), "TrainKit app icon", contentScale = ContentScale.Fit,
                modifier = Modifier.size(128.dp).pointerInput(Unit) { detectTapGestures {
                    val now = System.currentTimeMillis(); taps = if (now - lastTap < 700) taps + 1 else 1; lastTap = now
                    if (taps >= 3) { taps = 0; confirmReset = true }
                } })
        }
        item { Text("TrainKit", fontSize = 30.sp, fontWeight = FontWeight.Bold) }
        item { Text("Simple control for SBrick-powered trains.", textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        item { HorizontalDivider(); Text("Version 1.1 · Build 2") }
        item { Text("Acknowledgements", style = MaterialTheme.typography.titleMedium) }
        item { Text("Built with Kotlin, Jetpack Compose, Android Bluetooth APIs, Gradle, and Android Studio.") }
        item { Text("SBrick communication uses the publicly documented SBrick Bluetooth Low Energy protocol.") }
        item { Text("TrainKit is independent and is not endorsed by, owned by, affiliated with, or linked to SBrick or its owners.") }
        item { Text("Copyright © 2026 Damrob Pty Ltd.") }
    }
    if (confirmReset) AlertDialog(onDismissRequest = { confirmReset = false }, title = { Text("Reset TrainKit?") },
        text = { Text("This removes names, profiles, consists, port settings, and connection preferences, then disconnects every SBrick.") },
        confirmButton = { TextButton(onClick = { confirmReset = false; reset() }, colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) { Text("Reset") } },
        dismissButton = { TextButton(onClick = { confirmReset = false }) { Text("Cancel") } })
}

@Composable
private fun WhatsNewDialog(continueAction: () -> Unit) {
    AlertDialog(onDismissRequest = {}, confirmButton = { Button(onClick = continueAction, modifier = Modifier.fillMaxWidth()) { Text("Continue") } },
        title = { Text("What’s New in TrainKit") }, text = {
            Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
                FeatureRow(Icons.Default.Badge, "SBrick profiles", "Name each SBrick and configure every port.")
                FeatureRow(Icons.Default.Link, "Saved consists", "Choose a lead locomotive and append others.")
                FeatureRow(Icons.Default.Lightbulb, "Safer control", "Manage lights, port tests, reconnect, and emergency stop.")
            }
        })
}

@Composable
private fun FeatureRow(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, detail: String) {
    Row(verticalAlignment = Alignment.Top) { Icon(icon, null, tint = MaterialTheme.colorScheme.primary); Spacer(Modifier.width(14.dp)); Column { Text(title, fontWeight = FontWeight.SemiBold); Text(detail, color = MaterialTheme.colorScheme.onSurfaceVariant) } }
}
