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

IMSA registration, RAT, SIP failure and the voice/video/SMS/UT/RCS capability
mask are represented independently for every subscription. Automatic SMS and
call domain selection consumes that state. SSR clears registration and
capabilities, fails in-flight SMS with `ENETRESET`, ends calls, drops audio and
advances the generation so stale indications cannot complete new operations.

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
| `hotdog-imsd` | Per-subscription IMS registration, IMS bearer and media-control bridge |
| Plasma Mobile | Standard ModemManager/NetworkManager/Calls/Spacebar user interface |

`hotdog-radio-bootstrapd` must be the sole owner of the pre-online state. It
hands the modem to ModemManager only after an explicit readiness record
contains the boot ID, MPSS identity, UIM slot/application mapping, selected and
active MCFG IDs for all populated subscriptions, and clean retry counters.

The first transport slice is implemented with libqrtr-glib and libqmi. It
discovers the configured QRTR node, opens a QMI device with indications,
allocates UIM, decodes the complete card/application/retry structure and feeds
the transport-independent dual-SIM model. With the subscription-capable libqmi
build it then retains the same device, allocates PDC and queries active/pending
software config IDs sequentially for every GW subscription. Each request has a
subscription ID, unique token and bounded indication timeout. It neither
submits a PIN, changes a selected config nor changes DMS state. Mutation,
online gating and SSR re-entry remain later daemon phases.

The read-only slice is packaged as `hotdog-radio-bootstrap-0.5-r0` plus an
OpenRC oneshot service. The aarch64 APKs have SHA-256
`091da530c9e560b90790f610f7eef5942596aa7abec2ffed6af1cbcd46a3baee`
and `7f43de159e52c8075f817bcf191ff12c3de0d5a9cf94f4720f53071dc6478cd9`.
The binary links to the four subscription setters from libqmi `r2`. The service
writes boot ID, kernel identity, UIM and PDC output atomically under `/run`, but
is deliberately not auto-enabled before a no-SIM target validation.
For that validation, `--pdc-subscription=0..2` performs one explicit read-only
Get Selected even when no UIM application is populated. A build without the
patched API rejects the option before opening QRTR.
The no-SIM hardware probe reached PDC service 36, read subscription 0 as
`active:- pending:- result:NotProvisioned`, released both QMI CIDs and left MPSS
running. See [the read-only PDC validation](2026-08-25-radio-pdc-readonly.md).

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

### Radio and SSR

- DMS state transitions are explicit and validated;
- NAS registration starts only after UIM and PDC readiness;
- QRTR service disappearance invalidates all QMI clients;
- recovery recreates provisioning sessions and verifies active MCFG state;
- data, SMS, calls and IMS receive deterministic loss/recovery notifications;
- repeated modem failure remains stopped instead of inducing a phone reboot
  loop.

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
