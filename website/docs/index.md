---
title: Whistle — Location sharing without surveillance
template: home.html
hide:
  - navigation
  - toc
---

<div class="w-home-wrap" markdown>

## §01 · A different shape { .w-section-title }

Whistle is built on three open primitives nobody owns. Your phone holds the
keys. The relays in between see nothing but noise. There is no Whistle account,
no Whistle server, no Whistle database with your trips in it.

<div class="w-cards" markdown>

<div class="w-card" markdown>
<div class="w-card__icon w-card__icon--nostr"><img src="assets/nostr.svg" alt="Nostr" width="44" height="44"/></div>
<div class="w-card__title">Nostr</div>
<div class="w-card__body">Identity &amp; message routing. Public-key cryptography, no
accounts, no central database.</div>
</div>

<div class="w-card" markdown>
<div class="w-card__icon w-card__icon--mls"><img src="assets/mls.png" alt="MLS" width="44" height="44"/></div>
<div class="w-card__title">MLS</div>
<div class="w-card__body">RFC 9420 — forward-secure group messaging, the same
primitive used in modern secure chat.</div>
</div>

<div class="w-card" markdown>
<div class="w-card__icon w-card__icon--marmot"><img src="assets/marmot.png" alt="Marmot" width="64" height="64"/></div>
<div class="w-card__title">Marmot</div>
<div class="w-card__body">Protocol glue. Binds Nostr identity to MLS groups in a
coherent shape.</div>
</div>

</div>

This isn't about building a better tracking app. It's about
**removing tracking as a default assumption.**

## §02 · Who it's for { .w-section-title }

<div class="w-pairs" markdown>

<div class="w-pair" markdown>
<div class="w-pair__title"><span class="w-bolt"></span> The family circle</div>
A small, trusted group — parents, kids, maybe a grandparent. See when someone
gets home safely; check if they're still at work or already on their way. Quiet
reassurance without the constant ping of a text. Nothing archived, no dossier
on your household.
</div>

<div class="w-pair" markdown>
<div class="w-pair__title"><span class="w-bolt"></span> The festival crew</div>
You and six friends arrive at a festival. Phones die, people wander, plans
dissolve. Whistle becomes a lightweight coordination layer — no endless "where
are you?" chain, no swapping numbers with everyone, no 200MB official app. The
group evaporates Monday morning with no lingering graph of who met whom.
</div>

<div class="w-pair" markdown>
<div class="w-pair__title"><span class="w-bolt"></span> The late walk home</div>
Temporary visibility while you're in a taxi or crossing an unfamiliar city.
The digital equivalent of <em>"text me when you're back"</em> — a bridge of
reassurance during a late-night walk or a solo journey, without handing your
data to a platform.
</div>

<div class="w-pair" markdown>
<div class="w-pair__title"><span class="w-bolt"></span> The school trip</div>
A class trip looks organised on paper; in reality it's a constant balancing
act — small groups splitting off, missed meeting points, the low-level stress
of "where are they now?". Whistle helps coordinate without turning the day
into a surveillance exercise. Live for as long as the trip lasts; then gone
forever.
</div>

</div>

Also useful for nights out, pre-wedding gatherings, travel companions,
conferences — anywhere you'd otherwise text "where are you?" five times.
Make a group, share it, dissolve it when you're done.

## §03 · What you get { .w-section-title }

<ul class="w-features">
  <li><strong>End-to-end encrypted location &amp; chat</strong><span>Relays carry only
ciphertext — never plaintext, never your group's membership.</span></li>
  <li><strong>No accounts</strong><span>Identity is a keypair on your phone,
held in the secure enclave. No email, no phone number, no signup.</span></li>
  <li><strong>Multiple groups</strong><span>Family, festival, walk-home circles that
don't see each other and don't share a contact list.</span></li>
  <li><strong>Movement aware</strong><span>Battery-friendly: backs off when
stationary, resumes on movement.</span></li>
  <li><strong>Low-battery alerts</strong><span>Your group gets a heads-up before
your phone dies.</span></li>
  <li><strong>iOS and Android</strong><span>Same protocol, fully interoperable. No
platform lock-in.</span></li>
  <li><strong>Pause, leave, or burn</strong><span>Stop sharing without leaving the
group, leave the group cleanly, or destroy your identity entirely.</span></li>
  <li><strong>Open source</strong><span>Auditable, forkable, no telemetry, no
analytics SDKs.</span></li>
</ul>

## §04 · Why it matters { .w-section-title }

We've quietly drifted into a world where every app wants to know who you are,
where you are, and who you're with — *all the time*.

Location sharing was sold to us as care, as safety, as an advantage. But
somewhere along the way it became infrastructure for something else entirely:
ambient surveillance as a business model. A permanent exhaust trail of
coordinates, relationships, routines, and habits — vacuumed into ad-tech
pipelines, retained indefinitely, and fed into platforms whose incentives are
fundamentally at odds with privacy.

There's a fine line between care and control, and most platforms crossed it
years ago — quietly, incrementally, "for your convenience." Temporary
reassurance became persistent tracking. Presence became telemetry. Human trust
became another dataset to capture, correlate, monetise, and never fully delete.

You're expected to create an account before you can feel safe. Expected to tie
your movements to an identity. Expected to leave the tracking switched on
indefinitely because disabling it creates friction, suspicion, or fear. The
default assumption of modern software is that every moment should be observed,
stored, and recoverable.

Whistle rejects that assumption. Whistle is a refusal.

No accounts. No identity layer. No shadow profile waiting in a database somewhere.
No "just in case" retention dressed up as safety.

Just coordination when it matters, between people who choose it — and then it disappears.

Share your location because you mean to. Stop because you're done.

Not forever. Not stored. Not watched.

Just for now.

</div>
