# SMB5 and TCPM register ownership

## Scope

This audit answers whether the proposed PM8150B SMB5 support and the existing
Qualcomm PMIC TCPM driver can write the same PMIC registers. It uses the
public qcom_smbx candidate tree
`face07e87b8b06d4d93e0d8d598e13a64d72f255` and the PM8150B description in
that same tree.

The PM8150B charger node uses base `0x1000`. The dedicated Type-C port uses
base `0x1500`, and its PD PHY uses base `0x1700`.

## SMB5 writes

All qcom_smbx register accesses add an offset to the charger base. The SMB5
paths write charger, DCDC, USB-input and watchdog blocks. Relevant absolute
addresses include:

| Block | Absolute addresses used by SMB5 |
|---|---|
| Charger core | `0x1042`, `0x1061`, `0x1070` |
| DCDC / power path | `0x1108`, `0x110b` |
| USB input and BC1.2 | `0x1340`-`0x1342`, `0x1358`, `0x1362`, `0x1365`, `0x1366`, `0x1370`, `0x1380` |
| Watchdog / AICL timer | `0x1651`, `0x1653`, `0x1661` |

The symbol named `TYPE_C_CFG` in qcom_smbx is offset `0x358`, therefore
absolute address `0x1358` in the USB-input peripheral. SMB5 only clears its
`APSD_START_ON_CC_BIT`, keeping BC1.2 detection from being started directly
by CC state. It is not the dedicated PM8150B Type-C port register at
`0x1544`.

## TCPM writes

The PMIC Type-C port driver accesses the peripheral beginning at `0x1500`.
Its writes are at offsets such as `0x44`, `0x46`, `0x50`, `0x52`, `0x5e` and
`0x60`, yielding absolute addresses `0x1544`, `0x1546`, `0x1550`, `0x1552`,
`0x155e` and `0x1560`. Its status reads remain in the same `0x1500`
peripheral.

The PD PHY driver independently accesses the block beginning at `0x1700`,
principally `0x1740` through its RX/TX buffer window in the `0x1780` range.

## Verdict

The actual absolute register sets are disjoint. qcom_smbx does not write the
dedicated Type-C or PD PHY blocks on SMB5, while TCPM does not write the
charger, USB-input or charger-watchdog blocks. The misleading legacy
`TYPE_C_CFG` symbol in qcom_smbx names a USB-input/BC1.2 policy register and
does not indicate shared ownership.

This source audit resolves register ownership only. USB-C sink/source role,
PD negotiation and powered-dock hardware tests remain separate behavioral
gates before calling the combined implementation production ready.
