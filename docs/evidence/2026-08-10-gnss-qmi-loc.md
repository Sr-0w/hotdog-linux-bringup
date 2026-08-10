# GNSS: the engine works, the userspace path does not - 2026-08-10

## Result

The modem's GNSS engine is alive and answers QMI on the mainline stack. What is
missing is the bridge to a standard location service, and that bridge is blocked
behind the mobile-data path rather than behind anything GNSS-specific.

## What works

`pd-mapper` had to be started first; it is installed but was not running. With
it up, the modem's QMI services answer over QRTR node 0:

```
qmicli -d qrtr://0 --loc-get-nmea-types
  Successfully retrieved NMEA types: gga, rmc, gsv, gsa, vtg, pqxfi

qmicli -d qrtr://0 --loc-session-id=1 --loc-start
  Successfully started location tracking (session id 1)

qmicli -d qrtr://0 --loc-session-id=1 --loc-stop
  Successfully stopped location tracking (session id 1)
```

So the LOC service is registered, its NMEA configuration is readable, and
sessions start and stop cleanly.

The rest of the modem answers too, which matters for the telephony phase:

| Query | Result |
| --- | --- |
| `--dms-get-manufacturer` | `QUALCOMM INCORPORATED` |
| `--dms-get-revision` | `Q_V1_P14` |
| `--nas-get-signal-strength` | reports IO `-106 dBm`, SINR `9.0 dB` |
| `--uim-get-card-status` | `no-atr-received` - no SIM was inserted |

## What blocks the standard stack

`gnss-share` is the postmarketOS bridge from a GNSS source to geoclue. It has
exactly two backends, from its own binary:

```
gnss-share/internal/gnss/stm.go            serial receivers
gnss-share/internal/gnss/modemmanager.go   ModemManager
```

There is no QMI or QRTR backend, so the supported path runs through
ModemManager. ModemManager finds no modem, and its debug log says exactly why:

```
[qrtr] created new node 0
[qrtr-bus-watcher] qrtr node 0 added
[base-manager] couldn't create modem for device 'qcom-soc':
               Failed to find a net port in the QMI modem
```

It discovers the QRTR node and all 49 registered services, builds a modem
object, and then discards it because there is no network interface. On a
Qualcomm SoC the modem's data path is `rmnet` carried by IPA, and there is no
IPA device here.

## Why there is no IPA

`CONFIG_QCOM_IPA=m` and `CONFIG_RMNET=m` are already enabled, so this is not a
configuration gap. Upstream IPA supports these parts:

```
msm8998, sc7180, sc7280, sdm845, sdx55, sdx65, sm6350, sm8350, sm8550
```

SM8150 is not among them, and neither `linux-next` nor mainline carries an
`ipa_data-v4.0.c` for it. `CONFIG_QCOM_BAM_DMUX` is deliberately unset and would
not apply: BAM-DMUX belongs to the pre-IPA generation.

So the chain is: geoclue needs gnss-share, gnss-share needs ModemManager,
ModemManager needs a net port, the net port needs rmnet over IPA, and IPA has no
SM8150 support upstream.

## Consequence for the roadmap

GNSS is not an independent item. It sits behind the same IPA work as mobile
data, and the roadmap's ordering of GNSS before telephony does not reflect that.

Two ways forward, and they are not equivalent:

1. **Port IPA for SM8150.** Large, but it unlocks mobile data, ModemManager, and
   GNSS together, and it is the change that belongs upstream. The published
   OnePlus kernel carries the vendor IPA driver and its SM8150 configuration,
   which is where the register layout and endpoint tables can be read.
2. **Add a QMI backend to gnss-share.** Smaller and GNSS-only, but it diverges
   from the upstream project unless it is contributed there.

## Not established

No satellite was acquired. `--loc-get-gnss-sv-info` timed out after 90 seconds
and `--loc-follow-nmea` produced no sentences, both indoors and with the session
opened by a separate short-lived process. The QMI client is bound to the QRTR
socket, so a session opened by one `qmicli` invocation ends when it exits, and
`qmicli` refuses to combine `--loc-start` with a follow action. Whether the
receiver acquires satellites therefore remains untested and needs either sky
view with a single long-lived client, or the userspace bridge above.
