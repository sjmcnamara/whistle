package org.findmyfam.ui.common

import androidx.compose.animation.*
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import org.findmyfam.ui.groups.GroupChatScreen
import org.findmyfam.ui.groups.GroupDetailScreen
import org.findmyfam.ui.groups.GroupListScreen
import kotlinx.coroutines.launch
import org.findmyfam.viewmodels.AppViewModel
import org.findmyfam.viewmodels.AppViewModel.StartupPhase
import org.findmyfam.viewmodels.ChatViewModel
import org.findmyfam.viewmodels.GroupDetailViewModel
import org.findmyfam.viewmodels.GroupListViewModel
import org.findmyfam.ui.map.MapScreen
import org.findmyfam.ui.map.GroupOption
import org.findmyfam.ui.identity.ExportKeyScreen
import org.findmyfam.ui.identity.IdentityCardScreen
import org.findmyfam.ui.identity.ImportKeyScreen
import org.findmyfam.ui.settings.AdvancedSettingsScreen
import org.findmyfam.ui.settings.DiagnosticsScreen
import org.findmyfam.ui.settings.SettingsScreen

// Navigation route constants
object Routes {
    const val GROUP_LIST = "groups"
    const val GROUP_CHAT = "groups/{groupId}/chat"
    const val GROUP_DETAIL = "groups/{groupId}/detail"
    const val MAP = "map"
    const val SETTINGS = "settings"
    const val ADVANCED_SETTINGS = "settings/advanced"
    const val DIAGNOSTICS = "settings/diagnostics"
    const val IDENTITY_CARD = "identity/card"
    const val EXPORT_KEY = "identity/export"
    const val IMPORT_KEY = "identity/import"

    fun groupChat(groupId: String) = "groups/$groupId/chat"
    fun groupDetail(groupId: String) = "groups/$groupId/detail"
}

@Composable
fun RootScreen(
    viewModel: AppViewModel = hiltViewModel()
) {
    val phase by viewModel.startupPhase.collectAsState()

    LaunchedEffect(Unit) {
        viewModel.onAppear()
    }

    Box(modifier = Modifier.fillMaxSize()) {
        // Main content (shown when ready)
        AnimatedVisibility(
            visible = phase == StartupPhase.READY,
            enter = fadeIn(),
            exit = fadeOut()
        ) {
            MainNavigationScaffold(viewModel = viewModel)
        }

        // Splash overlay
        AnimatedVisibility(
            visible = phase != StartupPhase.READY,
            enter = fadeIn(),
            exit = fadeOut()
        ) {
            SplashScreen(phase = phase)
        }
    }
}

@Composable
private fun MainNavigationScaffold(viewModel: AppViewModel) {
    val navController = rememberNavController()
    val scope = rememberCoroutineScope()
    // Surfaced when picking a member photo fails — iOS has always alerted here
    // and Android silently dropped the result, so an oversized image simply
    // did nothing.
    var avatarError by remember { mutableStateOf<String?>(null) }
    val currentBackStack by navController.currentBackStackEntryAsState()
    val currentRoute = currentBackStack?.destination?.route

    // Only show bottom bar on top-level destinations
    val showBottomBar = currentRoute in listOf(Routes.GROUP_LIST, Routes.MAP, Routes.SETTINGS)

    avatarError?.let { message ->
        AlertDialog(
            onDismissRequest = { avatarError = null },
            title = { Text("Couldn't set your photo") },
            text = { Text(message) },
            confirmButton = { TextButton(onClick = { avatarError = null }) { Text("OK") } }
        )
    }

    Scaffold(
        bottomBar = {
            if (showBottomBar) {
                NavigationBar {
                    NavigationBarItem(
                        selected = currentRoute == Routes.GROUP_LIST,
                        onClick = {
                            navController.navigate(Routes.GROUP_LIST) {
                                popUpTo(Routes.GROUP_LIST) { inclusive = true }
                                launchSingleTop = true
                            }
                        },
                        icon = { Icon(Icons.Default.Groups, contentDescription = "Groups") },
                        label = { Text("Groups") }
                    )
                    NavigationBarItem(
                        selected = currentRoute == Routes.MAP,
                        onClick = {
                            navController.navigate(Routes.MAP) {
                                popUpTo(Routes.GROUP_LIST)
                                launchSingleTop = true
                            }
                        },
                        icon = { Icon(Icons.Default.Map, contentDescription = "Map") },
                        label = { Text("Map") }
                    )
                    NavigationBarItem(
                        selected = currentRoute == Routes.SETTINGS,
                        onClick = {
                            navController.navigate(Routes.SETTINGS) {
                                popUpTo(Routes.GROUP_LIST)
                                launchSingleTop = true
                            }
                        },
                        icon = { Icon(Icons.Default.Settings, contentDescription = "Settings") },
                        label = { Text("Settings") }
                    )
                }
            }
        }
    ) { padding ->
        NavHost(
            navController = navController,
            startDestination = Routes.GROUP_LIST,
            modifier = Modifier.padding(padding)
        ) {
            // Group list
            composable(Routes.GROUP_LIST) {
                val groupListViewModel: GroupListViewModel = hiltViewModel()

                GroupListScreen(
                    viewModel = groupListViewModel,
                    appViewModel = viewModel,
                    onGroupClick = { groupId ->
                        navController.navigate(Routes.groupChat(groupId))
                    },
                    modifier = Modifier.fillMaxSize()
                )
            }

            // Group chat
            composable(
                route = Routes.GROUP_CHAT,
                arguments = listOf(navArgument("groupId") { type = NavType.StringType })
            ) { backStackEntry ->
                val groupId = backStackEntry.arguments?.getString("groupId") ?: return@composable
                val groups by viewModel.marmot.groups.collectAsState()
                val groupName = groups.find { it.mlsGroupId == groupId }?.name?.ifEmpty { "Unnamed Group" } ?: "Chat"
                // Nothing feeds a health signal in v2 (MarmotKit reports an
                // unrecoverable group as a typed error instead), so the banner
                // stays off, as on iOS.
                val isUnhealthy = false

                val chatViewModel = remember(groupId) {
                    ChatViewModel(
                        groupId = groupId,
                        marmot = viewModel.marmot,
                        nicknameStore = viewModel.nicknameStore,
                        myPubkeyHex = viewModel.identity.publicKeyHex ?: "",
                        messageCache = viewModel.chatMessageCache,
                        notices = viewModel.notices
                    )
                }

                GroupChatScreen(
                    chatViewModel = chatViewModel,
                    groupName = groupName,
                    isUnhealthy = isUnhealthy,
                    onBack = { navController.popBackStack() },
                    onDetail = { navController.navigate(Routes.groupDetail(groupId)) },
                    modifier = Modifier.fillMaxSize()
                )
            }

            // Group detail
            composable(
                route = Routes.GROUP_DETAIL,
                arguments = listOf(navArgument("groupId") { type = NavType.StringType })
            ) { backStackEntry ->
                val groupId = backStackEntry.arguments?.getString("groupId") ?: return@composable

                val detailViewModel = remember(groupId) {
                    GroupDetailViewModel(
                        groupId = groupId,
                        marmot = viewModel.marmot,
                        nicknameStore = viewModel.nicknameStore,
                        myPubkeyHex = viewModel.identity.publicKeyHex ?: "",
                        settings = viewModel.settings,
                        notices = viewModel.notices
                    )
                }

                GroupDetailScreen(
                    viewModel = detailViewModel,
                    appViewModel = viewModel,
                    onBack = { navController.popBackStack() },
                    onLeaveComplete = {
                        navController.popBackStack(Routes.GROUP_LIST, inclusive = false)
                    },
                    modifier = Modifier.fillMaxSize()
                )
            }

            // Family map
            composable(Routes.MAP) {
                val locationViewModel = viewModel.locationViewModel

                val marmotGroups by viewModel.marmot.groups.collectAsState()
                val activeGroups = marmotGroups
                    .filter { it.isActive }
                    .map { GroupOption(id = it.mlsGroupId, name = it.name) }

                val whistleState by viewModel.whistleState.collectAsState()
                val avatarRevision by viewModel.memberAvatarStore.revision.collectAsState()
                MapScreen(
                    locationViewModel = locationViewModel,
                    groups = activeGroups,
                    onPermissionGranted = { viewModel.onLocationPermissionGranted() },
                    whistleState = whistleState,
                    onWhistle = { viewModel.whistle() },
                    // Keyed on the store's revision so pins redraw when an
                    // avatar arrives or is removed.
                    avatarFor = { pubkey ->
                        avatarRevision.let { viewModel.memberAvatarStore.image(pubkey) }
                    },
                    modifier = Modifier.fillMaxSize()
                )
            }

            // Settings
            composable(Routes.SETTINGS) {
                SettingsScreen(
                    settings = viewModel.settings,
                    identity = viewModel.identity,
                    nicknameStore = viewModel.nicknameStore,
                    memberAvatarStore = viewModel.memberAvatarStore,
                    onDisplayNameChanged = { name -> viewModel.broadcastDisplayName(name) },
                    onAvatarPicked = { uri ->
                        scope.launch {
                            if (!viewModel.setOwnAvatar(uri)) {
                                avatarError =
                                    "Your photo is sent to everyone in your groups, so it has to be small. This one couldn't be shrunk enough — try another image."
                            }
                        }
                    },
                    onAvatarRemoved = { scope.launch { viewModel.removeOwnAvatar() } },
                    onExportKey = { navController.navigate(Routes.EXPORT_KEY) },
                    onImportKey = { navController.navigate(Routes.IMPORT_KEY) },
                    onAdvanced = { navController.navigate(Routes.ADVANCED_SETTINGS) },
                    onIdentityCard = { navController.navigate(Routes.IDENTITY_CARD) },
                    modifier = Modifier.fillMaxSize()
                )
            }

            // Advanced Settings
            composable(Routes.DIAGNOSTICS) {
                DiagnosticsScreen(
                    collector = viewModel.diagnosticsCollector,
                    onBack = { navController.popBackStack() },
                    modifier = Modifier.fillMaxSize()
                )
            }

            composable(Routes.ADVANCED_SETTINGS) {
                val startupError by viewModel.startupError.collectAsState()
                val accountReady by viewModel.accountIsReady.collectAsState()
                val relayStatus by viewModel.marmot.relayStatus.collectAsState()
                AdvancedSettingsScreen(
                    settings = viewModel.settings,
                    identity = viewModel.identity,
                    relayStatus = relayStatus,
                    accountReady = accountReady,
                    startupError = startupError,
                    onRefreshRelayStatus = { viewModel.refreshRelayStatus() },
                    onReconnectRelays = { viewModel.applyRelaySettings() },
                    onFuzzSettingChanged = { viewModel.locationService.resetThrottle() },
                    onExportKey = { navController.navigate(Routes.EXPORT_KEY) },
                    onImportKey = { navController.navigate(Routes.IMPORT_KEY) },
                    onDiagnostics = { navController.navigate(Routes.DIAGNOSTICS) },
                    onPrepareBurnPlan = { viewModel.prepareBurnPlan() },
                    onExecuteBurnPlan = { plan, promotions ->
                        viewModel.executeBurnPlan(plan, promotions)
                        navController.popBackStack(Routes.GROUP_LIST, inclusive = false)
                    },
                    onBack = { navController.popBackStack() },
                    modifier = Modifier.fillMaxSize()
                )
            }

            // Identity card (QR + npub detail)
            composable(Routes.IDENTITY_CARD) {
                IdentityCardScreen(
                    identity = viewModel.identity,
                    onBack = { navController.popBackStack() },
                    modifier = Modifier.fillMaxSize()
                )
            }

            // Export key
            composable(Routes.EXPORT_KEY) {
                ExportKeyScreen(
                    identity = viewModel.identity,
                    onBack = { navController.popBackStack() },
                    modifier = Modifier.fillMaxSize()
                )
            }

            // Import key
            composable(Routes.IMPORT_KEY) {
                ImportKeyScreen(
                    currentPubkeyHex = viewModel.identity.publicKeyHex,
                    onImport = { nsec ->
                        viewModel.replaceIdentity(nsec)
                        navController.popBackStack(Routes.GROUP_LIST, inclusive = false)
                    },
                    onBack = { navController.popBackStack() },
                    modifier = Modifier.fillMaxSize()
                )
            }

        }
    }
}
