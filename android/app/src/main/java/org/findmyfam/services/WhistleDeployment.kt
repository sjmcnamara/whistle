package org.findmyfam.services

import dev.ipf.marmotkit.MarmotDeploymentFfi
import dev.ipf.marmotkit.marmotDeploymentWhiteNoise

/**
 * The MarmotKit deployment record Whistle passes to every `Marmot` constructor.
 *
 * Required since MarmotKit 0.14.0, with no default: it carries the services
 * that earlier releases compiled in for White Noise — recovery relays,
 * discovery indexers, media and image servers, and the platform keystore
 * service under which account secrets are stored.
 *
 * **Everything except the keystore service is still White Noise's preset.**
 * That is what 0.11.0 compiled in and what has been tested, so the upgrade
 * stays one variable. Moving Whistle onto its own services is a separate,
 * reversible change (relays and servers can change in any release).
 *
 * **The keystore service is not reversible, so it is Whistle's own from the
 * first public release.** It is the name every user's secret key is stored
 * under; a later release that used a different name could not find existing
 * keys, and those accounts would be gone. Do not change [KEYSTORE_SERVICE]
 * without a migration. Anything that constructs a `Marmot` (the app, the relay
 * policy probe, any background process) must pass this same record.
 */
object WhistleDeployment {
    const val KEYSTORE_SERVICE = "org.getwhistle.whistle.marmotkit"

    fun create(): MarmotDeploymentFfi =
        marmotDeploymentWhiteNoise().copy(keychainService = KEYSTORE_SERVICE)
}
