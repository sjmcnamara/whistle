package org.findmyfam.di

import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent

/**
 * Hilt module for app-wide singletons.
 * IdentityService, RelayService, and MLSService are @Singleton with @Inject constructors,
 * so Hilt provides them automatically. This module is reserved for bindings that
 * need explicit @Provides methods (e.g. external library instances).
 */
@Module
@InstallIn(SingletonComponent::class)
object AppModule
