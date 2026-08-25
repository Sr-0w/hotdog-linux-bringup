# OxygenOS modem stack architecture - 2026-08-24

## Scope

This is the implementation contract for reconstructing the complete Hotdog
telephony stack on mainline Linux. It covers modem storage and transport,
dual-SIM UIM, PIN and PUK security, PDC/MCFG selection, radio registration,
packet data, SMS, circuit-switched voice, IMS/VoLTE, recovery after subsystem
restart, service supervision and the Plasma-facing D-Bus surface.

The reference is the European OxygenOS 10.0.13 HD1913 vendor image. Proprietary
executables are behavioral evidence only. The mainline implementation uses
upstream kernel interfaces and libqmi/ModemManager rather than loading Android
binaries.

Run the reproducible inventory without embedding the host path in its output:

```sh
scripts/inventory-oxygenos-modem-stack.py /private/oxygenos/vendor \
  --output /private/evidence/hotdog-oos10-modem-stack.json
```

The current source produced 19 binary components, 20 init service or property
actions, 18 radio/data/IMS VINTF entries and the following dynamic-symbol
coverage:

| Family | Matching symbols |
| --- | ---: |
| UIM/SIM/PBM/GSTK | 1294 |
| NAS/DMS/RFRPE/SAR | 920 |
| IMS/IMSA/IMSS/RCS | 895 |
| WDS/data/rmnet/DPM/IPA | 737 |
| Voice/calls | 696 |
| PDC/MBN/MCFG | 544 |
| WMS/SMS | 250 |
| SSR/restart/recovery | 46 |

## Stock service graph

### Storage and transport

1. `rmt_storage` serves modem EFS through the modemst/fsg partitions.
2. QRTR exposes QMI services from MPSS.
3. `libqmiservices.so` supplies the generated Qualcomm service schemas.
4. `qcrild`, `netmgrd`, DPM and IMS daemons allocate independent QMI clients.

`rmt_storage` is not optional state. PDC selections, NV radio configuration,
SMS storage and provisioning survive subsystem restart through this layer.

### Radio orchestration

OxygenOS declares three qcrild commands: the primary instance and `-c 2`/`-c
3` secondary instances. The HD1913 VINTF surface exposes two IMS radio
instances. `libril-qc-qmi-1.so` owns the large state machines while
`libril-qc-hal-qmi.so` and `libqcrilFramework.so` bridge Android HAL requests,
indications and asynchronous completion.

The primary boot sequence is:

1. wait for QMI services and bind each client to its subscription;
2. discover physical UIM slots and applications;
3. create provisioning sessions and cache ICCID/MCC/MNC per subscription;
4. load the MBN database and select software MCFG by long IIN, IIN, then
   MCC/MNC fallback;
5. count pending configurations across every APSS subscription;
6. activate each pending subscription and complete modem-switch recovery;
7. transition DMS online and start NAS registration;
8. expose Android radio and IMS interfaces only after the state is coherent.

The order matters. Mainline previously let ModemManager transition DMS online
without reproducing the UIM/MBN orchestration, exposing a repeatable MPSS RFLM
QLINK assertion.

### Packet data

`dpmQmiMgr`, `qti`, `adpl`, `netmgrd`, `ipacm` and `cnd` form the stock data
plane around IPA and rmnet. QCRIL owns WDS profiles, default-data-subscription
policy and data-call requests; netmgrd owns link setup, recovery state and
kernel-facing rmnet configuration. IPA connection management is a separate
service, not part of SIM authentication.

The mainline equivalent must preserve:

- APN profiles and authentication;
- IPv4, IPv6 and dual-stack calls;
- QMAP/rmnet mux ownership per subscription;
- default-data subscription switching;
- DNS, MTU and route lifetime;
- disconnect reasons and automatic recovery after SSR;
- tethering/offload as an optional layer, not a prerequisite for handset data.

The transport-independent `hotdog-network` model now covers the NAS/WDS/netmgr
ownership boundary. A populated subscription must be home or roaming and PS
attached before WDS can start. The default-data subscription is explicit,
QMAP mux IDs are unique, IPv4/IPv6/dual-stack runtime settings and MTU are
validated, and changing DDS with a live bearer is refused unless the caller
explicitly tears it down. SSR advances a generation counter, clears NAS
attachment and fails every live bearer with no stale addresses left behind.
The public replay covers registration and DDS gates, dual-stack completeness,
forced and refused DDS switching, mux collision and SSR invalidation.

`hotdog-qmi-wds` now maps an admitted bearer into concrete WDS requests.
Each client first binds the caller-supplied endpoint/interface and QMAP mux,
then starts the 3GPP profile/APN with bounded auth credentials. IPv4v6 becomes
two WDS clients, IPv4 and IPv6, sharing the mux; it is never collapsed into an
unsupported single-family request. Endpoint type/interface remain discovered
runtime inputs rather than Hotdog constants, and credentials are never logged.
Start confirmation requires a nonzero packet handle; Stop carries that exact
handle. Current Settings decoding preserves per-family address, gateway and DNS
plus IPv6 prefix and a consistent MTU, rejecting incomplete addresses, malformed
IPv6 arrays and mismatched dual-stack MTUs before the bearer becomes connected.

The model now retains the exact IPv4 and IPv6 packet handles. A bearer cannot
become connected until every family it requested has both a handle and valid
runtime settings. Disconnect produces a bounded stop plan, and each completion
must echo the matching family and handle before local state is released. If one
dual-stack leg fails after the other starts, the surviving remote leg is stopped
before the bearer becomes failed. Live remote handles also make a DDS switch
fail with `EBUSY`; force never orphans a session. SSR is the only path that may
discard handles without Stop Network, because their QMI generation has ceased,
and records `ENETRESET`. APN length, every address string, gateways, per-family
and generic DNS, MTU and IPv6 prefix are validated before publication.

### SMS and cell broadcast

QCRIL WMS handles PDU submission, delivery reports, modem/SIM storage and
unsolicited incoming messages. The parity surface includes GSM and CDMA PDU
paths exposed by the modem, multipart messages, status reports, storage-full
handling, SMSC configuration and cell-broadcast indications.

The `hotdog-telephony` model implements the shared WMS/Voice/IMS lifetime. SMS
selects IMS only when the subscription is registered with SMS capability and
otherwise falls back to circuit-switched service. It records PDU size,
multipart identity, storage, modem reference, delivery-report state and strict
queued/submitted/sent/delivered/failed transitions. Incoming messages retain
their subscription, transport and SIM/modem storage identity.

`hotdog-qmi-wms` now carries the opaque 3GPP TPDU into Raw Send, explicitly
selecting CS or SMS-over-IMS from the model without logging payload bytes. It
requires an admitted queued MO message and exact PDU length, then decodes the
16-bit modem reference or preserves QMI plus packed RP/TP failure causes for the
submitted/sent/failed transition.
Transfer-route MT indications are accepted only as bounded 3GPP point-to-point
PDUs; transaction ID, ACK requirement and CS/IMS domain are retained. Send Ack
then echoes that transaction with WCDMA protocol and the same domain, adding
RP/TP causes only on failure. Stored UIM/NV notifications remain a separate Raw
Read path rather than being misread as inline PDUs.

The standard ModemManager QMI messaging owner now enforces that domain model at
runtime. It validates the complete boot-bound `hotdog-ims-state`, maps the
1-based primary SIM slot to its 0-based subscription and snapshots SMS
availability once before a multipart send. Raw Send and Send From Memory
Storage use the same selected domain for every part. An incoming transfer-route
message copies its indication's `SMS on IMS` value into Send Ack. Invalid or
unavailable IMS state falls back to CS; no second WMS or IMSA client is created.

The 3GPP envelope is now classified before creating a message object. The SMSC
length locates TP-MTI; `SMS-DELIVER` remains an incoming message, while a
bounded `SMS-STATUS-REPORT` extracts TP-MR and TP-ST after the variable remote
address and two timestamps. Completed statuses mark the unique matching MO
message delivered, `0x20..0x3f` preserves `sent` while the service centre keeps
retrying, and final failure classes mark it failed. Matching is scoped by
generation, subscription and CS/IMS domain; missing, duplicate or ambiguous
references fail closed. Reserved MTI, truncated addresses/timestamps and
reserved status values never surface as phantom SMS messages.

### Voice and supplementary services

QMI Voice covers dial, answer, hangup, call state, DTMF, call waiting,
forwarding, CLIR/CLIP, conference and emergency call state. Voice is coupled
to the audio graph: a successful QMI call without the matching Q6 audio route
is not a complete call implementation.

The same model tracks MO/MT calls by subscription, CS or IMS domain, emergency
status, video, strict dial/alert/incoming/active/held/disconnecting/end
transitions and a separate audio-ready gate. DTMF is rejected outside an
active call. Call waiting, CLIP and CLIR state are subscription-scoped; the
remaining forwarding, conference and transfer request payloads stay in the
transport parity queue rather than being collapsed into call state.

`hotdog-qmi-voice` keeps a deliberately narrow CS transport/reference boundary:
Dial preserves the validated number, response yields a nonzero modem call ID,
and Answer, End and continuous DTMF require that ID. IMS and video calls cannot
silently fall through that standalone helper as CS. The All Call Status decoder
preserves QMI call ID, subscription, mode, CS/IMS domain, direction, emergency
flag and every user-visible state. Waiting is an incoming call, not a held local
leg. Restricted/unavailable presentation never exposes a number, while
duplicate IDs, unknown directions/states/types and oversized numbers fail
closed. OTAPA and supplementary control transactions are filtered instead of
appearing as calls in Plasma.

The snapshot is reconciled atomically with the transport-independent call
table. MO requests bind exactly one remote call ID; MT and recovered calls may
be created from observations with a hidden number. Immutable direction/domain/
emergency/video fields cannot drift, and all state changes still pass through
the call transition graph. Because All Call Status is a complete snapshot,
previous remote calls absent from the same subscription are ended before new
ones are allocated. This permits complete eight-call churn without false
`ENOSPC`, does not end another SIM subscription, and returns bounded
add/update/end deltas for the future D-Bus publisher.

The delivered ModemManager QMI plugin already owns WDS, WMS and Voice D-Bus
objects, so these clean-room adapters are protocol/reference tests rather than
a competing runtime owner. `modemmanager r5` transposes the first finding into
that standard surface: it creates calls from mandatory Call Information even
when Remote Party Number is absent, enforces presentation privacy and filters
control-call types. Plasma therefore receives the corrected call list through
`org.freedesktop.ModemManager1` without a parallel call daemon.

The OxygenOS 10.0.13 radio library provides the missing Dial contract. Its
exported `ImsVoiceModule::handleQcRilRequestImsDialMessage()` builds a
`voice_dial_call_req_msg_v02` and passes it to
`qcril_qmi_voice_process_dial_call_req()`. The exported
`convert_call_info_to_qmi()` mapping, checked against its AArch64 code, maps an
ordinary VOICE request in the PS domain to `CALL_TYPE_VOICE_IP_V02`, audio
attributes `TX|RX` and video attributes zero, with both attribute TLVs valid.
The matching public QMI v02 service definition assigns Dial TLVs `0x10`,
`0x18` and `0x19` to call type, 64-bit audio attributes and 64-bit video
attributes. The local libqmi extension exposes exactly those fields.

`modemmanager r8` consumes the same strict per-subscription IMS state as the
SMS path. A normal outgoing call on the primary slot uses the OxygenOS IP Voice
tuple only when voice is an available registered IMS capability. Missing,
limited, stale or invalid IMS state preserves the existing automatic/CS Dial.
Answer, End and DTMF remain call-ID operations. This establishes signaling
domain parity but does not by itself claim the IMS APN, Q6 voice route or RTP
media path is complete.

The matching aarch64 protocol packages are
`libqmi-1.38.0_git20260414-r3` SHA-256
`aee333cf2050dd773c79107817de02e4a5187adee4d71724491bd8923c787cf4`
and `libqmi-dev-1.38.0_git20260414-r3` SHA-256
`342992e0fd191db27da0b560fa63e54cc2dd53bfb84131f444dad91e00b0d8c2`.
All seven generated libqmi tests pass in the aarch64 build environment.

### IMS, VoLTE and RCS

OxygenOS splits IMS into `imsqmidaemon`, `imsdatadaemon`, `ims_rtp_daemon` and
`imsrcsd`, with two `IImsRadio` instances plus IMS call-info and RTP HIDL
services. The required reconstruction surface is:

- IMS registration and capability indications;
- IMS APN/bearer lifecycle;
- VoLTE call setup and RTP media control;
- SMS over IMS with circuit-switched fallback;
- emergency registration/call fallback;
- per-subscription IMS state;
- RCS as a separable feature after core IMS parity.

The OxygenOS data-plane boundary is also explicit. `imsdatadaemon` imports
`dsi_get_data_srvc_hndl`, `dsi_set_modem_subs_id`,
`dsi_set_data_call_param`, `dsi_start_data_call`, `dsi_stop_data_call`, address
and device-name readers. Its diagnostics retain APN name, modem profile number,
IP family and subscription ID, set the DSI application type to IMS, support
IPv4 and IPv6 independently, and classify a missing modem link after start as
a possible modem restart or netmgr crash. IMS, emergency, RCS and UT are
separate APN purposes; they are not aliases for the user's default-data PDN.

The mainline model therefore discovers profiles from modem state rather than
hard-coding `ims`. A candidate must be an enabled 3GPP profile on the requested
subscription, carry the matching WDS APN type mask, expose a bounded APN and a
supported PDP family, and for IMS request P-CSCF through PCO. An APN learned
from the modem may disambiguate a carrier profile. Without that evidence an
exact single-purpose mask wins over a composite mask; multiple remaining
candidates fail closed. Dedicated IMS/emergency/UT bearers bypass DDS while
retaining global mux uniqueness and the existing dual-leg handle/SSR rollback.

IMSA registration, RAT, SIP failure and the voice/video/SMS/UT/RCS capability
mask are represented independently for every subscription. Automatic SMS and
call domain selection consumes that state. SSR clears registration and
capabilities, fails in-flight SMS with `ENETRESET`, ends calls, drops audio and
advances the generation so stale indications cannot complete new operations.

`hotdog-qmi-imsa` now binds a dedicated client to subscription 0..2, registers
for registration/service indications and decodes both initial responses and
partial asynchronous updates. The model retains the global registration RAT,
SIP error, available and limited masks, plus WWAN/WLAN RAT independently for
voice, video and SMS. A service indication may precede registration and may
omit its own RAT; in that case the proven registration RAT is the only allowed
fallback. Unregistration clears every effective and limited capability, while
unknown enums or a registered state without technology fail closed. Automatic
domain selection still requires `registered` plus an available capability, so
limited service never becomes a callable transport. The adapter deliberately
does not infer UT or RCS from base IMSA status; those remain owned by their
separate service transports. No APN, RTP or IMS call claim follows from IMSA
alone.

The IPC boundary for this owner is `hotdog-ims-state`, a strict GLib key file
under `/run/hotdog-radio`. It contains only boot ID, SSR generation, populated
subscription flags, registration/RAT, available/limited masks, SIP code and
per-service RAT; ICCID, IMSI, operator and telephone numbers are absent by
construction. The writer uses a private temporary file, fsync, atomic rename
and directory fsync. The reader opens once with `O_NOFOLLOW`, rejects writable
or oversized files, NUL bytes, unknown/missing/duplicate groups or keys and
then revalidates every cross-field invariant. This is the bounded state that a
standard-service adapter may consume without sharing QMI IMSA client ownership.

`hotdog-imsd` is the sole long-lived IMSA owner. It refuses startup until
schema-2 readiness matches the current boot and packaged modem/MCFG identity,
then allocates one IMSA CID for each populated subscription. Every client is
bound before indication registration; initial Registration then Services
queries complete before the first state publication. If an indication races a
query response, the indication wins and the older response is discarded.
Subsequent partial indications atomically rewrite the runtime file. A change in
populated slots or active/selected PDC identity, readiness loss, malformed IMSA
data, SIGTERM or QRTR node removal removes the file and releases every client.
This service owns no WDS, WMS or Voice CID and therefore does not compete with
ModemManager.

The packaged OpenRC graph does not place `hotdog-imsd` directly in a boot
runlevel. The lifecycle supervisor creates verified readiness and starts the
generic modem stack; ModemManager has a soft `use` dependency and ordering on
`hotdog-imsd`, so an IMSA snapshot is available first when the service can be
started. Readiness or QRTR loss makes `hotdog-imsd` remove its runtime state and
exit. The supervisor then revokes readiness and stops ModemManager, preventing
either daemon from retaining state across a modem generation.

## Mainline ownership model

The implementation deliberately keeps proven generic components and replaces
only the missing Qualcomm/Hotdog orchestration:

| Mainline component | Ownership |
| --- | --- |
| Kernel remoteproc/rmtfs/QRTR/IPA/rmnet | MPSS lifecycle, storage and packet transport |
| `hotdog-radio-bootstrapd` | UIM provisioning, per-subscription PDC/MCFG, DMS online gate and SSR recovery |
| libqmi | Typed QMI protocol implementation, including Hotdog-validated missing PDC fields |
| ModemManager QMI plugin | Standard modem, SIM, bearer, SMS, voice and D-Bus objects |
| NetworkManager | IP configuration, routes and user-visible connectivity |
| `hotdog-imsd` | Sole per-subscription IMSA client owner and strict runtime-state publisher |
| Plasma Mobile | Standard ModemManager/NetworkManager/Calls/Spacebar user interface |

`hotdog-radio-bootstrapd` must be the sole owner of the pre-online state. It
hands the modem to ModemManager only after an explicit readiness record
contains the boot ID, MPSS identity, UIM slot/application mapping, selected and
active MCFG IDs for all populated subscriptions, and clean retry counters.
ModemManager is therefore absent from the boot and default OpenRC runlevels
while this gate is incomplete. Its system-bus activation file uses
`Exec=/bin/false`, as intended by the upstream service-file comment, so Plasma
or another D-Bus client cannot silently start the daemon around the OpenRC
policy. A later readiness transition starts ModemManager explicitly.

The first transport slice is implemented with libqrtr-glib and libqmi. It
discovers the configured QRTR node, opens a QMI device with indications,
allocates UIM, decodes the complete card/application/retry structure and feeds
the transport-independent dual-SIM model. With the subscription-capable libqmi
build it then retains the same device, allocates PDC and queries active/pending
software config IDs sequentially for every GW subscription. Each request has a
subscription ID, unique token and bounded indication timeout. It neither
submits a PIN, changes a selected config nor changes DMS state. Mutation,
online gating and SSR re-entry remain later daemon phases.

The current slice is packaged as `hotdog-radio-bootstrap-0.18-r0` plus its
OpenRC service. The aarch64 APKs have SHA-256
`834bf9c0effcfab94b88de3d28db2d2b45d4912956d9e31c59ef9f348b42ff70`
and `9156a110e0b8cc335a0328ae9e6da5238a6851311fb851b9af05713d82e6c340`.
The default service writes boot ID, kernel identity, UIM and PDC output
atomically to `/run/hotdog-radio/observation`; it remains read-only. PDC
mutation requires a separate boot-bound approval manifest. The OpenRC
subpackage orders the generic Plasma Mobile policy first, removes
ModemManager from its runlevel afterwards, and leaves D-Bus activation disabled.
Only a verified apply path may create schema-2 `readiness` and explicitly hand
the modem to ModemManager.
For that validation, `--pdc-subscription=0..2` performs one explicit read-only
Get Selected even when no UIM application is populated. A build without the
patched API rejects the option before opening QRTR.
The no-SIM hardware probe reached PDC service 36, read subscription 0 as
`active:- pending:- result:NotProvisioned`, released both QMI CIDs and left MPSS
running. A second probe joined Get Card Status with Get Slot Status and proved
that the firmware exposes two logically active physical slots even when both
are empty. See [the read-only PDC validation](2026-08-25-radio-pdc-readonly.md)
and [physical-slot identity validation](2026-08-25-radio-uim-slot-identity.md).
The matching 69-profile catalog is now installed on the test phone. A no-SIM
`--plan-pdc` run reached both UIM views and then failed closed before PDC with
`requires a populated GW application`; see
[the installed-catalog dry-run](2026-08-25-radio-mcfg-dry-plan.md).

## Required state machines

### UIM and dual SIM

- physical slot discovery independent of logical subscription;
- application choice for USIM, SIM, CSIM and ISIM;
- primary and secondary GW provisioning sessions;
- hotplug and no-ATR recovery;
- PIN1/PIN2, PUK1/PUK2 and retry-count preservation;
- card-slot-scoped verify, unblock, change and protection operations;
- both slots represented even when one is empty;
- no implicit fallback that routes a security operation to slot 1.

The transport-independent `hotdog-uim` model implements this inventory and
session mapping. Replays cover two populated physical slots, a card only in
slot 2, no-ATR failure, no-card state, explicit security routing and retry
counter integrity. This model is shared by the future libqmi transport and the
offline trace harness, so D-Bus presentation cannot silently alter the slot or
subscription selected for a PIN operation.

The libqmi transport now combines two distinct UIM views before PDC planning.
Get Card Status supplies applications, AIDs, PIN/PUK state and retry counters;
Get Slot Status supplies physical presence, logical-slot activation and the
BCD ICCID for each physical slot. The decoder preserves both physical slots,
trims only the terminal ICCID filler nibble and rejects inconsistent slot
counts or an ICCID attached to an absent card. Runtime logs expose only
presence and length, never the full ICCID. MCFG selection consumes the value
internally, so a PIN prompt cannot accidentally become the first operation
that discovers which card and subscription are active.

### PDC/MCFG

- parse stock MBN metadata types for carrier name, long IIN, IIN and MCC/MNC;
- select by the same precedence as qcrild;
- get/set/activate/deactivate on the same subscription;
- enumerate and activate every pending APSS subscription;
- verify active ID after modem switch;
- retain the previous active ID for rollback;
- never transition online with an unresolved pending configuration.

The clean-room `hotdog-mbn` parser implements the stock trailer and metadata
TLVs without embedding any proprietary MBN. Synthetic tests cover malformed
input and selection precedence. External validation against private stock MBNs
recovered the expected carrier name, six-digit IIN, PLMN, versions and
capability, then selected that carrier by IIN. Runtime code therefore discovers
the profile from card and MBN metadata instead of carrying device-owner or
operator-specific constants.

The `hotdog-mcfg` runtime catalog now scans the packaged profile tree without
following symlinks, parses every MBN, sorts relative paths deterministically
and rejects duplicate configuration IDs. The ID is the SHA-1 digest of the
complete MBN, matching both libqmi's PDC Load Config implementation and the
20-byte QCRIL/PDC contract. The matching OOS10 list has 69 entries; one stale
`sm8150.g` list path corresponds to the real `sm8150.p` default profile, so the
scanner reports list drift but never hides a valid parsed profile. See
[the OxygenOS catalog reconstruction](2026-08-25-oxygenos-mcfg-catalog.md).
Immediately before Load Config, the selected profile is reopened one path
component at a time with `openat`, directory/file `O_NOFOLLOW`, a 16 MiB size
bound and an exact SHA-1 recheck against the planned ID. A changed file or an
intermediate/final symlink is therefore rejected even if catalog discovery was
valid earlier.

The bootstrap daemon exposes this join only as `--plan-pdc --mcfg-root=DIR`.
Planning requires a real GW application, a physically present card and an
ICCID on that same physical slot. It queries active and pending IDs for every
subscription, marks matching catalog entries as already loaded, then prints the
complete load/select/activate/verify transaction using only relative MCFG paths
and carrier metadata. The option never sends Load, Set Selected, Activate,
Delete or DMS requests; no-card and missing-identity states fail before a plan
can be accepted.

The transport-independent `hotdog-pdc` model now turns that selection into an
auditable multi-subscription transaction. It saves each previous active ID,
sets each populated subscription independently, issues one bounded global
activation with the exact pending-indication count, models modem-switch
completion and verifies every active ID before the online gate. Rollback
deactivates each changed subscription, restores its previous selected ID and
reactivates the complete set. The public replay covers precedence, version
tie-breaking, an already-active no-op, two-subscription activation, unmatched
cards, malformed bounds, verification and rollback without any private MBN.

`hotdog-qmi-pdc` is the corresponding libqmi boundary. It constructs software
Get Selected, Set Selected, Activate and Deactivate requests with the same
subscription ID and caller-owned token, then decodes Get Selected indications
into bounded active/pending IDs. Missing fields, stale tokens, a nonzero remote
result and oversized IDs fail closed before they can advance the radio state.
Its compile-check uses the public libqmi API plus exactly the four generated
subscription setters carried by the local libqmi patch.
The same adapter now decodes Set Selected, Activate and Deactivate indications
plus the Delete response. Every mutation confirmation requires its exact token
and a zero remote result; stale tokens, missing fields and protocol errors are
preserved as failures rather than being collapsed into generic success.

Rollback is generated from acknowledged progress, not merely from the original
plan. A failed or interrupted Load schedules only Delete Config for the partial
SHA-1. A selection-stage failure deactivates the pending current ID, restores
the previous selection and deletes the newly loaded profile without a needless
activation. Once activation has been attempted, recovery additionally
reactivates every previous ID, waits for the modem switch, then deletes only
profiles loaded by this transaction. Shared profiles are deleted once.

`hotdog-pdc-executor` consumes that activation plan one operation at a time.
Calling `next` marks a mutation as potentially dispatched; a second operation
cannot be obtained until the first is explicitly completed. Full confirmation
reaches `committed`. The first apply failure switches to the progress-derived
recovery plan, and a successful recovery ends as `rolled-back` while preserving
the original error. Any recovery failure ends as `blocked` with a separate
rollback error and no further operation, making residue impossible to report as
success.

`hotdog-qmi-pdc-dispatch` is the concrete request boundary consumed by that
executor. It maps local save, secure chunked load, subscription-scoped
set/restore, activate/deactivate, delete, selected-ID verification and modem
switch wait into one owned request object. Load keeps the securely reopened
profile alive across chunks and refuses a next chunk until the previous
indication has advanced the load state. Clearing a request unreferences every
typed libqmi object and profile buffer deterministically.

`hotdog-qmi-pdc-backend` sends one dispatched request at a time. Responses and
indications both validate their tokens; protocol errors are preserved. Load
indications advance the bounded chunk state and refresh a per-chunk timeout,
while Verify requires the exact active ID and an empty pending ID. The backend
deliberately returns modem-switch ownership to the outer QRTR lifecycle rather
than pretending a dead PDC client can confirm its own reconnect.

`hotdog-pdc-controller` joins executor, dispatcher and backend. QRTR loss while
Activate is outstanding completes that operation as the expected modem switch;
loss during any other request is `ENETRESET` and enters recovery. The following
Switch operation pauses the controller until the outer lifecycle has observed
service loss/reappearance, allocated a new PDC client and rebound the backend.
Only an explicit switch completion can advance to selected-ID verification.
An unexpected loss also pauses the generated recovery until a new client is
rebound; no rollback request is sent through a dead transport. A loss already
observed during Activate satisfies exactly the following Switch operation once,
whereas a later recovery activation must observe its own new loss/reconnect.

Execution also requires a root-owned approval manifest that is neither a
symlink nor group/world writable. `hotdog-radio-approval` accepts only schema,
boot ID, modem SHA-256, MCFG archive SHA-256 and one selected ID (or `-`) for
each subscription 0..2. Unknown, missing or duplicate keys fail closed. The
manifest must match the current boot and installed runtime manifest, and its
subscription population/IDs must match the freshly computed plan. It contains
no PIN or subscriber identity.
The installed package manifest is parsed separately by `hotdog-mcfg-runtime`;
its exact schema, source/MPSS/catalog hashes and three nonzero file counts are
required, with the same symlink and permission restrictions. This prevents an
approval from validating against documentation while the runtime package
metadata is missing or malformed.
`hotdog-radio-gate` then recomputes the SHA-256 of the actual MPSS file with a
128 MiB bound and no final symlink, recounts the MCFG tree without following
any symlink, checks those values and the parsed catalog against package
metadata, reads the current boot ID and finally validates the approval against
fresh subscription selections. This is the single pre-mutation gate; the QRTR
reads used to rebuild the plan happen before it, but no mutating request does.

The daemon exposes execution only as
`--apply-pdc=APPROVAL --mcfg-root=/usr/share/hotdog-radio/mcfg/mcfg_sw`.
It is mutually exclusive with dry-run and all standalone probes, requires real
UIM identity, inventories resident configs and all three selected states again,
prints the rebuilt plan, passes the combined gate and then starts the
transaction controller. Bus node removal/addition and PDC service return drive
the reconnect/rebind path. A committed PDC transaction allows only
`shutting-down`, offline or low-power to transition to Online, then re-reads
DMS. `hotdog-radio-readiness` writes schema 2 atomically only after DMS is
confirmed Online, every populated active ID equals selected and every pending
ID is empty. The record contains physical slot, application lock state and retry
counts but no ICCID or PIN. Deferred stale cleanup remains a later maintenance
phase.
Immediately after the atomic readiness write, the same process explicitly
starts the OpenRC ModemManager service. This preserves the live verification
window: no separate process trusts a stale record, and D-Bus activation remains
disabled. A failed handoff is reported as transaction failure while the valid
radio-state record remains available for diagnosis or retry.
The target no-SIM apply probe fails at the populated-GW gate before reading a
deliberately absent approval and leaves resident PDC count, DMS and MPSS
unchanged; see [the apply fail-closed validation](2026-08-25-radio-pdc-apply-nosim.md).

The load phase is modeled separately by `hotdog-pdc-load` and
`hotdog-qmi-pdc-load`. A complete MBN is addressed by its 20-byte SHA-1 ID and
sent in chunks no larger than `0x400` bytes, matching upstream qmicli and the
stock QCRIL `pdc_load_config_segment` path. Every chunk has a fresh token and
must report the exact remaining byte count before the next chunk is built.
Stale tokens do not advance state. A remote error, frame reset, malformed
progress or local abort after transmission marks the ID for an explicit PDC
Delete Config cleanup before selection can continue. Synthetic replay covers
multi-chunk completion and every cleanup transition; no hardware mutation is
enabled by this model alone.

`hotdog-qmi-pdc-list` inventories the modem-EFS software configs before that
plan. The request is global and read-only; the indication must carry the
expected token, software type, unique nonempty IDs and no remote error. The
decoded IDs are compared byte-for-byte with local MBN SHA-1 IDs. Matching
entries are marked loaded so the plan never uploads them twice, while resident
IDs from an older firmware catalog remain visible as unmatched state instead
of being mistaken for the current profile.
The no-SIM hardware inventory found 25 unique inactive residents and zero ID
matches against either the 69-profile matching OOS10 tree or the 242-profile
OOS12 F.22 cross-check. They are persistent stale state and must be handled by
the guarded cleanup transaction; see
[the resident PDC inventory](2026-08-25-radio-pdc-resident-catalog.md).

The cleanup planner is all-or-nothing. It first marks exact current-catalog
matches as loaded, rejects duplicate or malformed resident IDs, and scans the
active and pending state of every supplied subscription. Any unmatched active
or pending ID returns `EBUSY` with zero operations. Only unmatched inactive
residents become Delete Config operations; the current profile is never
deleted and will not be loaded again. Cleanup is deliberately deferred until
the selected current profile is active, verified and committed; deleting stale
profiles before a successful load would create an unnecessary non-restorable
failure mode. The hardware executor must supply all three APSS subscription
readbacks before this offline plan can be authorized.
The daemon dry-run now obtains those inputs in one ordered read-only session:
List Configs first, then Get Selected for subscription 0, 1 and 2, then local
catalog parsing, load/select/activate/verify planning for populated
subscriptions and finally deferred stale cleanup planning. It prints the
activation and post-commit cleanup transactions separately and still has no
call site for any mutating PDC request.

### Radio and SSR

- DMS state transitions are explicit and validated;
- NAS registration starts only after UIM and PDC readiness;
- QRTR service disappearance invalidates all QMI clients;
- recovery recreates provisioning sessions and verifies active MCFG state;
- data, SMS, calls and IMS receive deterministic loss/recovery notifications;
- repeated modem failure remains stopped instead of inducing a phone reboot
  loop.

Readiness and ModemManager ownership are represented in the same reducer as
PDC, NAS, data, SMS, calls and IMS. DMS Online publishes a phase-specific
readiness record before handoff. A handoff acknowledgement is accepted only
while QRTR, DMS and that attestation are current. Any unexpected `QRTR_DOWN`
then emits `revoke-ready` and `stop-modemmanager` together with teardown of
data, in-flight SMS, calls and IMS. Locked-to-registering, registration success
and registration loss each republish the phase instead of leaving a stale
ready-state file behind. The next transport step must execute these actions and
reattest UIM/PDC/DMS before restarting the generic daemon.

`hotdog-radio-supervisor` now defines the execution-side lifecycle independently
of GLib/QRTR process plumbing. It waits for QRTR and strict readiness, owns one
asynchronous ModemManager start/stop operation, bounds repeated start failures
and enters a permanent blocked phase when stop cannot be confirmed. SSR during
start is handled explicitly: a late successful child is stopped before the
supervisor waits for QRTR. A fatal event uses the same drain-before-block rule,
so blocking never loses ownership of a process still being created. The replay
covers normal handoff, invalid/removed readiness, active SSR, start-time SSR,
late child completion, stop failure and bounded retries. The next slice is the
long-lived QRTR/file/OpenRC adapter that executes these emitted actions.

That adapter now exists as `hotdog-radio-supervisord`. It watches the configured
MPSS QRTR node and revalidates the schema-2 record against the current kernel
boot ID and packaged MCFG/modem hashes. OpenRC start/stop and approved bootstrap
are fixed-argv asynchronous `GSubprocess` operations; no shell or command-line
expansion is involved. Readiness is unlinked before a required stop. On SSR, an
automatic re-attestation runs only when a readable boot-bound approval path was
explicitly configured; otherwise it waits for manual approval without mutating
PDC. The bootstrap's `--defer-handoff` mode publishes verified readiness but
leaves ModemManager startup exclusively to the supervisor. SIGINT/SIGTERM uses
the same drain-before-block path, including a late start completion.

`hotdog-qmi-dms` provides the typed operating-mode boundary. The standalone
`--probe-dms` remains read-only. The approved PDC path invokes Set Online only
after commit, rereads DMS, publishes readiness only after confirmed Online and
then starts ModemManager explicitly. Any unsafe or unknown mode fails closed.
The no-SIM hardware probe reports stable `shutting-down` while remoteproc and
all MPSS QRTR services remain alive. This is the intended pre-online state, not
a remoteproc failure. Earlier Set Online evidence crashed the modem when no
MCFG was active, so the daemon must preserve this mode through PDC verification;
see [the DMS shutdown gate](2026-08-25-radio-dms-shutdown-gate.md).

`hotdog-qmi-nas` decodes both Get Serving System and its asynchronous indication
into bounded registration, CS/PS attach, selected-network, radio interfaces,
roaming and internal PLMN state. Registered state requires explicit home/roam,
a valid MCC/MNC and at least one known RAT; mixed interface lists use the
NR5G/LTE/UMTS/GSM/CDMA priority without depending on enum numeric order.
Applying a PS detach or registration loss atomically creates exact WDS stop
plans for every bearer on that subscription while leaving the other SIM
untouched. The daemon still exposes transport only through standalone
read-only `--probe-nas`; long-lived indication ownership is the next service
phase. It does not print PLMN/operator identity and does not request
registration. The no-SIM hardware baseline is `not-registered-searching` with
both CS and PS detached, network unknown and interface `none`, independently
confirmed by qmicli. Searching is not readiness; see
[the NAS pre-online baseline](2026-08-25-radio-nas-preonline.md).

## Parity gates

Offline replay must cover every request/response/indication family before a SIM
is reinserted. Hardware validation then proceeds in this order:

1. card discovery and retry counters, no PIN submission;
2. selected/active MCFG proof for every populated subscription;
3. one PIN verification with unchanged counter on success;
4. stable registration and operator identity;
5. IPv4/IPv6 data and reconnect;
6. outgoing and incoming SMS with delivery report;
7. outgoing and incoming circuit-switched or IMS call with audio and DTMF;
8. VoLTE registration and call, then optional RCS;
9. SIM removal/reinsert, slot swap and modem SSR recovery.

No function is marked working from API success alone. Data requires traffic,
SMS requires remote receipt, calls require bidirectional audio, and recovery
requires the same operation to succeed after a controlled service loss.
