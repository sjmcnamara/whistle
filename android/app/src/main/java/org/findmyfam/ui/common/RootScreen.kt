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
import org.findmyfam.viewmodels.AppViewModel
import org.findmyfam.viewmodels.AppViewModel.StartupPhase
import org.findmyfam.viewmodels.ChatViewModel
import org.findmyfam.viewmodels.GroupDetailViewModel
import org.findmyfam.viewmodels.GroupListViewModel
import org.findmyfam.viewmodels.LocationViewModel
import org.findmyfam.ui.map.FamilyMapScreen
import org.findmyfam.ui.map.GroupOption
import org.findmyfam.ui.identity.ExportKeyScreen
import org.findmyfam.ui.identity.ImportKeyScreen
import org.findmyfam.ui.settings.SettingsScreen

// Navigation route constants
object Routes {
    const val GROUP_LIST = "groups"
    const val GROUP_CHAT = "groups/{groupId}/chat"
    const val GROUP_DETAIL = "groups/{groupId}/detail"
    const val MAP = "map"
    const val SETTINGS = "settings"
    const val QR_SCANNER = "qr_scanner"
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
    val currentBackStack by navController.currentBackStackEntryAsState()
    val currentRoute = currentBackStack?.destination?.route

    // Only show bottom bar on top-level destinations
    val showBottomBar = currentRoute in listOf(Routes.GROUP_LIST, Routes.MAP, Routes.SETTINGS)

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
                    onGroupClick = { groupId ->
                        navController.navigate(Routes.groupChat(groupId))
                    },
                    onScanQr = {
                        navController.navigate(Routes.QR_SCANNER)
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
                val groups by viewModel.marmotService.groups.collectAsState()
                val groupName = groups.find { it.mlsGroupId == groupId }?.name?.ifEmpty { "Unnamed Group" } ?: "Chat"
                val unhealthyGroupIds by viewModel.healthTracker.unhealthyGroupIds.collectAsState()
                val isUnhealthy = groupId in unhealthyGroupIds

                val chatViewModel = remember(groupId) {
                    ChatViewModel(
                        groupId = groupId,
                        marmot = viewModel.marmotService,
                        mls = viewModel.mls,
                        nicknameStore = viewModel.nicknameStore,
                        myPubkeyHex = viewModel.identity.publicKeyHex ?: ""
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
                        marmot = viewModel.marmotService,
                        mls = viewModel.mls,
                        nicknameStore = viewModel.nicknameStore,
                        myPubkeyHex = viewModel.identity.publicKeyHex ?: "",
                        pendingLeaveStore = viewModel.pendingLeaveStore
                    )
                }

                GroupDetailScreen(
                    viewModel = detailViewModel,
                    onBack = { navController.popBackStack() },
                    onLeaveComplete = {
                        navController.popBackStack(Routes.GROUP_LIST, inclusive = false)
                    },
                    modifier = Modifier.fillMaxSize()
                )
            }

            // Family map
            composable(Routes.MAP) {
                val locationViewModel = remember {
                    LocationViewModel(
                        locationCache = viewModel.locationCache,
                        nicknameStore = viewModel.nicknameStore,
                        intervalSeconds = { viewModel.settings.locationIntervalSeconds },
                        myPubkeyHex = { viewModel.identity.publicKeyHex }
                    )
                }

                val marmotGroups by viewModel.marmotService.groups.collectAsState()
                val activeGroups = marmotGroups.filter { it.state == "active" }.map {
                    GroupOption(id = it.mlsGroupId, name = it.name)
                }

                FamilyMapScreen(
                    locationViewModel = locationViewModel,
                    groups = activeGroups,
                    onPermissionGranted = { viewModel.onLocationPermissionGranted() },
                    modifier = Modifier.fillMaxSize()
                )
            }

            // Settings
            composable(Routes.SETTINGS) {
                SettingsScreen(
                    settings = viewModel.settings,
                    identity = viewModel.identity,
                    nicknameStore = viewModel.nicknameStore,
                    onDisplayNameChanged = { name -> viewModel.broadcastDisplayName(name) },
                    onExportKey = { navController.navigate(Routes.EXPORT_KEY) },
                    onImportKey = { navController.navigate(Routes.IMPORT_KEY) },
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

            // QR scanner (navigated from Join Group)
            composable(Routes.QR_SCANNER) {
                val groupListViewModel: GroupListViewModel = hiltViewModel()
                QrScannerScreen(
                    onScanned = { code ->
                        navController.popBackStack()
                        groupListViewModel.joinGroup(code)
                    },
                    onBack = { navController.popBackStack() },
                    modifier = Modifier.fillMaxSize()
                )
            }
        }
    }
}
